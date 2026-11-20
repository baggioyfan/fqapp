//! 真上游取流响应体转储（排障用，默认 ignore）。
//!
//! 用来回答「这份响应里到底有哪些档位、哪些编码」这类问题：把原始 JSON 落到
//! 文件，再离线比对「可解设备」与「只给 bytevc2 设备」的差异。
//!
//! ```text
//! DUMP_ID=<video_id> DUMP_POOL_IDS=<device_id> \
//!   cargo test --manifest-path rust/Cargo.toml --test live_body_dump -- --ignored --nocapture
//! ```

mod common;

use std::io::Write;

use common::{build_server, TempDir};
use serde_json::json;

const V5_PLAYER_URL: &str =
    "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1";

fn body(video_id: &str, extra: &serde_json::Value) -> Vec<u8> {
    let mut biz = json!({
        "detail_page_version": 0,
        "device_level": 3,
        "disable_digg_stat": false,
        "disable_video_relate_book": false,
        "need_all_video_definition": true,
        "need_mp4_align": false,
        "use_os_player": false,
        "use_server_dns": false,
        "video_platform": 1024,
    });
    if let (Some(dst), Some(src)) = (biz.as_object_mut(), extra.as_object()) {
        for (k, v) in src {
            dst.insert(k.clone(), v.clone());
        }
    }
    let plain = serde_json::to_vec(&json!({
        "biz_param": biz,
        "mixed_video_id_map": { "1004": [video_id] },
        "dr_scene": "player",
    }))
    .unwrap();
    let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    enc.write_all(&plain).unwrap();
    enc.finish().unwrap()
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn dump_playback_body() {
    let video_id = std::env::var("DUMP_ID").expect("DUMP_ID");
    let device_id = std::env::var("DUMP_POOL_IDS").expect("DUMP_POOL_IDS");
    let extra: serde_json::Value = std::env::var("DUMP_BIZ")
        .ok()
        .map(|raw| serde_json::from_str(&raw).expect("DUMP_BIZ json"))
        .unwrap_or_else(|| json!({}));

    let pool = json!({
        "android": [{
            "device_id": device_id,
            "install_id": "9000000000000000001",
            "secret_key": format!("{:032x}", 0),
            "platform": "android",
            "status": "active",
            "created_time": "2026-01-01 00:00:00",
            "last_used": "2026-01-01 00:00:00",
            "use_count": 0,
            "cdid": "cdid-0",
        }],
        "last_update": "2026-01-01 00:00:00",
    })
    .to_string();

    let dir = TempDir::new("body-dump");
    let srv = build_server(&dir, None, &[], &[], &pool).await;
    let raw = srv
        .ctx
        .up
        .v5_playback(V5_PLAYER_URL, &body(&video_id, &extra))
        .await
        .expect("playback request");

    let text = String::from_utf8_lossy(&raw).into_owned();
    let path = format!(
        "/tmp/fq-body-{}-{}.json",
        video_id,
        if device_id.chars().all(|c| c == '0') {
            "zero"
        } else {
            "real"
        }
    );
    std::fs::write(&path, &text).unwrap();
    println!("wrote {path} ({} bytes)", text.len());

    if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
        let video_list = value
            .pointer("/data/video_model/video_list")
            .and_then(|v| v.as_object());
        if let Some(list) = video_list {
            for (key, tier) in list {
                println!(
                    "tier {key}: codec={:?} w={:?} h={:?} url_kind={}",
                    tier.get("codec_type").and_then(|v| v.as_str()),
                    tier.get("vwidth").and_then(|v| v.as_i64()),
                    tier.get("vheight").and_then(|v| v.as_i64()),
                    if tier.get("main_url").is_some() {
                        "main_url"
                    } else {
                        "-"
                    }
                );
            }
        } else {
            println!(
                "no video_list; top keys: {:?}",
                value.as_object().map(|o| o.keys().collect::<Vec<_>>())
            );
        }
    }
}
