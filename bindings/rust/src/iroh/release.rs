use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::Notify;

use super::check_iroh;
use super::sync::lock_iroh;
use crate::sys::iroh::{self as ffi, GlowcapIrohNetlayer};
use crate::{Error, Result, sys};

const RELEASE_OPEN: u8 = 0;
const RELEASE_RESERVED: u8 = 1;
const RELEASE_RUNNING: u8 = 2;
const RELEASE_DONE: u8 = 3;

type ReleaseFn = unsafe fn(usize) -> i32;
type CloseFn = unsafe fn(usize);

fn call_release(release: ReleaseFn, raw: usize) -> Result<()> {
	// SAFETY: `release` is `release_native` in production and a counting stub in the tests, and `raw` is the address of
	// the `GlowcapIrohNetlayer` its owner passed in; `NetlayerRelease::start` and `fallback` reach this call only after
	// moving the phase to `RELEASE_RUNNING`, so the release runs at most once and this frame is the handle's last
	// owner.
	match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe { release(raw) })) {
		Ok(code) => check_iroh(code),
		Err(_) => Err(Error::with_detail(
			sys::ERR_INTERNAL,
			"iroh netlayer release panicked".to_string(),
		)),
	}
}

// A release task is retained until its blocking call has completed. The
// reserved/running split lets a last-resort Drop fallback claim a queued task:
// the fallback drops the retained handle, runs the native release itself, and a
// task that starts later observes the running claim and skips the native call.
// Release remains exactly once even when the explicit waiter is cancelled.
struct NetlayerRelease {
	phase: AtomicU8,
	task: Mutex<Option<tokio::task::JoinHandle<()>>>,
	notify: Notify,
	close_lock: tokio::sync::Mutex<()>,
	failure: Mutex<Option<Error>>,
}

impl NetlayerRelease {
	fn new() -> NetlayerRelease {
		NetlayerRelease {
			phase: AtomicU8::new(RELEASE_OPEN),
			task: Mutex::new(None),
			notify: Notify::new(),
			close_lock: tokio::sync::Mutex::new(()),
			failure: Mutex::new(None),
		}
	}

	fn start(self: &Arc<NetlayerRelease>, raw: usize, release: ReleaseFn) {
		// Store the JoinHandle before a waiter can take it, even if the blocking
		// task runs to completion immediately.
		let mut task_slot = lock_iroh(&self.task, "iroh-release-task-lock-poison");
		if self
			.phase
			.compare_exchange(RELEASE_OPEN, RELEASE_RESERVED, Ordering::AcqRel, Ordering::Acquire)
			.is_err()
		{
			return;
		}
		let state = Arc::clone(self);
		let task = tokio::task::spawn_blocking(move || {
			if state
				.phase
				.compare_exchange(RELEASE_RESERVED, RELEASE_RUNNING, Ordering::AcqRel, Ordering::Acquire)
				.is_ok()
			{
				if let Err(error) = call_release(release, raw) {
					*lock_iroh(&state.failure, "iroh-release-failure-lock-poison") = Some(error);
				}
				state.phase.store(RELEASE_DONE, Ordering::Release);
				state.notify.notify_waiters();
			}
		});
		*task_slot = Some(task);
	}

	async fn wait(&self) -> Result<()> {
		// Join first when this owner retained the task. A panic or runtime
		// cancellation must surface as an error instead of leaving every waiter
		// asleep forever waiting for a DONE store the task never performed.
		let task = lock_iroh(&self.task, "iroh-release-task-lock-poison").take();
		if let Some(task) = task {
			task.await.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
		}
		loop {
			if self.phase.load(Ordering::Acquire) == RELEASE_DONE {
				return self.result();
			}
			let notified = self.notify.notified();
			if self.phase.load(Ordering::Acquire) == RELEASE_DONE {
				return self.result();
			}
			notified.await;
		}
	}

	fn result(&self) -> Result<()> {
		match lock_iroh(&self.failure, "iroh-release-failure-lock-poison").clone() {
			Some(error) => Err(error),
			None => Ok(()),
		}
	}

