//! Request-local, content-free diagnostics for V5 playback.

use std::collections::hash_map::RandomState;
use std::future::Future;
use std::hash::BuildHasher;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

static IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);
static DEVICE_TAG_HASHER: OnceLock<RandomState> = OnceLock::new();

#[derive(Clone)]
pub(crate) struct PlaybackTraceContext {
    pub request_id: u64,
    pub purpose: &'static str,
    pub attempt: usize,
    pub device_tag: u64,
    pub in_flight: usize,
    pub redirect_hops: Arc<AtomicUsize>,
    pub redirect_method: Arc<Mutex<&'static str>>,
}

tokio::task_local! {
    static TRACE: PlaybackTraceContext;
}

pub(crate) fn current() -> Option<PlaybackTraceContext> {
    TRACE.try_with(Clone::clone).ok()
}

pub(crate) fn purpose(value: &str) -> &'static str {
    match value {
        "foreground" => "foreground",
        "prefetch" => "prefetch",
        _ => "other",
    }
}

struct InFlight;

impl Drop for InFlight {
    fn drop(&mut self) {
        IN_FLIGHT.fetch_sub(1, Ordering::Relaxed);
    }
}

pub(crate) async fn within<F: Future>(
    request_id: u64,
    purpose: &'static str,
    work: F,
) -> F::Output {
    let in_flight = IN_FLIGHT.fetch_add(1, Ordering::Relaxed) + 1;
    // Dropping a cancelled endpoint also releases its diagnostic count.
    let _in_flight = InFlight;
    let trace = PlaybackTraceContext {
        request_id,
        purpose,
        attempt: 0,
        device_tag: 0,
        in_flight,
        redirect_hops: Arc::new(AtomicUsize::new(0)),
        redirect_method: Arc::new(Mutex::new("POST")),
    };
    log::info!("v5 trace request={request_id} purpose={purpose} event=start in_flight={in_flight}");
    TRACE.scope(trace, work).await
}

pub(crate) async fn with_device<F: Future>(device_id: &str, work: F) -> F::Output {
    let Some(mut trace) = current() else {
        return work.await;
    };
    // A randomly keyed process-local hash permits comparisons within one run
    // without logging an identity or producing a stable identifier across runs.
    trace.device_tag = DEVICE_TAG_HASHER
        .get_or_init(RandomState::new)
        .hash_one(device_id);
    TRACE.scope(trace, work).await
}

pub(crate) async fn with_attempt<F: Future>(attempt: usize, work: F) -> F::Output {
    let Some(mut trace) = current() else {
        return work.await;
    };
    trace.attempt = attempt;
    trace.in_flight = IN_FLIGHT.load(Ordering::Relaxed);
    trace.redirect_hops = Arc::new(AtomicUsize::new(0));
    trace.redirect_method = Arc::new(Mutex::new("POST"));
    TRACE.scope(trace, work).await
}
