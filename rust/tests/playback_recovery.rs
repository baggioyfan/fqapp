//! Playback door fallback contract.
//!
//! Ported from `N3urda/hongguoTV`'s `streamLadderWithCompatibility`: when the v5
//! player door answers `HTTP 200` with no bytes, the playback model is requested
//! from the signed `video_tab` doors under the same identity, doors that returned
//! an empty body stay parked, and only a foreground request may rotate identity.
//! Nothing here may leak a URL, a body or a signature into the error surface.
//!
//! The door-health state is process-wide, so these scenarios take turns on a
//! plain mutex. Holding it across `await` is the point: the guard is released
//! only when the scenario that owns the state is finished.
#![allow(clippy::await_holding_lock)]

mod common;

use common::{
    build_server, identity_setup_reply, is_identity_setup, pool_json, query_map, MockReply,
    MockUpstream, TempDir, ANON_PLAYER_PATH, LEGACY_V5_PLAYER_PATH,
};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use fqapi_core::upstream::reset_playback_route_state_for_tests;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::sync::{Mutex, MutexGuard};

const V5_PATH: &str = LEGACY_V5_PLAYER_PATH;
const MODEL_PATH: &str = "/novel/player/video_model/v1/";
const TAB_PATH: &str = "/reading/bookapi/video_tab/multi_video_model/v1/";
const VIDEO_ID: &str = "7312345678901234567";

/// Process-wide route state means these scenarios must not interleave.
static ROUTES: Mutex<()> = Mutex::new(());

fn exclusive() -> MutexGuard<'static, ()> {
    let guard = ROUTES.lock().unwrap_or_else(|error| error.into_inner());
    reset_playback_route_state_for_tests();
    guard
}

fn model() -> Value {
    json!({
        "key_seed": "AAAA",
        "video_list": {
            "video_0": {
                "main_url": "https://example.invalid/h264-1080.mp4",
                "codec_type": "h264",
                "video_meta": {"definition": "1080p", "vwidth": 1080, "vheight": 1920},
                "encrypt_info": {"encrypt": false}
            }
        }
    })
}

/// A v5 player response: `data.1004.<video id>.video_model`.
fn v5_body() -> Value {
    let entry = json!({ "video_model": model() });
    let mut group = serde_json::Map::new();
    group.insert(VIDEO_ID.to_string(), entry);
    json!({"code": 0, "data": {"1004": Value::Object(group)}})
}

/// A `video_tab` response: `data.video_model_data.<video id>.video_model`.
fn tab_body() -> Value {
    let entry = json!({ "video_model": model() });
    let mut rows = serde_json::Map::new();
    rows.insert(VIDEO_ID.to_string(), entry);
    json!({"code": 0, "data": {"video_model_data": Value::Object(rows)}})
}

fn is_v5(request: &common::Recorded) -> bool {
    request.path == V5_PATH
}

fn is_anon(request: &common::Recorded) -> bool {
    request.path == ANON_PLAYER_PATH
}

fn is_model(request: &common::Recorded) -> bool {
    request.path == MODEL_PATH
}

fn is_tab(request: &common::Recorded) -> bool {
    request.path == TAB_PATH
}

fn playback_requests(requests: &[common::Recorded]) -> Vec<&common::Recorded> {
    requests
        .iter()
        .filter(|request| !is_identity_setup(request))
        .collect()
}

fn paths<'a>(requests: &[&'a common::Recorded]) -> Vec<&'a str> {
    requests
        .iter()
        .map(|request| request.path.as_str())
        .collect()
}

fn with_identity_setup<F>(responder: F) -> impl Fn(&common::Recorded) -> MockReply
where
    F: Fn(&common::Recorded) -> MockReply + Send + Sync + 'static,
{
    move |request| identity_setup_reply(request).unwrap_or_else(|| responder(request))
}

fn business_rejection() -> MockReply {
    MockReply::json(json!({"code": 100103, "data": {}}))
}

/// A codec-only model in the v5 grouped shape.
fn v5_codec_body(codec: &str) -> Value {
    let entry = json!({ "video_model": {
        "key_seed": "AAAA",
        "video_list": {"video_0": {
            "main_url": format!("https://example.invalid/{codec}-1080.mp4"),
            "codec_type": codec,
            "vwidth": 1080,
            "vheight": 1920,
        }}
    }});
    let mut group = serde_json::Map::new();
    group.insert(VIDEO_ID.to_string(), entry);
    json!({"code": 0, "data": {"1004": Value::Object(group)}})
}

