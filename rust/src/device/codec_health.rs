//! 记住哪些设备身份给得出可解码流。
//!
//! 上游按设备身份分流码流：同一个进程、同一集，一部分设备每次都给 h264/h265
//! 多档，另一部分只给 bytevc2（H.266，Android 播放链路上没有解码器）。实测
//! 2026-11-20：池里 0 号设备 3/3 可解，1–4 号 9/9 全拒，而且同一台设备的表现
//! 是稳定的。所以「这台设备给过什么」是能跨请求复用的判断依据——先挑已知可解
//! 的设备，比每次都靠重掷碰运气省掉最多 8 次取流（每次 200–300ms）。
//!
//! 只放内存，不落盘：这是对设备当下表现的观测，而设备文件会换机、会按版本
//! 重注册，写进磁盘只会让过期的判断活过它的事实基础。进程重启后从头学。

use std::collections::HashMap;
use std::sync::Mutex;

/// 一次取流结果在「能不能解」这个维度上的结论。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodecVerdict {
    /// 至少有一档本机能解码，正常播出。
    Playable,
    /// 全档 bytevc2，播放链路上没有解码器。
    UnsupportedOnly,
}

/// 最多记多少台设备的观感。池子上限是 20，这里留足被替换掉的旧身份。
const MAX_TRACKED_DEVICES: usize = 64;
/// 单台设备的分数上下限：一次成功不等于永远成功，一次被拒也不等于永远被拒。
const SCORE_LIMIT: i32 = 8;

#[derive(Debug, Default, Clone)]
struct Entry {
    score: i32,
    /// 上一次被挑中时的序号，用来在同等分数里轮换，避免所有请求都压在同一台。
    picked_at: u64,
}

#[derive(Debug, Default)]
pub struct CodecHealth {
    inner: Mutex<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    entries: HashMap<String, Entry>,
    seq: u64,
}

impl CodecHealth {
    pub fn new() -> Self {
        Self::default()
    }

    /// 记一次观测。分数越高越可信，0 及以下表示「不值得优先」。
    pub fn record(&self, device_id: &str, verdict: CodecVerdict) {
        if device_id.is_empty() {
            return;
        }
        let mut inner = self.lock();
        if inner.entries.len() >= MAX_TRACKED_DEVICES && !inner.entries.contains_key(device_id) {
            inner.evict_weakest();
        }
        let entry = inner.entries.entry(device_id.to_string()).or_default();
        entry.score = match verdict {
            CodecVerdict::Playable => (entry.score + 1).min(SCORE_LIMIT),
            CodecVerdict::UnsupportedOnly => (entry.score - 1).max(-SCORE_LIMIT),
        };
    }

    /// 挑一台已知可解的设备；没有可靠候选时返回 `None`，让池子按自己的轮转出手。
    pub fn preferred(&self) -> Option<String> {
        self.preferred_excluding(None)
    }

    /// 同上，但排除一台指定设备：码流被拒后换设备时，换回来同一台不算换。
    pub fn preferred_excluding(&self, excluded: Option<&str>) -> Option<String> {
        let mut inner = self.lock();
        let mut best: Option<(String, i32, u64)> = None;
        for (device_id, entry) in inner.entries.iter() {
            if entry.score <= 0 || excluded.is_some_and(|excluded| excluded == device_id) {
                continue;
            }
            let better = match &best {
                None => true,
                Some((_, score, picked_at)) => {
                    entry.score > *score || (entry.score == *score && entry.picked_at < *picked_at)
                }
            };
            if better {
                best = Some((device_id.clone(), entry.score, entry.picked_at));
            }
        }
        let (device_id, _, _) = best?;
        inner.seq += 1;
        let seq = inner.seq;
        if let Some(entry) = inner.entries.get_mut(&device_id) {
            entry.picked_at = seq;
        }
        Some(device_id)
    }

    /// 设备离开池子（隔离、被替换）后，它的观感没有意义了。
    pub fn forget(&self, device_id: &str) {
        if device_id.is_empty() {
            return;
        }
        self.lock().entries.remove(device_id);
    }

    #[cfg(test)]
    fn tracked(&self) -> usize {
        self.lock().entries.len()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        // 记录观感不该因为别处的 panic 把整条取流链路带下水。
        self.inner.lock().unwrap_or_else(|error| error.into_inner())
    }
}

impl Inner {
    fn evict_weakest(&mut self) {
        let weakest = self
            .entries
            .iter()
            .min_by_key(|(_, entry)| (entry.score, entry.picked_at))
            .map(|(device_id, _)| device_id.clone());
        if let Some(device_id) = weakest {
            self.entries.remove(&device_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{CodecHealth, CodecVerdict, MAX_TRACKED_DEVICES};

    #[test]
    fn playable_device_becomes_the_preferred_one() {
        let health = CodecHealth::new();
        health.record("bad", CodecVerdict::UnsupportedOnly);
        health.record("good", CodecVerdict::Playable);

        assert_eq!(health.preferred().as_deref(), Some("good"));
    }

    #[test]
    fn unseeded_health_has_no_preference() {
        let health = CodecHealth::new();
        assert_eq!(health.preferred(), None);
    }

    #[test]
    fn a_device_that_starts_rejecting_drops_out_of_preference() {
        let health = CodecHealth::new();
        health.record("flaky", CodecVerdict::Playable);
        assert_eq!(health.preferred().as_deref(), Some("flaky"));

        // 分流会变：给过好码流的设备也可能只剩 bytevc2，一次被拒就该回头观察，
        // 连拒两次后它的分数落到 0 以下，不该再被优先挑中。
        health.record("flaky", CodecVerdict::UnsupportedOnly);
        health.record("flaky", CodecVerdict::UnsupportedOnly);
        assert_eq!(health.preferred(), None);
    }

    #[test]
    fn equally_good_devices_are_rotated_instead_of_pinned() {
        let health = CodecHealth::new();
        health.record("a", CodecVerdict::Playable);
        health.record("b", CodecVerdict::Playable);

        let first = health.preferred();
        let second = health.preferred();
        let third = health.preferred();

        assert_ne!(
            first, second,
            "同等可信的设备要轮换，不能一直压在同一个身份上"
        );
        assert_eq!(first, third, "两台设备应当交替，而不是轮到第三台");
    }

    #[test]
    fn tracked_set_stays_bounded() {
        let health = CodecHealth::new();
        for index in 0..(MAX_TRACKED_DEVICES * 2) {
            health.record(&format!("device-{index}"), CodecVerdict::Playable);
        }
        assert_eq!(health.tracked(), MAX_TRACKED_DEVICES);
    }

    #[test]
    fn forgotten_device_is_no_longer_preferred() {
        let health = CodecHealth::new();
        health.record("retired", CodecVerdict::Playable);
        health.forget("retired");
        assert_eq!(health.preferred(), None);
    }
}
