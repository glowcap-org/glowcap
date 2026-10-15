//! Ownership of one FFI driver loop. Holding a [`LoopHandle`] proves the
//! loop is unreleased, so its verbs are safe functions: the only unsafe act is
//! adopting the pointer `glowcap_driver_take_host` wrote, and the only way to
//! give the loop up is the consuming [`LoopHandle::release`], which hands the
//! handle back when the driver refuses before consuming it.
use core::ptr::NonNull;

use crate::driver_failure::{decode, empty};
use crate::sys::GlowcapTransportProvider;
use crate::sys::driver::{self as ffi, GlowcapDriverLoop};
use crate::{Error, Result, sys};

/// One live FFI driver loop. The loop stays allocated until `release`
/// consumes this handle. Dropping the handle without releasing leaks the loop,
/// which is why every owner either releases it or parks it with the finalizer.
pub(crate) struct LoopHandle(NonNull<GlowcapDriverLoop>);

/// What one release attempt did with FFI ownership.
pub(crate) enum Released {
	/// FFI ownership is gone, with the release's own outcome.
	Consumed(Result<()>),
	/// The driver refused before consuming. The loop is still live.
	Refused { handle: LoopHandle, error: Error },
}

impl LoopHandle {
	/// Adopt the loop `glowcap_driver_take_host` just wrote.
	///
	/// # Safety
	///
	/// `raw` came from a successful `glowcap_driver_take_host` and no other owner releases it.
	pub(crate) unsafe fn adopt(raw: *mut GlowcapDriverLoop) -> Option<Self> {
		NonNull::new(raw).map(Self)
	}

	/// The raw loop for a C ABI call made while this handle is borrowed.
	pub(crate) fn as_ptr(&self) -> *mut GlowcapDriverLoop {
		self.0.as_ptr()
	}

	/// Install one provider package. The driver copies its profiles and tables.
	pub(crate) fn add_provider(&self, provider: &GlowcapTransportProvider) -> Result<()> {
		let mut failure = empty();
		// SAFETY: this handle proves the loop is unreleased; `provider` is borrowed for the call and copied by the
		// callee; `failure` is a local `GlowcapDriverFailure` initialised by `empty()` with the current version and
		// layout.
		let code = unsafe { ffi::glowcap_driver_add_provider(self.as_ptr(), provider, &mut failure) };
		decode(code, failure, "driver add_provider")
	}

	/// Stop one listener while preserving already committed events. `false`
	/// means the driver asked for the close to be retried later.
	pub(crate) fn close_listener(&self, listener: u64) -> Result<bool> {
		let mut failure = empty();
		// SAFETY: this handle proves the loop is unreleased; `listener` is a plain integer; `failure` is a local
		// `GlowcapDriverFailure` initialised by `empty()` with the current version and layout.
		let code = unsafe { ffi::glowcap_driver_listener_close(self.as_ptr(), listener, &mut failure) };
		if code == sys::WOULD_BLOCK {
			return Ok(false);
		}
		decode(code, failure, "driver listener_close").map(|()| true)
	}

	/// Release the loop. The driver consumes it on every code but a refusal,
	/// and a refusal returns the still-live handle for a later attempt.
	pub(crate) fn release(self) -> Released {
		let mut failure = empty();
		// SAFETY: this handle proves the loop is unreleased; `failure` is a local `GlowcapDriverFailure` initialised
		// by `empty()` with the current version and layout. Consumption is decided from `code` below, and the handle
		// is returned to the caller only when the driver refused.
		let code = unsafe { ffi::glowcap_driver_release(self.as_ptr(), &mut failure) };
		let result = decode(code, failure, "driver release");
		if crate::lifecycle::release_consumed(code) {
			return Released::Consumed(result);
		}
		let error = match result {
			Err(error) => error,
			Ok(()) => Error::with_detail(
				sys::ERR_INTERNAL,
				"driver release refused without a failure".to_string(),
			),
		};
		Released::Refused { handle: self, error }
	}
}
