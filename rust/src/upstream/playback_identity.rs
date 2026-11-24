//! Anonymous playback device registration and process-local caching.
//!
//! Ported from `Amor5207/lvguo-tv` v2.0.8 (commit `32fcdfdb`):
//! `web/internal/lvguoplay/minireel_single_model.go`,
//! `web/internal/lvguoplay/passport_device.go`, and
//! `web/internal/lvguoplay/passport_sign.go`. The project is GPL-3.0 like this
//! repository; the wire constants and field layout are kept byte-for-byte.
//!
//! This identity is deliberately separate from the persistent `DevicePool`:
//! it exists only for playback, is never persisted, and its refresh policy is
//! owned here instead of being inferred from pooled-device usage.

use std::time::{Duration, Instant};

use base64::Engine as _;
use md5::{Digest, Md5};
use rand::Rng;
use serde_json::{json, Map, Value};
use tokio::sync::Mutex;

use crate::crypto::gzip;
use crate::device::crypto::{
    normalize_tt_encrypt_gzip_header, random_hex_lower, tt_decrypt_response, tt_encrypt, uuid_v4,
};
use crate::device::register::sorted_query;
use crate::sign::gorgon::generate_v5_gorgon;
use crate::upstream::http::HttpTransport;

const DEVICE_REGISTER_BASE: &str = "https://log5-applog-lq.fqnovel.com";
const DEVICE_ACTIVATE_BASE: &str = "https://log5-applog-lf.fqnovel.com";
const DEVICE_REGISTER_PATH: &str = "/service/2/device_register/";
const DEVICE_ACTIVATE_PATH: &str = "/service/2/app_alert_check/";
const MINI_REEL_UA: &str = "com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; 23127PN0CC; Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)";

const IDENTITY_TTL: Duration = Duration::from_secs(2 * 60 * 60);
const REGISTER_BACKOFF: Duration = Duration::from_secs(30);
const EMPTY_REFRESH_INTERVAL: Duration = Duration::from_secs(10 * 60);
const REGISTER_TIMEOUT: Duration = Duration::from_secs(4);
const ACTIVATION_TIMEOUT: Duration = Duration::from_secs(1);
const REGISTER_RESPONSE_LIMIT: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PlaybackDevice {
    pub device_id: String,
    pub install_id: String,
    pub cdid: String,
    pub openudid: String,
    pub clientudid: String,
    pub egdi: String,
}

#[derive(Debug, Default)]
struct IdentityState {
    device: Option<PlaybackDevice>,
    expires_at: Option<Instant>,
    last_empty_refresh: Option<Instant>,
    register_blocked_until: Option<Instant>,
}

/// Lazily registers and reuses one anonymous playback device per process.
pub(crate) struct PlaybackIdentity {
    http: HttpTransport,
    state: Mutex<IdentityState>,
    mock_origin: Option<String>,
}

impl PlaybackIdentity {
    pub(crate) fn new(mock_origin: Option<String>) -> Result<Self, String> {
        Ok(Self {
            http: HttpTransport::new(REGISTER_TIMEOUT.as_secs())?,
            state: Mutex::new(IdentityState::default()),
            mock_origin,
        })
    }

    pub(crate) async fn current(&self) -> Result<PlaybackDevice, String> {
        let mut state = self.state.lock().await;
        if let Some(device) = state.device.as_ref() {
            if state
                .expires_at
                .is_some_and(|expires_at| Instant::now() < expires_at)
            {
                return Ok(device.clone());
            }
        }
        self.register_locked(&mut state).await
    }

    /// Refreshes only when the empty response belongs to the cached identity
    /// and the previous refresh is at least ten minutes old. The first empty
    /// response after registration is allowed to refresh immediately.
    pub(crate) async fn refresh_after_empty(
        &self,
        failed_device_id: &str,
    ) -> Result<Option<PlaybackDevice>, String> {
        let mut state = self.state.lock().await;
        let Some(device) = state.device.as_ref() else {
            return Ok(None);
        };
        if device.device_id != failed_device_id {
            return Ok(None);
        }
        let now = Instant::now();
        if state
            .last_empty_refresh
            .is_some_and(|last| now.duration_since(last) < EMPTY_REFRESH_INTERVAL)
        {
            return Ok(None);
        }
        state.last_empty_refresh = Some(now);
        state.device = None;
        state.expires_at = None;
        self.register_locked(&mut state).await.map(Some)
    }