/// A codec-only model in the official single-episode shape (`data.video_model`).
fn model_codec_body(codec: &str) -> Value {
    json!({"code": 0, "data": {"video_model": {
        "key_seed": "AAAA",
        "video_list": {"video_0": {
            "main_url": format!("https://example.invalid/{codec}-1080.mp4"),
            "codec_type": codec,
            "vwidth": 1080,
            "vheight": 1920,
        }}
    }}})
}

fn device_of(request: &common::Recorded) -> String {
    query_map(&request.query)
        .get("device_id")
        .cloned()
        .unwrap_or_default()
}

/// The video id is the path segment: the router overrides any `video_id` query
/// parameter with it. `mode=stream` keeps the assertion on the model fetch and
/// stops the endpoint from also downloading media through the same mock.
async fn episode(server: &Server, extra: &str) -> (u16, Value) {
    let query = if extra.is_empty() {
        "mode=stream".to_string()
    } else {
        format!("mode=stream&{extra}")
    };
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: format!("/api/v1/videos/{VIDEO_ID}"),
            query,
            ..Default::default()
        },
    )
    .await;
    let status = response.status;
    let body = response.into_bytes().await.expect("response body");
    (
        status,
        serde_json::from_slice(&body).expect("JSON response"),
    )
}

async fn server_with(upstream: &MockUpstream, tag: &str) -> (TempDir, Arc<Server>) {
    let dir = TempDir::new(tag);
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    (dir, server)
}

#[tokio::test]
async fn empty_player_doors_fall_back_to_the_signed_video_tab_door_on_the_same_identity() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|request| {
        if is_tab(request) {
            MockReply::json(tab_body())
        } else {
            MockReply::status(200)
        }
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "fallback-video-tab").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    assert!(
        body["video_url"]
            .as_str()
            .is_some_and(|url| url.starts_with("https://")),
        "the fallback model must produce a playable primary url: {body}"
    );

    let requests = upstream.requests();
    let playback = playback_requests(&requests);
    assert_eq!(
        paths(&playback),
        [
            ANON_PLAYER_PATH,
            ANON_PLAYER_PATH,
            ANON_PLAYER_PATH,
            V5_PATH,
            MODEL_PATH,
            MODEL_PATH,
            TAB_PATH,
        ],
        "anonymous door, its re-probe, v5, model-a, model-c, then one video_tab door"
    );
    assert!(is_anon(playback[0]) && playback[0].method == "POST");
    assert!(
        is_anon(playback[1]) && playback[1].method == "POST",
        "the anonymous door may refresh its device once and then re-probe once"
    );
    assert!(
        is_v5(playback[3]) && playback[3].method == "POST",
        "v5 is the first fallback after the anonymous door"
    );
    assert!(
        is_model(playback[4]) && playback[4].method == "POST",
        "the single-episode door is the second fallback"
    );
    assert!(is_model(playback[5]) && playback[5].method == "POST");
    assert!(is_tab(playback[6]) && playback[6].method == "GET");

    let anonymous_id = device_of(playback[0]);
    assert!(!anonymous_id.is_empty());
    assert!(playback[..3]
        .iter()
        .all(|request| device_of(request) == anonymous_id));
    let pooled_id = device_of(playback[3]);
    assert!(!pooled_id.is_empty());
    assert_ne!(anonymous_id, pooled_id);
    for request in playback.iter().skip(3) {
        assert_eq!(
            pooled_id,
            device_of(request),
            "every legacy fallback must be asked under the same pooled identity"
        );
    }
    for header in ["x-medusa", "x-helios", "x-khronos"] {
        assert!(
            playback[6].header(header).is_some(),
            "the fallback door must carry the player signature header {header}"
        );
    }
    assert!(
        playback[6].header("x-ss-stub").is_none(),
        "a body-less GET must not claim a body digest"
    );

    let query = query_map(&playback[6].query);
    for (key, expected) in [
        ("video_id", VIDEO_ID),
        ("video_id_type", "0"),
        ("device_level", "1"),
        ("need_all_video_definition", "1"),
        ("need_mp4_align", "0"),
        ("use_os_player", "0"),
        ("video_platform", "1024"),
        ("source", "0"),
        ("from_video_id", ""),
    ] {
        assert_eq!(
            query.get(key).map(String::as_str),
            Some(expected),
            "video_tab parameter {key}"
        );
    }
    upstream.shutdown();
}