	fn fallback(&self, raw: usize, close: CloseFn, release: ReleaseFn) {
		loop {
			let phase = self.phase.load(Ordering::Acquire);
			if phase == RELEASE_DONE || phase == RELEASE_RUNNING {
				return;
			}
			if self
				.phase
				.compare_exchange(phase, RELEASE_RUNNING, Ordering::AcqRel, Ordering::Acquire)
				.is_ok()
			{
				if let Some(task) = lock_iroh(&self.task, "iroh-release-task-lock-poison").take() {
					task.abort();
				}
				// SAFETY: `close` is `close_native` in production, and `raw` is the address of the
				// `GlowcapIrohNetlayer` this `NetlayerRaw` is dropping; this frame holds the `RELEASE_RUNNING` claim,
				// so no release has run yet, and `close` is a shutdown lever that does not free the handle.
				unsafe { close(raw) };
				if let Err(error) = call_release(release, raw) {
					*lock_iroh(&self.failure, "iroh-release-failure-lock-poison") = Some(error.clone());
					crate::record_runtime_failure(crate::FailureLayer::Transport, "iroh-netlayer-finalize", error);
				}
				self.phase.store(RELEASE_DONE, Ordering::Release);
				self.notify.notify_waiters();
				return;
			}
		}
	}
}

unsafe fn close_native(raw: usize) {
	// SAFETY: the caller passes a live netlayer handle. `close` is a shutdown
	// lever, not a free, so it is callable while other owners still hold `raw`.
	unsafe { ffi::glowcap_iroh_netlayer_close(raw as *mut GlowcapIrohNetlayer) };
}

unsafe fn release_native(raw: usize) -> i32 {
	// SAFETY: the caller has already joined the dispatcher task, so this frame
	// is the handle's last owner and the release is the final use of `raw`.
	unsafe {
		ffi::glowcap_iroh_netlayer_release(
			raw as *mut GlowcapIrohNetlayer,
			core::ptr::null_mut(),
			0,
			core::ptr::null_mut(),
		)
	}
}

// The raw netlayer handle is shared (behind an `Arc`) between the public
// `Netlayer`/`Server` and the readiness loop's dispatcher task. Explicit
// owners join that task before consuming the handle and awaiting release. Drop
// is only a last-resort fallback for cancellation/runtime shutdown; after
// claiming the same state it sends the idempotent close signal, then releases
// synchronously, never racing a queued release.
pub(super) struct NetlayerRaw {
	pub(super) raw: *mut GlowcapIrohNetlayer,
	release: Arc<NetlayerRelease>,
}

// SAFETY: sharing `&NetlayerRaw` across threads only exposes reads of the raw
// pointer *value*, which is trivially safe. Concurrent *FFI use* of the endpoint
// behind it, the dispatcher's `drain_ready` on the reactor thread versus the
// public handle's accessors/`close` on a caller thread, is defined because the
// sidecar endpoint behind `glowcap_iroh_netlayer_*` is internally synchronized:
// iroh's `Endpoint` is `Send + Sync` and the readiness queue is mutex-guarded.
// The `Arc` only keeps the handle alive and moves its release across threads.
unsafe impl Send for NetlayerRaw {}
// SAFETY: as the `Send` impl above; the same reasoning covers sharing `&NetlayerRaw` across threads.
unsafe impl Sync for NetlayerRaw {}

impl NetlayerRaw {
	pub(super) fn new(raw: *mut GlowcapIrohNetlayer) -> NetlayerRaw {
		NetlayerRaw {
			raw,
			release: Arc::new(NetlayerRelease::new()),
		}
	}

	pub(super) fn close(&self) {
		// SAFETY: `self.raw` is the `GlowcapIrohNetlayer` handle this `NetlayerRaw` owns; its only caller, `release`,
		// runs this before starting the one native release, and `close_native` is a shutdown lever callable while other
		// owners still hold the handle.
		unsafe { close_native(self.raw as usize) };
	}

	pub(super) async fn release(self: &Arc<NetlayerRaw>) -> Result<()> {
		let _close_guard = self.release.close_lock.lock().await;
		if self.release.phase.load(Ordering::Acquire) == RELEASE_DONE {
			return self.release.wait().await;
		}
		self.close();
		self.release.start(self.raw as usize, release_native);
		self.release.wait().await
	}