    async fn register_locked(&self, state: &mut IdentityState) -> Result<PlaybackDevice, String> {
        let now = Instant::now();
        if state
            .register_blocked_until
            .is_some_and(|blocked_until| now < blocked_until)
        {
            return Err("playback device registration is cooling down".to_string());
        }
        match tokio::time::timeout(REGISTER_TIMEOUT, self.register()).await {
            Ok(Ok(device)) => {
                log::info!("playback identity event=register result=ok cached=true");
                state.device = Some(device.clone());
                state.expires_at = Some(Instant::now() + IDENTITY_TTL);
                state.register_blocked_until = None;
                Ok(device)
            }
            Ok(Err(error)) => {
                log::warn!("playback identity event=register result=failed reason={error}");
                state.register_blocked_until = Some(Instant::now() + REGISTER_BACKOFF);
                Err(error)
            }
            Err(_) => {
                log::warn!("playback identity event=register result=timeout");
                state.register_blocked_until = Some(Instant::now() + REGISTER_BACKOFF);
                Err("playback device registration timed out".to_string())
            }
        }
    }

    async fn register(&self) -> Result<PlaybackDevice, String> {
        let now_ms = crate::timeutil::now_millis();
        let stamp = now_ms;
        let cdid = uuid_v4();
        let clientudid = uuid_v4();
        let openudid = random_hex_lower(16);
        let seed: [u8; 32] = rand::thread_rng().gen();

        let mut header = Map::new();
        for (key, value) in [
            ("aid", json!(8662)),
            ("access", json!("wifi")),
            ("app_version", json!("7.3.9.32")),
            ("app_version_minor", json!("7.3.9.32")),
            ("channel", json!("xiaomi_8662_64")),
            ("device_brand", json!("Xiaomi")),
            ("device_manufacturer", json!("Xiaomi")),
            ("device_model", json!("23127PN0CC")),
            ("device_category", json!("phone")),
            ("device_platform", json!("android")),
            ("os", json!("Android")),
            ("os_api", json!(34)),
            ("os_version", json!("14")),
            ("density_dpi", json!(460)),
            ("display_density", json!("xxxhdpi")),
            ("resolution", json!("2670x1200")),
            ("language", json!("zh")),
            ("timezone", json!(8)),
            ("tz_name", json!("Asia/Shanghai")),
            ("tz_offset", json!(28800)),
            ("region", json!("CN")),
            ("package", json!("com.phoenix.read")),
            ("version_code", json!(73932)),
            ("manifest_version_code", json!(73932)),
            ("update_version_code", json!(73932)),
            ("apk_first_install_time", json!(now_ms)),
            ("cdid", json!(cdid)),
            ("clientudid", json!(clientudid)),
            ("openudid", json!(openudid)),
            ("cpu_abi", json!("arm64-v8a")),
            ("display_name", json!("红果免费短剧")),
            ("sdk_version", json!("3.7.2")),
            ("sdk_target_version", json!(29)),
            ("sdk_flavor", json!("china")),
            ("guest_mode", json!(0)),
            ("is_system_app", json!(0)),
            ("not_request_sender", json!(0)),
            ("oaid_may_support", json!(true)),
            ("ipv6_list", json!([])),
            ("sim_serial_number", json!([])),
            (
                "custom",
                json!({
                    "is_android_fold": 0,
                    "filter_warn": 0,
                    "web_ua": "",
                    "is_android_pad": 0,
                    "client_ipv4": "",
                }),
            ),
            ("device_id", json!("0")),
            ("install_id", json!("0")),
            ("req_id", json!(clientudid)),
            (
                "oaid",
                json!({
                    "req_id": cdid,
                    "hw_id_version_code": "0",
                    "take_ms": "6",
                    "is_track_limited": "false",
                    "query_times": "1",
                    "id": cdid,
                    "time": stamp.saturating_sub(200).to_string(),
                }),
            ),
        ] {
            header.insert(key.to_string(), value);
        }
        let payload = serde_json::to_vec(&json!({
            "magic_tag": "ss_app_log",
            "header": Value::Object(header),
            "_gen_time": stamp,
        }))
        .map_err(|error| format!("marshal playback device payload: {error}"))?;
        let compressed = normalize_tt_encrypt_gzip_header(&gzip(&payload))?;
        let body = tt_encrypt(&compressed, Some(seed))?;

        let query = sorted_query(&[
            ("ac".to_string(), "wifi".to_string()),
            ("aid".to_string(), "8662".to_string()),
            ("app_name".to_string(), "novelread".to_string()),
            ("cdid".to_string(), cdid.clone()),
            ("channel".to_string(), "xiaomi_8662_64".to_string()),
            ("compliance_status".to_string(), "0".to_string()),
            ("device_brand".to_string(), "Xiaomi".to_string()),
            ("device_platform".to_string(), "android".to_string()),
            ("device_type".to_string(), "23127PN0CC".to_string()),
            ("dpi".to_string(), "460".to_string()),
            ("dragon_device_type".to_string(), "phone".to_string()),
            ("host_abi".to_string(), "arm64-v8a".to_string()),
            ("is_android_pad_screen".to_string(), "0".to_string()),
            ("language".to_string(), "zh".to_string()),
            ("manifest_version_code".to_string(), "73932".to_string()),
            ("need_personal_recommend".to_string(), "1".to_string()),
            ("openudid".to_string(), openudid.clone()),
            ("os".to_string(), "android".to_string()),
            ("os_api".to_string(), "34".to_string()),
            ("os_version".to_string(), "14".to_string()),
            ("package".to_string(), "com.phoenix.read".to_string()),
            ("player_so_load".to_string(), "1".to_string()),
            ("pv_player".to_string(), "73932".to_string()),
            ("resolution".to_string(), "1200*2670".to_string()),
            ("ssmix".to_string(), "a".to_string()),
            ("tt_data".to_string(), "a".to_string()),
            ("ts".to_string(), (now_ms / 1000).to_string()),
            ("update_version_code".to_string(), "73932".to_string()),
            ("version_code".to_string(), "73932".to_string()),
            ("version_name".to_string(), "7.3.9.32".to_string()),
            ("_rticket".to_string(), stamp.to_string()),
        ]);
        let ts = u32::try_from(now_ms / 1000)
            .map_err(|_| "playback device timestamp is outside the protocol range".to_string())?;
        let body_md5 = hex::encode(Md5::digest(&body));
        let gorgon_random: u16 = rand::thread_rng().gen();
        let headers = vec![
            ("User-Agent".to_string(), MINI_REEL_UA.to_string()),
            (
                "Content-Type".to_string(),
                "application/octet-stream;tt-data=a".to_string(),
            ),
            (
                "Accept".to_string(),
                "application/json; charset=utf-8,application/x-protobuf".to_string(),
            ),
            ("Content-Encoding".to_string(), "gzip".to_string()),
            ("X-Tt-Request-Tag".to_string(), "t=0;n=1".to_string()),
            ("Log-Encode-Type".to_string(), "gzip".to_string()),
            ("Lc".to_string(), "102".to_string()),
            ("Sdk-Version".to_string(), "2".to_string()),
            ("Passport-Sdk-Version".to_string(), "60755".to_string()),
            (
                "Passport-Sdk-Settings".to_string(),
                "device_transfer_s_0,device_transfer_ab_1".to_string(),
            ),
            ("X-SS-DP".to_string(), "8662".to_string()),
            (
                "X-Vc-Bdturing-Sdk-Version".to_string(),
                "4.0.3.cn".to_string(),
            ),
            ("X-Tt-Store-Region".to_string(), "cn".to_string()),
            ("X-Tt-Store-Region-Src".to_string(), "did".to_string()),
            ("X-Khronos".to_string(), ts.to_string()),
            (
                "X-Argus".to_string(),
                base64::engine::general_purpose::STANDARD.encode(ts.to_le_bytes()),
            ),
            ("X-SS-Req-Ticket".to_string(), stamp.to_string()),
            ("X-SS-STUB".to_string(), body_md5),
            (
                "X-Gorgon".to_string(),
                generate_v5_gorgon(&query, &body, ts, gorgon_random),
            ),
        ];
        let url = format!("{DEVICE_REGISTER_BASE}{DEVICE_REGISTER_PATH}?{query}");
        let response = self
            .http
            .request_with_limit(
                "POST",
                &self.target(&url),
                &headers,
                Some(body),
                None,
                Some(REGISTER_RESPONSE_LIMIT),
            )
            .await
            .map_err(|error| format!("device_register transport: {error:?}"))?;
        if response.status != 200 {
            return Err(format!("device_register HTTP {}", response.status));
        }
        let plain = if response
            .body
            .starts_with(&[0x74, 0x63, 0x05, 0x10, 0x00, 0x00])
        {
            tt_decrypt_response(&response.body)?
        } else {
            response.body
        };
        let root: Value = serde_json::from_slice(&plain)
            .map_err(|error| format!("device_register json: {error}"))?;
        let device_id = pick_id(&root, &["device_id_str", "device_id"]);
        let install_id = pick_id(&root, &["install_id_str", "install_id"]);
        if !valid_id(&device_id) || !valid_id(&install_id) {
            return Err("device_register did not return a valid identity".to_string());
        }
        let egdi = pick_id(&root, &["klink_egdi", "egdi"]);

        let _ =
            tokio::time::timeout(ACTIVATION_TIMEOUT, self.activate(&device_id, &install_id)).await;

        Ok(PlaybackDevice {
            device_id,
            install_id,
            cdid,
            openudid,
            clientudid,
            egdi,
        })
    }