#[tokio::test]
async fn an_empty_v5_body_is_reprobed_once_on_the_same_identity_before_switching_door() {
    let _guard = exclusive();
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let upstream = MockUpstream::start(with_identity_setup(move |request| {
        if is_anon(request) {
            business_rejection()
        } else if is_v5(request) && counter.fetch_add(1, Ordering::SeqCst) == 0 {
            MockReply::status(200)
        } else if is_v5(request) {
            MockReply::json(v5_body())
        } else {
            MockReply::status(200)
        }
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "same-door-reprobe").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let requests = upstream.requests();
    let playback = playback_requests(&requests);
    assert_eq!(
        paths(&playback),
        [ANON_PLAYER_PATH, V5_PATH, V5_PATH],
        "a rejected anon door does not spend the v5 re-probe: {body}"
    );
    assert!(
        is_anon(playback[0]),
        "the anonymous door is attempted before the legacy v5 door"
    );
    assert!(playback[1..].iter().all(|request| is_v5(request)));
    assert_eq!(
        device_of(playback[1]),
        device_of(playback[2]),
        "the v5 re-probe must reuse the pooled identity that just answered"
    );
    assert_ne!(device_of(playback[0]), device_of(playback[1]));
    upstream.shutdown();
}

#[tokio::test]
async fn a_prefetch_empty_body_is_not_reprobed_or_parked() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|_| MockReply::status(200))).await;
    let (_dir, server) = server_with(&upstream, "prefetch-empty").await;

    let (status, body) = episode(&server, "_playback_purpose=prefetch").await;
    assert_eq!(status, 500, "{body}");
    let prefetched = upstream.requests();
    let playback = playback_requests(&prefetched);
    assert_eq!(
        paths(&playback),
        [ANON_PLAYER_PATH, ANON_PLAYER_PATH],
        "one speculative door plus one anonymous-identity refresh; no same-door re-probe"
    );

    let before = prefetched.len();
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 500, "{body}");
    let after = upstream.requests();
    let foreground: Vec<_> = after.iter().skip(before).collect();
    assert!(
        foreground.first().is_some_and(|request| is_anon(request)),
        "a speculative empty must not park the anonymous door: {:?}",
        foreground
            .iter()
            .map(|request| &request.path)
            .collect::<Vec<_>>()
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_non_empty_anon_body_never_reaches_a_fallback_door() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|request| {
        if is_anon(request) {
            MockReply::json(v5_body())
        } else {
            MockReply::status(200)
        }
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "v5-first").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let requests = upstream.requests();
    let playback = playback_requests(&requests);
    assert_eq!(
        paths(&playback),
        [ANON_PLAYER_PATH],
        "a usable anonymous model needs no fallback"
    );
    assert!(is_anon(playback[0]));
    upstream.shutdown();
}

#[tokio::test]
async fn every_video_tab_payload_shape_reaches_the_shared_parser() {
    let flat = {
        let entry = json!({ "video_model": model() });
        let mut rows = serde_json::Map::new();
        rows.insert(VIDEO_ID.to_string(), entry);
        json!({ "code": 0, "data": Value::Object(rows) })
    };
    let embedded = {
        let entry = json!({ "video_model": model().to_string() });
        let mut rows = serde_json::Map::new();
        rows.insert(VIDEO_ID.to_string(), entry);
        json!({ "code": 0, "data": { "video_model_data": Value::Object(rows) } })
    };
    for (name, payload) in [("flat", flat), ("string model", embedded)] {
        let _guard = exclusive();
        let reply = payload.clone();
        let upstream = MockUpstream::start(with_identity_setup(move |request| {
            if is_tab(request) {
                MockReply::json(reply.clone())
            } else {
                MockReply::status(200)
            }
        }))
        .await;
        let (_dir, server) = server_with(&upstream, "tab-shape").await;
        let (status, body) = episode(&server, "").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert!(
            body["video_url"].as_str().is_some(),
            "{name}: the shared parser must find a playable url: {body}"
        );
        upstream.shutdown();
    }
}

