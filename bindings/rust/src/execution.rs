//! Platform time for byte-fed execution. Every Host and Session uses one
//! monotonic epoch; the Zig close machine owns the deadlines themselves.

use std::sync::OnceLock;

#[cfg(not(target_arch = "wasm32"))]
pub(crate) use std::time::Instant;
#[cfg(not(target_arch = "wasm32"))]
pub(crate) use tokio::time::{sleep, timeout};
#[cfg(target_arch = "wasm32")]
pub(crate) use web_time::Instant;

pub(crate) fn monotonic_ms() -> i64 {
	static EPOCH: OnceLock<Instant> = OnceLock::new();
	i64::try_from(EPOCH.get_or_init(Instant::now).elapsed().as_millis()).unwrap_or(i64::MAX)
}

#[cfg(target_arch = "wasm32")]
pub(crate) async fn sleep(duration: std::time::Duration) {
	// Browser timers accept signed 32-bit milliseconds. Split long waits and
	// round sub-millisecond tails upward instead of expiring a deadline early.
	// Dropping TimeoutFuture cancels the registered browser callback.
	let started = Instant::now();
	loop {
		let remaining = duration.saturating_sub(started.elapsed());
		if remaining.is_zero() {
			return;
		}
		let millis = remaining.as_nanos().div_ceil(1_000_000).min(i32::MAX as u128) as u32;
		gloo_timers::future::TimeoutFuture::new(millis).await;
	}
}

#[cfg(target_arch = "wasm32")]
pub(crate) async fn timeout<F: std::future::Future>(
	duration: std::time::Duration,
	future: F,
) -> std::result::Result<F::Output, ()> {
	// Match the native timeout's ready-operation precedence. Losing the race
	// drops the operation or timer before the caller resumes.
	tokio::select! {
		biased;
		result = future => Ok(result),
		() = sleep(duration) => Err(()),
	}
}