    async fn activate(&self, device_id: &str, install_id: &str) {
        let query = sorted_query(&[
            ("aid".to_string(), "8662".to_string()),
            ("app_name".to_string(), "novelread".to_string()),
            ("channel".to_string(), "xiaomi_8662_64".to_string()),
            ("device_id".to_string(), device_id.to_string()),
            ("device_platform".to_string(), "android".to_string()),
            ("iid".to_string(), install_id.to_string()),
            ("os".to_string(), "android".to_string()),
            (
                "_rticket".to_string(),
                crate::timeutil::now_millis().to_string(),
            ),
            ("version_code".to_string(), "73932".to_string()),
            ("version_name".to_string(), "7.3.9.32".to_string()),
        ]);
        let url = format!("{DEVICE_ACTIVATE_BASE}{DEVICE_ACTIVATE_PATH}?{query}");
        let headers = vec![("User-Agent".to_string(), MINI_REEL_UA.to_string())];
        let _ = self
            .http
            .request_with_limit("GET", &self.target(&url), &headers, None, None, Some(4096))
            .await;
    }

    fn target(&self, url: &str) -> String {
        let Some(origin) = self.mock_origin.as_deref() else {
            return url.to_string();
        };
        match url::Url::parse(url) {
            Ok(parsed) => {
                let origin = origin.trim_end_matches('/');
                let mut out = format!("{origin}{}", parsed.path());
                if let Some(query) = parsed.query() {
                    out.push('?');
                    out.push_str(query);
                }
                out
            }
            Err(_) => url.to_string(),
        }
    }
}

fn pick_id(root: &Value, keys: &[&str]) -> String {
    keys.iter()
        .find_map(|key| root.get(*key).and_then(crate::json::value_to_string))
        .unwrap_or_default()
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value != "0"
        && value.len() <= 32
        && value.bytes().all(|byte| byte.is_ascii_digit())
}
