//! 真上游探针：逐集打取流接口，打印结果（成功档位 / 失败原因）。
//!
//! 默认不跑，只在排障时显式触发：
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test live_codec_probe -- --ignored --nocapture
//! ```
//!
//! - `PROBE_SERIES=<series_id>`：先取剧集详情，再逐集探该剧（默认探前 40 集）
//! - `PROBE_LIMIT=<n>`：限制探测集数
//! - 不给 `PROBE_SERIES` 时探 `IDS` 里写死的集。

mod common;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::{Params, Server};
use serde_json::Value;

/// 最近在平板上播过的剧集（取自 WebDAV 同步里的观看记录）。
const IDS: &[&str] = &[
    "7706799298419117080",
    "7706799297538296856",
    "7706799297127271448",
    "7706799297269877784",
    "7706799297009830936",
    "7706799295357258776",
    "7706799295285955608",
    "7706799294778444824",
    "7706799294971382808",
    "7706799294879124504",
];

fn collect_episode_ids(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            for key in ["vid", "video_id", "item_id"] {
                if let Some(id) = map.get(key).and_then(Value::as_str) {
                    if id.len() > 12
                        && id.chars().all(|c| c.is_ascii_digit())
                        && !out.iter().any(|e| e == id)
                    {
                        out.push(id.to_string());
                    }
                }
            }
            for nested in map.values() {
                collect_episode_ids(nested, out);
            }
        }
        Value::Array(rows) => {
            for nested in rows {
                collect_episode_ids(nested, out);
            }
        }
        _ => {}
    }
}

async fn probe_one(srv: &Server, video_id: &str) -> bool {
    let video = srv.handler("video").expect("video route");
    let params = Params::from_pairs(vec![
        ("video_id".to_string(), video_id.to_string()),
        ("mode".to_string(), "stream".to_string()),
    ]);
    match video(&srv.ctx, &params).await {
        Ok(value) => {
            let names: Vec<String> = value["variants"]
                .as_array()
                .map(|rows| {
                    rows.iter()
                        .map(|row| format!("{}:{}", row["name"], row["height"]))
                        .collect()
                })
                .unwrap_or_default();
            println!("OK  {video_id} variants=[{}]", names.join(","),);
            true
        }
        Err(error) => {
            println!("ERR {video_id} {}", error.message());
            false
        }
    }
}

#[tokio::test]
#[ignore = "hits the live fanqie upstream"]
async fn probe_stream_tiers() {
    let dir = TempDir::new("codec-live");
    let pool_size = std::env::var("PROBE_POOL")
        .ok()
        .and_then(|n| n.parse::<usize>().ok())
        .unwrap_or(5);
    // PROBE_POOL_IDS 用「一台设备一个池」的方式逐台测：handler 有「优先已知可解
    // 设备」的逻辑，一个池里放多台时只要第一台成功就永远试不到其余的。
    let pool = match std::env::var("PROBE_POOL_IDS") {
        Ok(raw) => {
            let devices: Vec<serde_json::Value> = raw
                .split(',')
                .map(str::trim)
                .filter(|id| !id.is_empty())
                .enumerate()
                .map(|(i, id)| {
                    serde_json::json!({
                        "device_id": id,
                        "install_id": format!("{}", 9_000_000_000_000_000_000u64 + i as u64),
                        "secret_key": format!("{:032x}", i),
                        "platform": "android",
                        "status": "active",
                        "created_time": "2026-01-01 00:00:00",
                        "last_used": "2026-01-01 00:00:00",
                        "use_count": 0,
                        "cdid": format!("cdid-{i}"),
                    })
                })
                .collect();
            serde_json::json!({ "android": devices, "last_update": "2026-01-01 00:00:00" })
                .to_string()
        }
        Err(_) => pool_json(pool_size),
    };
    let srv = build_server(&dir, None, &[], &[], &pool).await;

    let mut ids: Vec<String> = Vec::new();
    if let Ok(one) = std::env::var("PROBE_ID") {
        ids.push(one);
    } else if let Ok(series) = std::env::var("PROBE_SERIES") {
        let detail = srv.handler("video_detail").expect("video_detail route");
        let params = Params::from_pairs(vec![("series_id".to_string(), series.clone())]);
        match detail(&srv.ctx, &params).await {
            Ok(value) => collect_episode_ids(&value, &mut ids),
            Err(error) => {
                println!("detail ERR {}", error.message());
                return;
            }
        }
        println!("series {series}: {} episodes", ids.len());
    } else {
        ids.extend(IDS.iter().map(|id| id.to_string()));
    }

    let limit = std::env::var("PROBE_LIMIT")
        .ok()
        .and_then(|n| n.parse::<usize>().ok())
        .unwrap_or(40);
    let repeat = std::env::var("PROBE_REPEAT")
        .ok()
        .and_then(|n| n.parse::<usize>().ok())
        .unwrap_or(1);
    let mut failures = 0usize;
    let mut total = 0usize;
    for _ in 0..repeat {
        for (index, id) in ids.iter().take(limit).enumerate() {
            print!("ep{:>3}  ", index + 1);
            total += 1;
            if !probe_one(&srv, id).await {
                failures += 1;
            }
        }
    }
    println!("probed {total} requests, failures={failures}");
}
