//! Exercise codec rejection through the real dispatcher, including the raw
//! response and download fallbacks that extractor-only tests cannot cover.

mod common;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use serde_json::{json, Value};

const ALLOWED_URL: &str = "https://example.invalid/h264.mp4";
const REJECTED_URL: &str = "https://example.invalid/bytevc2.mp4";
const SPADE_A: &str = "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==";
const KEY_HEX: &str = "4990a92de837e29e18031a370ab744e6";

fn response_shapes(variants: Vec<Value>) -> Vec<(&'static str, Value)> {
    let video_map: serde_json::Map<String, Value> = variants
        .iter()
        .enumerate()
        .map(|(i, v)| (format!("video_{i}"), v.clone()))
        .collect();
    let shortplay = json!({"key_seed": "AAAA", "video_list": video_map});
    let array_model = json!({"video_list": variants});
    vec![
        (
            "shortplay object",
            json!({"data": {"video_model": shortplay}}),
        ),
        (
            "shortplay string",
            json!({"data": {"video_model": shortplay.to_string()}}),
        ),
        (
            "nested shortplay",
            json!({"data": {"episode": {"video_model": shortplay}}}),
        ),
        (
            "array object",
            json!({"data": {"video_model": array_model}}),
        ),
        (
            "nested array string",
            json!({"data": {"episode": {"video_model": array_model.to_string()}}}),
        ),
        (
            "phoenix play info",
            json!({"data": {"video_info_list_map": {"episode": [
                {"play_info_list": variants}
            ]}}}),
        ),
    ]
}

