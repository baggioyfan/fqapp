//! 取流空包探针：注册一次性匿名身份，直连 v5 取流门，只报 status / body_len。
//!
//! 取流返回 `HTTP 200` 但 `body_len=0` 时，先跑它判断是签名层还是网络层：
//! 同样的身份与请求体，只要签名正确上游就会回十几 KB 的模型。2026-11-23 用它
//! 定了 Medusa proto 字段 21 必须发 312（官方 zigzag 值）而不是 377 的案。
//!
//! ```text
//! PROBE_ID=<video_id> cargo test --test live_v5_probe -- --ignored --nocapture
//! ```

use std::io::Write;

use fqapi_core::device::register::Registrar;
use fqapi_core::sign::v5::{sign_playback_v5, V5Identity};

const V5_URL: &str =
    "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1";

fn body(video_id: &str) -> Vec<u8> {
    let plain = serde_json::to_vec(&serde_json::json!({
        "biz_param": {
            "detail_page_version": 0,
            "device_level": 5,
            "disable_digg_stat": false,
            "disable_video_relate_book": false,
            "need_all_video_definition": true,
            "need_mp4_align": false,
            "use_os_player": false,
            "use_server_dns": false,
            "video_platform": 1024,
        },
        "mixed_video_id_map": { "1004": [video_id] },
        "dr_scene": "player",
    }))
    .expect("json");
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(&plain).expect("gzip");
    encoder.finish().expect("gzip finish")
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn probe_v5_door() {
    let video_id = std::env::var("PROBE_ID").expect("PROBE_ID");
    let registrar = Registrar::new().expect("registrar");
    let device = registrar.register().await.expect("register");
    eprintln!(
        "registered: device_id_len={} install_id_len={} secret_key_len={}",
        device.device_id.len(),
        device.install_id.len(),
        device.secret_key.len()
    );

    let identity = V5Identity {
        device_id: &device.device_id,
        install_id: &device.install_id,
        cdid: &device.cdid,
    };
    let compressed = body(&video_id);
    let signed = sign_playback_v5(V5_URL, &compressed, &identity).expect("sign");
    eprintln!("signed query fields: {}", signed.url.split('&').count());

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .expect("client");
    let mut request = client.post(&signed.url).body(compressed);
    for (name, value) in &signed.headers {
        request = request.header(name, value);
    }
    let response = request.send().await.expect("send");
    let status = response.status();
    let bytes = response.bytes().await.expect("body");
    eprintln!("RESULT status={} body_len={}", status, bytes.len());
    let head = String::from_utf8_lossy(&bytes[..bytes.len().min(160)]);
    eprintln!("HEAD {}", head.replace('\n', " "));
}