	/// Drop this construction reference without closing the endpoint. Valid
	/// only once another owner holds its own native reference, the driver's
	/// provider lease, retained when the package was registered, because the
	/// endpoint keeps running on that reference alone. The one native release
	/// still runs exactly once, and the `Drop` fallback afterwards sees a
	/// finished release and sends no close.
	pub(super) async fn relinquish(self: &Arc<NetlayerRaw>) -> Result<()> {
		let _close_guard = self.release.close_lock.lock().await;
		if self.release.phase.load(Ordering::Acquire) == RELEASE_DONE {
			return self.release.wait().await;
		}
		self.release.start(self.raw as usize, release_native);
		self.release.wait().await
	}
}

impl Drop for NetlayerRaw {
	fn drop(&mut self) {
		self.release.fallback(self.raw as usize, close_native, release_native);
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::atomic::AtomicUsize;

	static RELEASE_COUNT: AtomicUsize = AtomicUsize::new(0);
	static CLOSE_COUNT: AtomicUsize = AtomicUsize::new(0);

	unsafe fn count_close(_raw: usize) {
		CLOSE_COUNT.fetch_add(1, Ordering::SeqCst);
	}

	unsafe fn count_release(_raw: usize) -> i32 {
		RELEASE_COUNT.fetch_add(1, Ordering::SeqCst);
		sys::OK
	}

	unsafe fn panic_release(_raw: usize) -> i32 {
		panic!("release failed");
	}

	unsafe fn fail_release(_raw: usize) -> i32 {
		sys::ERR_IO
	}

	#[tokio::test]
	async fn netlayer_release_waits_and_claims_once() {
		RELEASE_COUNT.store(0, Ordering::SeqCst);
		CLOSE_COUNT.store(0, Ordering::SeqCst);
		let release = Arc::new(NetlayerRelease::new());
		release.start(0, count_release);
		release.start(0, count_release);
		release.wait().await.unwrap();
		release.wait().await.unwrap();
		assert_eq!(RELEASE_COUNT.load(Ordering::SeqCst), 1);
		assert_eq!(CLOSE_COUNT.load(Ordering::SeqCst), 0);

		let fallback = Arc::new(NetlayerRelease::new());
		fallback.phase.store(RELEASE_RESERVED, Ordering::Release);
		fallback.fallback(0, count_close, count_release);
		fallback.wait().await.unwrap();
		assert_eq!(RELEASE_COUNT.load(Ordering::SeqCst), 2);
		assert_eq!(CLOSE_COUNT.load(Ordering::SeqCst), 1);

		let queued = Arc::new(NetlayerRelease::new());
		queued.phase.store(RELEASE_RESERVED, Ordering::Release);
		let queued_task = tokio::spawn(async {
			std::future::pending::<()>().await;
		});
		*lock_iroh(&queued.task, "iroh-release-task-lock-poison") = Some(queued_task);
		queued.fallback(0, count_close, count_release);
		assert!(lock_iroh(&queued.task, "iroh-release-task-lock-poison").is_none());
		queued.wait().await.unwrap();
		assert_eq!(RELEASE_COUNT.load(Ordering::SeqCst), 3);
		assert_eq!(CLOSE_COUNT.load(Ordering::SeqCst), 2);

		// A relinquished reference releases once without a close, and the drop
		// fallback that follows finds the release finished and sends no close
		// either: the endpoint the driver's lease keeps running is never shut.
		let handed = Arc::new(NetlayerRelease::new());
		handed.start(0, count_release);
		handed.wait().await.unwrap();
		handed.fallback(0, count_close, count_release);
		assert_eq!(RELEASE_COUNT.load(Ordering::SeqCst), 4);
		assert_eq!(CLOSE_COUNT.load(Ordering::SeqCst), 2);

		let panicked = Arc::new(NetlayerRelease::new());
		panicked.start(0, panic_release);
		let panic_error = panicked.wait().await.unwrap_err();
		assert_eq!(panic_error.message(), Some("iroh netlayer release panicked"));
		assert_eq!(panicked.phase.load(Ordering::Acquire), RELEASE_DONE);

		let failed = Arc::new(NetlayerRelease::new());
		failed.start(0, fail_release);
		assert!(failed.wait().await.is_err());
		assert!(failed.wait().await.is_err(), "the release barrier retains its failure");

		let already_failed = NetlayerRelease::new();
		*lock_iroh(&already_failed.failure, "iroh-release-failure-lock-poison") = Some(Error::from_code(sys::ERR_IO));
		already_failed.phase.store(RELEASE_DONE, Ordering::Release);
		assert!(already_failed.wait().await.is_err());
	}
}