async fn request_video(server: &Server, query: &str) -> (u16, Value) {
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: "/api/v1/videos/episode".to_string(),
            query: query.to_string(),
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

fn assert_rejected(status: u16, body: &Value, context: &str) {
    assert_eq!(status, 500, "{context}: {body}");
    assert_eq!(body["success"], false, "{context}: {body}");
    assert_eq!(body["error"], "该视频暂不支持播放", "{context}: {body}");
    assert!(!body.to_string().contains("https://"), "{context}: {body}");
}

#[tokio::test]
async fn bytevc2_only_is_terminal_across_response_shapes_and_modes() {
    for codec in [
        json!({"codec_type": "ByTeVc2"}),
        json!({"video_meta": {"codec_type": "BYTEVC2"}}),
        json!({"gear_des_key": "bytevc2_1080p"}),
    ] {
        let mut variant = codec;
        variant["main_url"] = json!(REJECTED_URL);
        for (name, payload) in response_shapes(vec![variant]) {
            let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
            let dir = TempDir::new("video-codec-reject");
            let server =
                build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
            for mode in ["mode=stream", ""] {
                let (status, body) = request_video(&server, mode).await;
                assert_rejected(status, &body, &format!("{name}, {mode}"));
            }
            assert!(upstream
                .requests()
                .iter()
                .all(|r| !r.path.ends_with(".mp4")));
        }
    }
}

#[tokio::test]
async fn missing_or_invalid_seed_cannot_hide_codec_rejection() {
    for seed in [Value::Null, json!(""), json!("invalid!")] {
        let payload = json!({"data": {"video_model": {
            "key_seed": seed,
            "video_list": {"video_1": {
                "codec_type": "bytevc2", "main_url": REJECTED_URL
            }}
        }}});
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-seed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_rejected(status, &body, "invalid seed");
    }
}

#[tokio::test]
async fn mixed_variants_keep_h264_preference_across_response_shapes() {
    // Put H.264 first: blindly taking the last array entry would pick bytevc2,
    // and filtering without ranking would pick H.265 at the same quality.
    let variants = vec![
        json!({"main_url": ALLOWED_URL, "codec_type": "h264", "vwidth": 720}),
        json!({"main_url": "https://example.invalid/h265.mp4", "codec_type": "h265", "vwidth": 720}),
        json!({"main_url": REJECTED_URL, "codec_type": "bytevc2", "vwidth": 1080}),
    ];
    for (name, payload) in response_shapes(variants) {
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-mixed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert_eq!(body["video_url"], ALLOWED_URL, "{name}: {body}");
        assert!(!body.to_string().contains(REJECTED_URL), "{name}: {body}");
    }
}

#[tokio::test]
async fn unrecognized_payload_keeps_legacy_raw_response_compatibility() {
    let payload = json!({"code": 0, "data": {"legacy": {"main_url": ALLOWED_URL}}});
    let expected = payload.clone();
    let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
    let dir = TempDir::new("video-codec-legacy");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    for mode in ["mode=stream", ""] {
        let (status, body) = request_video(&server, mode).await;
        assert_eq!(status, 200);
        assert_eq!(body, expected);
    }
}

#[tokio::test]
async fn fallback_rejection_cannot_return_the_original_model_url() {
    let model = json!({
        "fallback_api": "https://example.invalid/fallback",
        "video_list": [{
            "main_url": "https://example.invalid/original.mp4",
            "encrypt_info": {"encrypt": true}
        }]
    });
    for data in [
        json!({"video_model": model}),
        json!({"episode": {"video_model": model.to_string()}}),
    ] {
        let upstream = MockUpstream::start(move |req| {
            if req.path == "/fallback" {
                return MockReply::json(json!({"video_info": {"data": {
                    "key_seed": "AAAA", "video_list": {"video_1": {
                        "main_url": REJECTED_URL, "codec_type": "bytevc2"
                    }}
                }}}));
            }
            MockReply::json(json!({"data": data}))
        })
        .await;
        let dir = TempDir::new("video-codec-fallback");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        for mode in ["mode=stream", ""] {
            let (status, body) = request_video(&server, mode).await;
            assert_rejected(status, &body, "fallback rejected");
        }
        let requests = upstream.requests();
        assert!(requests.iter().any(|r| r.path == "/fallback"));
        assert!(requests.iter().all(|r| !r.path.ends_with(".mp4")));
    }
}

#[tokio::test]
async fn download_failure_returns_only_the_selected_url_and_its_key() {
    let upstream = MockUpstream::start(|req| {
        if req.path.ends_with(".mp4") {
            return MockReply::status(500);
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA", "video_list": {
                "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A},
                "video_2": {"main_url": REJECTED_URL, "codec_type": "bytevc2"}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-codec-download");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200);
    assert_eq!(body["video_url"], ALLOWED_URL);
    assert_eq!(body["key_hex"], KEY_HEX);
    assert!(!body.to_string().contains(REJECTED_URL));
    let requests = upstream.requests();
    assert!(requests.iter().any(|r| r.path == "/h264.mp4"));
    assert!(requests.iter().all(|r| r.path != "/bytevc2.mp4"));
}

#[tokio::test]
async fn successful_download_keeps_the_local_source_contract() {
    let upstream = MockUpstream::start(|req| {
        if req.path == "/h264.mp4" {
            return MockReply {
                status: 200,
                headers: vec![],
                body: b"video fixture".to_vec(),
            };
        }
        MockReply::json(json!({"data": {"episode": {"video_model": {
            "video_list": [{"main_url": ALLOWED_URL, "codec_type": "h264"}]
        }}}}))
    })
    .await;
    let dir = TempDir::new("video-codec-local");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200);
    assert_eq!(body["video_url"], "/src/episode.mp4");
    assert_eq!(
        body["video_info"]["data"]["video_list"]["video_1"]["main_url"],
        "/src/episode.mp4"
    );
    assert_eq!(
        std::fs::read(dir.join("src/episode.mp4")).unwrap(),
        b"video fixture"
    );
}

/// The shortplay list stops at 720P; the model's `fallback_api` list carries
/// the top tier. The stream response must merge both, or the quality panel
/// silently loses a row (measured 2026-10-12 on the live upstream).
#[tokio::test]
async fn stream_variants_merge_the_fallback_list_so_the_top_tier_survives() {
    let upstream = MockUpstream::start(|req| {
        if req.path == "/fallback" {
            return MockReply::json(json!({"video_info": {"data": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": "https://example.invalid/360.mp4",
                        "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_2": {"main_url": "https://example.invalid/720.mp4",
                        "vwidth": 720, "vheight": 1280, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_3": {"main_url": "https://example.invalid/1080.mp4",
                        "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "fallback_api": "https://example.invalid/fallback",
            "video_list": {
                "video_1": {"main_url": "https://example.invalid/360.mp4",
                    "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A},
                "video_2": {"main_url": "https://example.invalid/720.mp4",
                    "vwidth": 720, "vheight": 1280, "codec_type": "bytevc1", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-variant-merge");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "mode=stream").await;
    assert_eq!(status, 200, "{body}");
    let names: Vec<&str> = body["variants"]
        .as_array()
        .expect("variants array")
        .iter()
        .map(|v| v["name"].as_str().expect("variant name"))
        .collect();
    assert_eq!(names, ["1080P", "720P", "360P"], "{body}");
    assert_eq!(
        body["variants"][0]["url"],
        "https://example.invalid/1080.mp4"
    );
    assert_eq!(
        body["variants"][0]["key_hex"].as_str().expect("key").len(),
        32,
        "{body}"
    );
    assert!(upstream.requests().iter().any(|r| r.path == "/fallback"));
}

/// The fallback list's low tiers are often bytevc2. Merging must not smuggle
/// them past the codec gate.
#[tokio::test]
async fn stream_variants_do_not_merge_bytevc2_tiers() {
    let upstream = MockUpstream::start(|req| {
        if req.path == "/fallback" {
            return MockReply::json(json!({"video_info": {"data": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": "https://example.invalid/1080.mp4",
                        "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_2": {"main_url": REJECTED_URL,
                        "vwidth": 720, "vheight": 1280, "codec_type": "bytevc2", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "fallback_api": "https://example.invalid/fallback",
            "video_list": {
                "video_1": {"main_url": ALLOWED_URL,
                    "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-variant-gate");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "mode=stream").await;
    assert_eq!(status, 200, "{body}");
    let names: Vec<&str> = body["variants"]
        .as_array()
        .expect("variants array")
        .iter()
        .map(|v| v["name"].as_str().expect("variant name"))
        .collect();
    assert_eq!(names, ["1080P", "360P"], "{body}");
    assert!(!body.to_string().contains(REJECTED_URL), "{body}");
}

/// 上游按设备分流：同一集的数据可能这一份只给 bytevc2（H.266，播放链路上
/// 没有解码器），下一份给 h264/h265 多档。实测 2026-11-20：同一集、同一个
/// 进程连打 20 次，6 次拿到多档、14 次只有 bytevc2；好设备的表现是稳定的，
/// 差的连打 9 次全是 bytevc2。所以「全档 bytevc2」不是终止状态，换一份响应
/// 就能过——必须走重试，否则用户看到的是这一集的真实片源被说成
/// 「播放服务暂时不可用」。
#[tokio::test]
async fn bytevc2_only_response_is_retried_until_a_playable_roll_arrives() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    let rolls = Arc::new(AtomicUsize::new(0));
    let counter = rolls.clone();
    let upstream = MockUpstream::start(move |req| {
        // 只数取流请求：设备注册也走这个 mock。
        if !req.path.contains("multi_video_model") {
            return MockReply::json(json!({"data": {}}));
        }
        let roll = counter.fetch_add(1, Ordering::SeqCst);
        if roll == 0 {
            return MockReply::json(json!({"data": {"video_model": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": REJECTED_URL, "codec_type": "bytevc2"}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-codec-retry-roll");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server, "mode=stream").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["video_url"], ALLOWED_URL, "{body}");
    assert!(
        rolls.load(Ordering::SeqCst) >= 2,
        "a bytevc2-only roll must be re-requested, saw {} playback requests",
        rolls.load(Ordering::SeqCst)
    );
}

/// 上游按设备身份分流码流，而一台设备的分流是稳定的（2026-11-20 实测：好设备
/// 3/3 可解，差的连打 9 次全拒）。既然身份本身就是线索，就不该每集都从头重掷：
/// 第一集学到「哪台设备给得出多档」之后，下一集必须直接用那台——否则用户在
/// 每一集上都要多等 3–8 次取流，还得赌运气。
#[tokio::test]
async fn a_device_that_served_tiers_is_preferred_by_the_next_request() {
    // 池里 5 台设备，只有 3 号给得出可解码档位。
    const GOOD_DEVICE: &str = "device_id=0000000000000003";
    let upstream = MockUpstream::start(|req| {
        if !req.path.contains("multi_video_model") {
            return MockReply::json(json!({"data": {}}));
        }
        if req.query.contains(GOOD_DEVICE) {
            return MockReply::json(json!({"data": {"video_model": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {"main_url": REJECTED_URL, "codec_type": "bytevc2"}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-codec-device-preference");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server, "video_id=first-episode&mode=stream").await;
    assert_eq!(status, 200, "{body}");
    let after_first = playback_requests(&upstream);
    assert!(
        after_first > 1,
        "the first episode has to roll onto the playable device, saw {after_first} requests"
    );

    let (status, body) = request_video(&server, "video_id=second-episode&mode=stream").await;
    assert_eq!(status, 200, "{body}");
    let second_episode = playback_requests(&upstream) - after_first;
    assert_eq!(
        second_episode, 1,
        "the device that served tiers must be reused instead of rolled again, saw {second_episode} playback requests"
    );
}

fn playback_requests(upstream: &MockUpstream) -> usize {
    upstream
        .requests()
        .iter()
        .filter(|request| request.path.contains("multi_video_model"))
        .count()
}

/// 池子里只有一台给得出可解档位，其余全拒。重掷必须把池子扫一遍才能碰到它 ——
/// 只排除「上一台」会出问题：两台设备的 `last_used` 落在同一秒时排序不倒，
/// 排除 A 拿到 B、排除 B 又拿回 A，好设备永远轮不到（平板上实测就是这个：
/// 一条请求 9 次重掷全落在同一台，答复一模一样）。
#[tokio::test]
async fn a_pool_of_rejecting_devices_still_reaches_the_only_playable_one() {
    const GOOD_DEVICE: &str = "device_id=0000000000000004";
    let upstream = MockUpstream::start(|req| {
        if !req.path.contains("multi_video_model") {
            return MockReply::json(json!({"data": {}}));
        }
        if req.query.contains(GOOD_DEVICE) {
            return MockReply::json(json!({"data": {"video_model": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {"main_url": REJECTED_URL, "codec_type": "bytevc2"}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-codec-sweep-pool");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let (status, body) = request_video(&server, "video_id=one-episode&mode=stream").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["video_url"], ALLOWED_URL, "{body}");
    assert!(
        playback_requests(&upstream) >= 5,
        "a pool of rejecting devices must be swept before giving up, saw {} playback requests",
        playback_requests(&upstream)
    );
}

/// 单档取流（`mode` 不带 stream）遇到全档 bytevc2 时，要换一台设备再问一次。
///
/// 上游按设备分发档位：同一集在 A 设备上全是 bytevc2（播放链路上没有解码器），
/// 在 B 设备上是 h264。第一次就报「该视频暂不支持播放」，等于把「这台设备给的
/// 档位解不了」当成「这一集播不了」——日志里那条错误连续出现上百次时，用户侧
/// 表现就是整部剧都打不开。重试只做一次，且必须排除刚应答的那台设备。
#[tokio::test]
async fn single_mode_asks_another_device_before_declaring_codec_rejection() {
    const GOOD_DEVICE: &str = "device_id=0000000000000001";
    let upstream = MockUpstream::start(|req| {
        if req.path == "/h264.mp4" {
            return MockReply {
                status: 200,
                headers: vec![],
                body: b"video fixture".to_vec(),
            };
        }
        if !req.path.contains("multi_video_model") {
            return MockReply::json(json!({"data": {}}));
        }
        if req.query.contains(GOOD_DEVICE) {
            return MockReply::json(json!({"data": {"video_model": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {"main_url": REJECTED_URL, "codec_type": "bytevc2"}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-codec-retry");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(2)).await;

    let (status, body) = request_video(&server, "video_id=one-episode").await;
    assert_eq!(status, 200, "{body}");
    // 走到下载契约说明这一次解析拿到的是可播档位，而不是「暂不支持播放」。
    assert_eq!(body["video_url"], "/src/episode.mp4", "{body}");
    assert_eq!(
        std::fs::read(dir.join("src/episode.mp4")).unwrap(),
        b"video fixture"
    );
    assert!(
        playback_requests(&upstream) >= 2,
        "the second attempt has to leave the rejecting device, saw {} playback requests",
        playback_requests(&upstream)
    );
}

/// 取流请求里声明的设备档位决定上游下发哪一套编码。
///
/// 2026-11-20 实测（真上游，同一集，逐台设备逐档位）：`device_level=3` 时注册
/// 设备拿到的五档全是 bytevc2（H.266，播放链路上没有解码器），整集必然以
/// 「该视频暂不支持播放」结束；4/5/6 时每一台设备都拿到 h265_hvc1 的五档。
/// 所以这条钉住「请求体里必须是高档位」，免得以后有人按官方默认值把它改回 3
/// —— 那会让所有剧集又变回播不了，而且看起来像是片源问题。
#[tokio::test]
async fn the_playback_request_declares_a_device_level_that_gets_h265() {
    let upstream = MockUpstream::start(|req| {
        if !req.path.contains("multi_video_model") {
            return MockReply::json(json!({"data": {}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-device-level");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(3)).await;

    let (status, body) = request_video(&server, "video_id=level-episode&mode=stream").await;
    assert_eq!(status, 200, "{body}");

    let playback = upstream
        .requests()
        .into_iter()
        .find(|request| request.path.contains("multi_video_model"))
        .expect("a playback request");
    let mut decoder = flate2::read::GzDecoder::new(playback.body.as_slice());
    let mut plain = String::new();
    std::io::Read::read_to_string(&mut decoder, &mut plain).expect("gzipped playback body");
    let parsed: serde_json::Value = serde_json::from_str(&plain).expect("playback body json");
    assert_eq!(
        parsed["biz_param"]["device_level"].as_i64(),
        Some(5),
        "device_level=3 makes upstream serve bytevc2 (H.266), which this player cannot decode: {plain}"
    );
}