#[tokio::test]
async fn a_rejected_video_tab_body_is_not_treated_as_a_playable_answer() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|request| {
        if is_tab(request) {
            // A business rejection: the door answered, but not with a model.
            MockReply::json(json!({"code": 100103, "data": {}}))
        } else {
            MockReply::status(200)
        }
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "tab-rejected").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(body["success"], false, "{body}");
    assert!(
        !body.to_string().contains("fqnovel") && !body.to_string().contains("https://"),
        "no upstream address may leak: {body}"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn every_door_empty_refreshes_anon_and_stays_bounded() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|_| MockReply::status(200))).await;
    let (_dir, server) = server_with(&upstream, "all-empty-rotate").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(body["success"], false, "{body}");

    let requests = upstream.requests();
    let playback = playback_requests(&requests);
    assert_eq!(
        paths(&playback),
        [
            ANON_PLAYER_PATH,
            ANON_PLAYER_PATH,
            ANON_PLAYER_PATH,
            V5_PATH,
            MODEL_PATH,
            MODEL_PATH,
            TAB_PATH,
            ANON_PLAYER_PATH,
            V5_PATH,
        ],
        "one bounded round plus the first attempt after the pooled rotation"
    );
    assert!(
        playback[..3].iter().all(|request| is_anon(request)),
        "the anonymous identity is refreshed once, then re-probed once"
    );
    let anonymous_id = device_of(playback[0]);
    let first_pool_id = device_of(playback[3]);
    assert_ne!(anonymous_id, first_pool_id);
    assert!(playback[3..7]
        .iter()
        .all(|request| device_of(request) == first_pool_id));
    assert_ne!(
        first_pool_id,
        device_of(playback[8]),
        "the empty round rotates the pooled identity before the eighth attempt"
    );
    assert_eq!(
        requests
            .iter()
            .filter(|request| request.path == common::DEVICE_REGISTER_PATH)
            .count(),
        2,
        "one registration plus one empty-response refresh"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_prefetch_never_probes_parked_doors_or_rotates() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|_| MockReply::status(200))).await;
    let (_dir, server) = server_with(&upstream, "prefetch-parked").await;

    // Foreground first: every door is empty and therefore parked.
    let (status, _) = episode(&server, "").await;
    assert_eq!(status, 500);
    let after_foreground = upstream.requests().len();
    assert!(after_foreground > 1);

    // A prefetch must not spend the foreground's failure budget or rotate.
    let (status, body) = episode(&server, "_playback_purpose=prefetch").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(
        upstream.requests().len(),
        after_foreground,
        "a prefetch over parked doors must not touch the upstream"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_second_all_empty_request_cannot_rotate_again_inside_the_cooldown() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|_| MockReply::status(200))).await;
    let (_dir, server) = server_with(&upstream, "rotate-cooldown").await;

    let (status, _) = episode(&server, "").await;
    assert_eq!(status, 500);
    let first_requests = upstream.requests();
    let after_first = first_requests.len();
    assert!(
        after_first >= 2,
        "the first round must have tried several doors"
    );
    let first_playback = playback_requests(&first_requests);
    let first_pool_id = device_of(first_playback[3]);

    let (status, _) = episode(&server, "").await;
    assert_eq!(status, 500);
    let all_requests = upstream.requests();
    let second = playback_requests(&all_requests)
        .into_iter()
        .skip(first_playback.len())
        .collect::<Vec<_>>();
    assert_eq!(
        second.len(),
        5,
        "every door is parked, so one probe per door is the whole request"
    );
    assert_eq!(
        paths(&second),
        [MODEL_PATH, MODEL_PATH, TAB_PATH, ANON_PLAYER_PATH, V5_PATH],
        "cooling doors are ordered by their recovery time"
    );
    assert_ne!(
        first_pool_id,
        device_of(second[0]),
        "the first round already rotated the pooled identity"
    );
    assert_eq!(
        all_requests.len() - after_first,
        second.len(),
        "no identity setup or hidden retry is added by the second request"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_parked_empty_door_is_skipped_by_the_next_foreground_request() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|request| {
        if is_anon(request) || is_v5(request) {
            // The v5 door refuses silently, so it gets parked for 30 s.
            MockReply::status(200)
        } else {
            MockReply::json(tab_body())
        }
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "parked-door").await;

    // First request: anon and v5 are empty, then the model door answers.
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let first = upstream.requests().len();
    assert_eq!(
        playback_requests(&upstream.requests()).len(),
        5,
        "anon refresh and re-probe, v5 empty, then the model door"
    );

    // Second request: the parked empty doors must not be retried.
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let second: Vec<_> = upstream.requests().into_iter().skip(first).collect();
    assert!(!second.is_empty());
    assert!(
        second
            .iter()
            .all(|request| !is_v5(request) && !is_anon(request)),
        "parked empty doors must be skipped, not retried"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn a_bytevc2_only_answer_tries_other_doors_before_one_identity_rotation() {
    let _guard = exclusive();
    for empty_fallbacks in [false, true] {
        reset_playback_route_state_for_tests();
        let upstream = MockUpstream::start(with_identity_setup(move |request| {
            if is_anon(request) {
                business_rejection()
            } else if (is_model(request) || is_v5(request))
                && device_of(request) != "0000000000000000"
            {
                MockReply::json(model_codec_body("h265"))
            } else if empty_fallbacks && !is_v5(request) {
                MockReply::status(200)
            } else if is_model(request) {
                MockReply::json(model_codec_body("bytevc2"))
            } else {
                MockReply::json(v5_codec_body("bytevc2"))
            }
        }))
        .await;
        let (_dir, server) = server_with(&upstream, "codec-retry-door").await;

        let (status, body) = episode(&server, "").await;
        assert_eq!(
            status,
            200,
            "{body}; {:?}",
            upstream
                .requests()
                .iter()
                .map(|request| (request.path.as_str(), device_of(request)))
                .collect::<Vec<_>>()
        );
        assert_eq!(
            body["video_url"], "https://example.invalid/h265-1080.mp4",
            "{body}"
        );

        let requests = upstream.requests();
        let playback = playback_requests(&requests);
        let legacy: Vec<_> = playback
            .iter()
            .copied()
            .filter(|request| !is_anon(request))
            .collect();
        let initial_legacy = if empty_fallbacks { 5 } else { 4 };
        assert_eq!(
            paths(&legacy)[initial_legacy..],
            [V5_PATH],
            "the replacement's v5 door answers after the initial legacy ladder: {body}"
        );
        assert!(is_v5(legacy[0]) && legacy[0].method == "POST");
        assert!(is_model(legacy[1]) && legacy[1].method == "POST");
        assert!(legacy[..initial_legacy]
            .iter()
            .all(|request| device_of(request) == device_of(legacy[0])));
        assert_ne!(
            device_of(legacy[0]),
            device_of(legacy[initial_legacy]),
            "the retry must step away from the identity whose lookup was undecodable"
        );
        upstream.shutdown();
    }
}

#[tokio::test]
async fn an_all_undecodable_answer_stays_terminal_and_bounded() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|_| {
        MockReply::json(v5_codec_body("bytevc2"))
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "codec-terminal").await;

    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(body["error"], "该视频暂不支持播放", "{body}");
    assert!(
        !body.to_string().contains("https://"),
        "no upstream address may leak: {body}"
    );
    let requests = upstream.requests();
    let playback = playback_requests(&requests);
    assert_eq!(
        paths(&playback),
        [
            ANON_PLAYER_PATH,
            V5_PATH,
            MODEL_PATH,
            MODEL_PATH,
            TAB_PATH,
            ANON_PLAYER_PATH,
            V5_PATH,
            MODEL_PATH,
        ],
        "five doors on the first identity, then three attempts on the replacement"
    );
    assert!(playback[1..5]
        .iter()
        .all(|request| device_of(request) == device_of(playback[1])));
    assert!(playback[6..]
        .iter()
        .all(|request| device_of(request) == device_of(playback[6])));
    assert_ne!(device_of(playback[1]), device_of(playback[6]));
    assert_ne!(device_of(playback[0]), device_of(playback[1]));
    assert!(playback
        .iter()
        .all(|request| !request.path.ends_with(".mp4")));
    upstream.shutdown();
}

#[tokio::test]
async fn an_undecodable_door_does_not_cool_or_rotate_when_the_next_door_recovers() {
    let _guard = exclusive();
    let v5_calls = Arc::new(AtomicUsize::new(0));
    let v5_counter = v5_calls.clone();
    let model_calls = Arc::new(AtomicUsize::new(0));
    let model_counter = model_calls.clone();
    let upstream = MockUpstream::start(with_identity_setup(move |request| {
        if is_anon(request) {
            MockReply::status(200)
        } else if is_model(request) {
            if model_counter.fetch_add(1, Ordering::SeqCst) == 0 {
                MockReply::json(model_codec_body("h265"))
            } else {
                MockReply::status(200)
            }
        } else if is_v5(request) && v5_counter.fetch_add(1, Ordering::SeqCst) == 0 {
            MockReply::json(v5_codec_body("bytevc2"))
        } else {
            MockReply::json(v5_body())
        }
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "codec-no-health-penalty").await;
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let requests = upstream.requests();
    let playback = playback_requests(&requests);
    assert_eq!(
        paths(&playback),
        [
            ANON_PLAYER_PATH,
            ANON_PLAYER_PATH,
            ANON_PLAYER_PATH,
            V5_PATH,
            MODEL_PATH
        ]
    );
    assert_eq!(device_of(playback[3]), device_of(playback[4]));
    assert_ne!(device_of(playback[0]), device_of(playback[3]));
    let after_first = requests.len();
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let second = upstream.requests();
    let second_playback: Vec<_> = second[after_first..]
        .iter()
        .filter(|request| !is_identity_setup(request))
        .collect();
    assert!(
        second_playback.iter().any(|request| is_v5(request)),
        "unplayable models do not cool a route"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn any_player_door_can_use_the_requests_single_reprobe() {
    let _guard = exclusive();
    for (selected, preceding_models) in [(MODEL_PATH, 0), (MODEL_PATH, 1), (TAB_PATH, 0)] {
        reset_playback_route_state_for_tests();
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = calls.clone();
        let upstream = MockUpstream::start(with_identity_setup(move |request| {
            if is_anon(request) {
                business_rejection()
            } else if request.path == selected {
                let selected_call = counter.fetch_add(1, Ordering::SeqCst);
                if selected_call < preceding_models {
                    MockReply::json(v5_codec_body("bytevc2"))
                } else if selected_call == preceding_models {
                    MockReply::status(200)
                } else {
                    MockReply::json(v5_body())
                }
            } else {
                MockReply::json(v5_codec_body("bytevc2"))
            }
        }))
        .await;
        let (_dir, server) = server_with(&upstream, "any-door-reprobe").await;
        let (status, body) = episode(&server, "").await;
        assert_eq!(status, 200, "{selected}: {body}");
        let requests = upstream.requests();
        let playback = playback_requests(&requests);
        let probes: Vec<_> = playback
            .iter()
            .copied()
            .filter(|request| request.path == selected)
            .skip(preceding_models)
            .collect();
        assert_eq!(probes.len(), 2, "{selected}");
        assert_eq!(device_of(probes[0]), device_of(probes[1]));
        let legacy: Vec<_> = playback
            .into_iter()
            .filter(|request| !is_anon(request))
            .collect();
        assert!(!legacy.is_empty());
        assert!(legacy
            .iter()
            .all(|request| device_of(request) == device_of(legacy[0])));
        upstream.shutdown();
    }
}

#[tokio::test]
async fn prefetch_never_recovers_codecs_or_refills_the_device_pool_after_auth_failure() {
    let _guard = exclusive();
    for auth_failure in [false, true] {
        reset_playback_route_state_for_tests();
        let upstream = MockUpstream::start(with_identity_setup(move |_| {
            if auth_failure {
                MockReply::status(401)
            } else {
                MockReply::json(v5_codec_body("bytevc2"))
            }
        }))
        .await;
        let dir = TempDir::new("prefetch-no-registration");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(2)).await;
        let (status, body) = episode(&server, "_playback_purpose=prefetch").await;
        assert_eq!(status, 500, "{body}");
        let requests = upstream.requests();
        let playback = playback_requests(&requests);
        assert_eq!(
            paths(&playback),
            [ANON_PLAYER_PATH],
            "prefetch uses one playback door and never walks the fallback ladder"
        );
        assert_eq!(
            server.ctx.pool.count().await,
            2,
            "prefetch must not refill the pooled device identity"
        );
        upstream.shutdown();
    }
}

#[tokio::test]
async fn missing_dimensions_or_addresses_continue_to_the_next_door() {
    let _guard = exclusive();
    for variant in [
        json!({"codec_type": "h264", "main_url": "https://example.invalid/missing-height.mp4", "vwidth": 1080}),
        json!({"codec_type": "h264", "vwidth": 1080, "vheight": 1920}),
    ] {
        reset_playback_route_state_for_tests();
        let bad = json!({"data": {"video_model": {"video_list": {"video_0": variant}}}});
        let upstream = MockUpstream::start(with_identity_setup(move |request| {
            if is_anon(request) {
                business_rejection()
            } else if is_model(request) {
                MockReply::json(model_codec_body("h265"))
            } else {
                MockReply::json(bad.clone())
            }
        }))
        .await;
        let (_dir, server) = server_with(&upstream, "missing-video-fields").await;
        let (status, body) = episode(&server, "").await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body["video_url"], "https://example.invalid/h265-1080.mp4");
        let requests = upstream.requests();
        let playback = playback_requests(&requests);
        assert_eq!(
            paths(&playback),
            [ANON_PLAYER_PATH, V5_PATH, MODEL_PATH,],
            "the malformed v5 answer continues to the single-episode door"
        );
        assert_eq!(device_of(playback[1]), device_of(playback[2]));
        assert_ne!(device_of(playback[0]), device_of(playback[1]));
        upstream.shutdown();
    }
}

#[tokio::test]
async fn an_empty_codec_replacement_stays_bounded_and_terminal() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(with_identity_setup(|request| {
        if is_anon(request) {
            business_rejection()
        } else if device_of(request) == "0000000000000000" {
            MockReply::json(v5_codec_body("bytevc2"))
        } else {
            MockReply::status(200)
        }
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "empty-codec-replacement").await;
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(body["error"], "该视频暂不支持播放");
    let requests = upstream.requests();
    let playback = playback_requests(&requests);
    assert_eq!(
        paths(&playback),
        [
            ANON_PLAYER_PATH,
            V5_PATH,
            MODEL_PATH,
            MODEL_PATH,
            TAB_PATH,
            ANON_PLAYER_PATH,
            V5_PATH,
            V5_PATH,
        ],
        "the codec rejection rotates once, then the replacement's re-probe is the eighth attempt"
    );
    assert!(playback[1..5]
        .iter()
        .all(|request| device_of(request) == device_of(playback[1])));
    assert!(playback[6..]
        .iter()
        .all(|request| device_of(request) == device_of(playback[6])));
    assert_ne!(device_of(playback[1]), device_of(playback[6]));
    upstream.shutdown();
}

#[tokio::test]
async fn all_cooling_doors_are_probed_until_the_last_one_recovers() {
    let _guard = exclusive();
    let recover = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let ready = recover.clone();
    let upstream = MockUpstream::start(with_identity_setup(move |request| {
        if ready.load(Ordering::SeqCst) && is_anon(request) {
            MockReply::json(v5_body())
        } else {
            MockReply::status(200)
        }
    }))
    .await;
    let (_dir, server) = server_with(&upstream, "cooling-last-door").await;
    assert_eq!(episode(&server, "").await.0, 500);
    let before = upstream.requests().len();
    recover.store(true, Ordering::SeqCst);
    let (status, body) = episode(&server, "").await;
    assert_eq!(status, 200, "{body}");
    let requests = upstream.requests();
    let after: Vec<_> = requests.iter().skip(before).collect();
    assert_eq!(after.len(), 4, "every cooling door must be probed");
    assert_eq!(
        after
            .iter()
            .map(|request| request.path.as_str())
            .collect::<Vec<_>>(),
        [MODEL_PATH, MODEL_PATH, TAB_PATH, ANON_PLAYER_PATH]
    );
    assert!(is_anon(after.last().expect("answering door")));
    upstream.shutdown();
}
