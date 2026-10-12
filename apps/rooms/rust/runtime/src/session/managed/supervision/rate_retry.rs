//! A refused attempt has no effect to replay. Its existing membership worker
//! may wait within one finite window. Cancellation owns the wait and no task
//! or mutation is queued elsewhere.
use rooms_application::admission::RetryAdvice;
use rooms_glowcap::client::Deadline;
use tokio::sync::watch;

#[derive(Default)]
pub(super) struct Window {
	started: Option<u64>,
	spread: u64,
}
impl Window {
	pub fn new(identity: &str) -> Self {
		let spread = identity
			.bytes()
			.fold(0u64, |hash, byte| hash.wrapping_mul(31).wrapping_add(u64::from(byte)))
			% 251;
		Self { started: None, spread }
	}
	pub fn delay(&mut self, advice: RetryAdvice, now: u64) -> Option<u64> {
		let started = *self.started.get_or_insert(now);
		let delay = advice.retry_ms.max(1000) + self.spread;
		(now.saturating_sub(started).saturating_add(delay) <= 60_000).then_some(delay)
	}
	pub fn reset(&mut self) {
		self.started = None;
	}
}

pub(super) async fn wait(platform: &impl Deadline, stopping: &mut watch::Receiver<bool>, delay: u64) -> bool {
	if *stopping.borrow() {
		return false;
	}
	tokio::select! {
		biased;
		_ = stopping.changed() => false,
		_ = platform.within(delay, core::future::pending::<()>()) => !*stopping.borrow(),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::admission::Class;
	struct Platform;
	impl Deadline for Platform {
		fn monotonic_millis(&self) -> u64 {
			0
		}
		async fn within<T>(&self, ms: u64, work: impl core::future::Future<Output = T>) -> Option<T> {
			tokio::time::timeout(core::time::Duration::from_millis(ms), work)
				.await
				.ok()
		}
	}
	#[test]
	fn automatic_window_is_finite_and_distinct_workers_spread_attempts() {
		let advice = RetryAdvice {
			class: Class::Join,
			retry_ms: 1000,
		};
		let mut first = Window::new("membership-a");
		let mut second = Window::new("membership-b");
		assert_ne!(first.delay(advice, 0), second.delay(advice, 0));
		assert!(first.delay(advice, 59_500).is_none());
		first.reset();
		assert!(first.delay(advice, 59_500).is_some());
	}
	#[tokio::test]
	async fn cancellation_ends_the_only_wait_without_an_automatic_attempt() {
		let (stop, mut stopping) = watch::channel(false);
		let waiting = wait(&Platform, &mut stopping, 60_000);
		tokio::pin!(waiting);
		use core::{future::Future, task::Poll};
		assert!(
			core::future::poll_fn(|cx| Poll::Ready(waiting.as_mut().poll(cx)))
				.await
				.is_pending()
		);
		stop.send_replace(true);
		assert!(!waiting.await);
		assert!(!wait(&Platform, &mut stop.subscribe(), 1).await);
	}
	#[tokio::test]
	async fn elapsed_wait_only_returns_permission_to_the_existing_worker() {
		let (_stop, mut stopping) = watch::channel(false);
		assert!(wait(&Platform, &mut stopping, 1).await);
	}
}
