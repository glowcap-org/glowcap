//! Synchronous ownership of one native driver loop.
//!
//! This leaf owns the raw archive handle, its construction policy, direct
//! verbs, and the consumed/refused release distinction. Async waiter and Host
//! choreography belongs to the parent `driver_loop` module.

use core::ffi::{c_int, c_void};
use std::cell::{Ref, RefCell};
use std::marker::PhantomData;
use std::rc::Rc;

use super::handle::{LoopHandle, Released};
use crate::driver_event::{LoopEvent, decode as decode_event};
use crate::sys::GlowcapTransportProvider;
use crate::sys::driver::{self as ffi, GlowcapDriverEvent, GlowcapDriverLoop, GlowcapDriverOptions};
use crate::sys::{self, host as ffi_host};
use crate::uri::OwnedLocator;
use crate::{ContextInner, Error, Locator, PendingWork, Result};

/// One archive-owned provider package. Registration acquires the package lease.
/// The driver releases it after every copied callback and transport handle.
pub struct ProviderPackage<'owner> {
	pub(crate) package: GlowcapTransportProvider,
	pub(crate) _owner: PhantomData<&'owner ()>,
}

/// One stepping native loop over one multi-session host. The handle slot is
/// empty once a release consumed the loop or a refused release moved it to
/// the finalizer. Every verb refuses on an empty slot instead of touching a
/// released loop.
pub struct DriverLoop {
	handle: RefCell<Option<LoopHandle>>,
	host: *mut ffi_host::GlowcapHost,
	_context: Option<Rc<ContextInner>>,
}

/// One release attempt on a `DriverLoop`.
pub(super) enum ReleaseOutcome {
	/// Native ownership is gone, with the release's own outcome. A loop whose
	/// handle had already left the slot reports `Consumed(Ok(()))`.
	Consumed(Result<()>),
	/// The driver refused before consuming. The loop is still live.
	Refused(Error),
}

/// Native loop construction policy. `wire_buffer_bytes` is retained per
/// stream direction, while `frame_cap` is the Host admission cap.
#[derive(Clone, Copy, Debug)]
pub struct DriverLoopOptions {
	pub frame_cap: usize,
	pub wire_buffer_bytes: usize,
	pub max_pending_opens: usize,
	pub handshake_ms: u32,
	pub listener_setup_ms: u32,
	pub settle_ms: u32,
}

impl Default for DriverLoopOptions {
	fn default() -> Self {
		Self {
			frame_cap: sys::DEFAULT_FRAME_CAP,
			wire_buffer_bytes: sys::DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
			max_pending_opens: sys::DRIVER_DEFAULT_MAX_PENDING_OPENS,
			handshake_ms: sys::DRIVER_DEFAULT_HANDSHAKE_MS,
			listener_setup_ms: sys::DRIVER_DEFAULT_LISTENER_SETUP_MS,
			settle_ms: sys::DRIVER_DEFAULT_SETTLE_MS,
		}
	}
}

impl DriverLoopOptions {
	fn to_c(self) -> GlowcapDriverOptions {
		GlowcapDriverOptions {
			abi_version: sys::DRIVER_OPTIONS_ABI_VERSION,
			struct_size: core::mem::size_of::<GlowcapDriverOptions>(),
			wire_buffer_bytes: self.wire_buffer_bytes,
			max_pending_opens: self.max_pending_opens,
			handshake_ms: self.handshake_ms,
			listener_setup_ms: self.listener_setup_ms,
			settle_ms: self.settle_ms,
		}
	}
}

fn check(rc: c_int) -> Result<()> {
	if rc == sys::OK {
		Ok(())
	} else {
		Err(Error::from_code(rc))
	}
}

impl DriverLoop {
	/// Create a loop over a fresh host. `seed` is the host constructor's
	/// 64-byte contract (durable identity, then a fresh session-key root).
	/// `options` owns the retained wire-buffer size and three positive wait bounds.
	pub fn open(seed: &[u8; 64], options: DriverLoopOptions) -> Result<Self> {
		let context = Rc::new(ContextInner::new()?);
		crate::require_archive_fingerprint(
			"host",
			// SAFETY: this fingerprint query takes no arguments and returns a constant.
			unsafe { ffi_host::glowcap_host_archive_fingerprint() },
			sys::HOST_ARCHIVE_FINGERPRINT,
		)?;
		let mut host: *mut ffi_host::GlowcapHost = core::ptr::null_mut();
		// SAFETY: `context.raw` is the allocator context the `Rc<ContextInner>` keeps live for this call; `seed` is a
		// borrowed 64-byte array whose pointer and length stay live for the call and the callee copies it; `host` is an
		// out-parameter the callee fills.
		crate::host::check_host(unsafe {
			ffi_host::glowcap_host_new_in(
				context.raw,
				seed.as_ptr(),
				seed.len(),
				options.frame_cap,
				1,
				sys::DEFAULT_CODEC,
				sys::DEFAULT_CAPTP_VERSION,
				sys::DEFAULT_FEATURES,
				0,
				&mut host,
			)
		})?;
		match Self::take_host(host, options) {
			Ok(mut loop_) => {
				loop_._context = Some(context);
				Ok(loop_)
			}
			Err(primary) => {
				// SAFETY: `host` is the handle `glowcap_host_new_in` just wrote and this function still owns, because
				// `take_host` failed and left Host ownership unchanged; it is released exactly once here.
				let cleanup_rc = unsafe { ffi_host::glowcap_host_release(host) };
				let cleanup = crate::host::check_host(cleanup_rc);
				if !crate::lifecycle::release_consumed(cleanup_rc) {
					core::mem::forget(context);
				}
				Err(crate::retain_cleanup_failure(primary, cleanup))
			}
		}
	}

	/// Transfer an existing quiescent Host to a native loop. The C transaction
	/// leaves Host ownership unchanged on failure and makes this loop the sole
	/// transport/action-drain/release owner on success.
	pub(crate) fn take_host(host: *mut ffi_host::GlowcapHost, options: DriverLoopOptions) -> Result<Self> {
		crate::require_archive_fingerprint(
			"driver",
			// SAFETY: this fingerprint query takes no arguments and returns a constant.
			unsafe { ffi::glowcap_driver_archive_fingerprint() },
			sys::DRIVER_ARCHIVE_FINGERPRINT,
		)?;
		let mut raw: *mut GlowcapDriverLoop = core::ptr::null_mut();
		let options = options.to_c();
		// SAFETY: `host` is the quiescent Host handle the caller transfers and a failed take leaves with the caller;
		// `options` is a local `GlowcapDriverOptions` borrowed for the call; `raw` is an out-parameter the callee
		// fills.
		check(unsafe { ffi::glowcap_driver_take_host(host, &options, &mut raw) })?;
		// SAFETY: `raw` is the loop `glowcap_driver_take_host` just wrote on success, and this `DriverLoop` becomes its
		// only owner.
		let handle = unsafe { LoopHandle::adopt(raw) }
			.ok_or_else(|| Error::with_detail(sys::ERR_INTERNAL, "driver take_host returned no loop".to_string()))?;
		Ok(Self {
			handle: RefCell::new(Some(handle)),
			host,
			_context: None,
		})
	}

	/// Borrow the live loop, or refuse because a release already consumed it
	/// or moved it to the finalizer.
	fn live(&self) -> Result<Ref<'_, LoopHandle>> {
		let slot = self
			.handle
			.try_borrow()
			.map_err(|_| Error::with_detail(sys::ERR_INVALID_ARGUMENT, "driver loop is being released".to_string()))?;
		Ref::filter_map(slot, Option::as_ref)
			.map_err(|_| Error::with_detail(sys::ERR_INVALID_ARGUMENT, "driver loop already released".to_string()))
	}

	pub(super) fn retained_context(&self) -> Option<Rc<ContextInner>> {
		self._context.as_ref().map(Rc::clone)
	}

	/// The wrapped `GlowcapHost` handle for application verbs. Never release
	/// it separately. Dropping the loop releases both.
	pub fn host(&self) -> *mut ffi_host::GlowcapHost {
		self.host
	}

	/// Install one provider package. Native registration retains its callback
	/// context before publication and releases it during loop teardown.
	pub fn add_provider(&self, provider: ProviderPackage<'_>) -> Result<()> {
		self.live()?.add_provider(&provider.package)
	}

	/// Report whether the native provider registry owns `transport`.
	pub fn has_transport(&self, transport: &str) -> Result<bool> {
		let handle = self.live()?;
		let mut present = 0u8;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `transport` is a borrowed `str` whose pointer and length stay live for the call; `present` is an
		// out-parameter the callee writes.
		check(unsafe {
			ffi::glowcap_driver_has_transport(handle.as_ptr(), transport.as_ptr(), transport.len(), &mut present)
		})?;
		Ok(present != 0)
	}

	/// Begin a nonblocking dial. A refusal before admission returns directly.
	/// After admission the outcome arrives as an `Opened`/`OpenFailed` event.
	pub fn dial(&self, locator: &Locator, options: Option<&[u8]>) -> Result<u64> {
		let handle = self.live()?;
		let owned = OwnedLocator::new(locator)?;
		let operation_options = options.map(|data| ffi::GlowcapTransportOperationOptions {
			data: data.as_ptr().cast::<c_void>(),
			size: data.len(),
		});
		let mut operation_id = 0u64;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `owned` keeps the locator view alive past this statement, `operation_options` (when `Some`) points at
		// `options`, which is borrowed for the whole call and which the callee reads only during the call, and
		// `operation_id` is an out-parameter the callee writes.
		check(unsafe {
			ffi::glowcap_driver_dial(
				handle.as_ptr(),
				owned.borrow_view()?,
				operation_options
					.as_ref()
					.map_or(core::ptr::null(), |options| options as *const _),
				&mut operation_id,
			)
		})?;
		Ok(operation_id)
	}

	/// Bind one listener. Accepted sessions arrive as `Accepted` events.
	pub fn listen(&self, transport: &str, designator: &str) -> Result<u64> {
		let handle = self.live()?;
		let mut listener = 0u64;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `transport` and `designator` are borrowed `str`s whose pointers and lengths stay live for the call;
		// `listener` is an out-parameter the callee writes.
		check(unsafe {
			ffi::glowcap_driver_listen(
				handle.as_ptr(),
				transport.as_ptr(),
				transport.len(),
				designator.as_ptr(),
				designator.len(),
				core::ptr::null(),
				&mut listener,
			)
		})?;
		Ok(listener)
	}

	/// Copy the listener's complete typed OCapN locator.
	pub fn listener_locator(&self, listener: u64) -> Result<Locator> {
		let handle = self.live()?;
		// SAFETY: `GlowcapLocatorView` is a plain C struct of integers and null pointers; all-zero is a valid value,
		// and the callee fills it before it is read.
		let mut view: sys::GlowcapLocatorView = unsafe { core::mem::zeroed() };
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `view` is an out-parameter the callee fills with a copy of the listener's locator.
		check(unsafe { ffi::glowcap_driver_listener_locator(handle.as_ptr(), listener, &mut view) })?;
		OwnedLocator::clone_view(&view)?.value()
	}

	/// Copy opaque provider-owned listener state.
	pub fn listener_restoration_state(&self, listener: u64) -> Result<Vec<u8>> {
		let handle = self.live()?;
		let mut needed = 0usize;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call; the
		// null buffer with length zero asks only for the needed size, which the callee writes to `needed`.
		let rc = unsafe {
			ffi::glowcap_driver_listener_restoration_state(
				handle.as_ptr(),
				listener,
				core::ptr::null_mut(),
				0,
				&mut needed,
			)
		};
		if rc != sys::OK && rc != sys::ERR_BUFFER_TOO_SMALL {
			check(rc)?;
		}
		if needed == 0 {
			return Ok(Vec::new());
		}
		let mut state = vec![0u8; needed];
		let mut copied = 0usize;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `state` is a live `Vec` of exactly `state.len()` writable bytes that the callee fills during the call;
		// `copied` is an out-parameter the callee writes.
		check(unsafe {
			ffi::glowcap_driver_listener_restoration_state(
				handle.as_ptr(),
				listener,
				state.as_mut_ptr(),
				state.len(),
				&mut copied,
			)
		})?;
		if copied != state.len() {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"listener restoration state changed during copy".to_string(),
			));
		}
		Ok(state)
	}

	/// Replace this listener's advertised locator through its native owner.
	pub fn advertise_listener(&self, listener: u64, locator: &Locator) -> Result<()> {
		let handle = self.live()?;
		let owned = OwnedLocator::new(locator)?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `owned` is a live `OwnedLocator`, so `borrow_view()` returns a view that stays valid through this statement
		// and the callee reads only during the call.
		check(unsafe { ffi::glowcap_driver_listener_advertise(handle.as_ptr(), listener, owned.borrow_view()?) })
	}

	/// Select this active listener's locator as the Host's acceptable location.
	pub fn select_listener(&self, listener: u64) -> Result<()> {
		let handle = self.live()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call
		check(unsafe { ffi::glowcap_driver_listener_select(handle.as_ptr(), listener) })
	}

	/// Stop one listener while preserving already committed events.
	pub fn close_listener(&self, listener: u64) -> Result<bool> {
		self.live()?.close_listener(listener)
	}

	pub(crate) fn claim_reference_exporter(
		&self,
		reference: &sys::GlowcapReference,
	) -> Result<Option<*mut ffi_host::GlowcapHostSession>> {
		let handle = self.live()?;
		let mut session = core::ptr::null_mut();
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `reference` is a borrowed `GlowcapReference` that stays live for the call; `session` is an out-parameter the
		// callee writes.
		check(unsafe { ffi::glowcap_driver_claim_reference_exporter(handle.as_ptr(), reference, &mut session) })?;
		Ok((!session.is_null()).then_some(session))
	}

	pub(crate) fn claim_exporter_session(&self, session: *mut ffi_host::GlowcapHostSession) -> Result<()> {
		let handle = self.live()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `session` is a Host session handle the caller passes for the Host this loop wraps.
		check(unsafe { ffi::glowcap_driver_claim_exporter_session(handle.as_ptr(), session) })
	}

	/// The one descriptor to park on. Owned by the loop. Never close it.
	pub fn readiness_fd(&self) -> Result<i32> {
		let handle = self.live()?;
		let mut fd: c_int = -1;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call; `fd`
		// is an out-parameter the callee writes; the descriptor stays owned by the loop.
		check(unsafe { ffi::glowcap_driver_readiness_fd(handle.as_ptr(), &mut fd) })?;
		Ok(fd)
	}

	/// One step plus a drain of the event queue into owned events.
	pub fn step(&self, timeout_ms: i32) -> Result<Option<Vec<LoopEvent>>> {
		let handle = self.live()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call
		let rc = unsafe { ffi::glowcap_driver_step(handle.as_ptr(), timeout_ms) };
		if rc == sys::WOULD_BLOCK {
			return Ok(None);
		}
		check(rc)?;
		Ok(Some(self.drain_events()?))
	}

	pub(super) fn drain_events(&self) -> Result<Vec<LoopEvent>> {
		let handle = self.live()?;
		let mut out = Vec::new();
		loop {
			// SAFETY: `GlowcapDriverEvent` is a plain C struct of integers and null pointers; all-zero is a valid
			// value, and the callee fills it before it is read.
			let mut event: GlowcapDriverEvent = unsafe { core::mem::zeroed() };
			// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
			// `event` is an out-parameter the callee fills.
			let rc = unsafe { ffi::glowcap_driver_next_event(handle.as_ptr(), &mut event) };
			if rc == sys::WOULD_BLOCK {
				return Ok(out);
			}
			check(rc)?;
			out.push(decode_event(&event)?);
		}
	}

	pub(super) fn session_release(&self, session: *mut ffi_host::GlowcapHostSession) -> Result<()> {
		let handle = self.live()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `session` is a Host session handle the caller passes for the Host this loop wraps.
		check(unsafe { ffi::glowcap_driver_session_release(handle.as_ptr(), session) })
	}

	pub(super) fn session_serve(&self, session: *mut ffi_host::GlowcapHostSession) -> Result<()> {
		let handle = self.live()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `session` is a Host session handle the caller passes for the Host this loop wraps.
		check(unsafe { ffi::glowcap_driver_session_serve(handle.as_ptr(), session) })
	}

	pub(super) fn begin_session_close(
		&self,
		session: *mut ffi_host::GlowcapHostSession,
		pending: PendingWork,
	) -> Result<()> {
		let handle = self.live()?;
		let options = pending.to_ffi()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `session` is a Host session handle the caller passes for the Host this loop wraps; `options` is a local
		// `GlowcapCloseOptions` borrowed for the call.
		check(unsafe { ffi::glowcap_driver_session_close(handle.as_ptr(), session, &options) })
	}

	pub(super) fn session_lifecycle_state(&self, session: *mut ffi_host::GlowcapHostSession) -> Result<(bool, i32)> {
		let handle = self.live()?;
		let mut lifecycle = 0;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `session` is a Host session handle the caller passes for the Host this loop wraps; `lifecycle` is an
		// out-parameter the callee writes.
		let rc = unsafe { ffi::glowcap_driver_session_lifecycle_state(handle.as_ptr(), session, &mut lifecycle) };
		if rc != sys::OK && rc != sys::ERR_TIMEOUT {
			check(rc)?;
		}
		Ok((crate::lifecycle_is_closed(lifecycle)?, rc))
	}

	pub fn wake(&self) -> Result<()> {
		let handle = self.live()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call
		check(unsafe { ffi::glowcap_driver_wake(handle.as_ptr()) })
	}

	pub fn detach_thread(&self) -> Result<()> {
		let handle = self.live()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call
		check(unsafe { ffi::glowcap_driver_detach_thread(handle.as_ptr()) })
	}

	pub(super) fn begin_close(&self, pending: PendingWork) -> Result<()> {
		let handle = self.live()?;
		let options = pending.to_ffi()?;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `options` is a local `GlowcapCloseOptions` borrowed for the call.
		check(unsafe { ffi::glowcap_driver_close(handle.as_ptr(), &options) })
	}

	pub(super) fn lifecycle_state(&self) -> Result<(bool, i32)> {
		let handle = self.live()?;
		let mut lifecycle = 0;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `lifecycle` is an out-parameter the callee writes.
		let rc = unsafe { ffi::glowcap_driver_lifecycle_state(handle.as_ptr(), &mut lifecycle) };
		if rc != sys::OK && rc != sys::ERR_TIMEOUT {
			check(rc)?;
		}
		Ok((crate::lifecycle_is_closed(lifecycle)?, rc))
	}

	pub(super) fn step_wait(&self) -> Result<Option<std::time::Duration>> {
		let handle = self.live()?;
		let mut wait_ms: i32 = -1;
		// SAFETY: `handle` borrows this `DriverLoop`'s live `LoopHandle`, so the loop is unreleased for this call;
		// `wait_ms` is an out-parameter the callee writes.
		check(unsafe { ffi::glowcap_driver_step_wait_ms(handle.as_ptr(), &mut wait_ms) })?;
		Ok((wait_ms >= 0).then(|| std::time::Duration::from_millis(wait_ms as u64)))
	}

	pub(super) fn release(&self) -> ReleaseOutcome {
		let Ok(mut slot) = self.handle.try_borrow_mut() else {
			return ReleaseOutcome::Refused(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"driver loop is in use".to_string(),
			));
		};
		let Some(handle) = slot.take() else {
			return ReleaseOutcome::Consumed(Ok(()));
		};
		match handle.release() {
			Released::Consumed(result) => ReleaseOutcome::Consumed(result),
			Released::Refused { handle, error } => {
				*slot = Some(handle);
				ReleaseOutcome::Refused(error)
			}
		}
	}

	/// Move a still-live loop out for a durable retry owner, with the
	/// allocator policy it was created under. `None` when nothing is left to
	/// transfer, or when a verb still borrows the loop. The slot then keeps
	/// the handle for the next release attempt.
	pub(super) fn transfer_refused(&self) -> Option<(LoopHandle, Option<Rc<ContextInner>>)> {
		let handle = self.handle.try_borrow_mut().ok()?.take()?;
		Some((handle, self.retained_context()))
	}

	/// Release from a last-owner path. A refusal transfers the live loop and
	/// its allocator policy to the recurring finalizer owner.
	pub(super) fn release_or_defer(&self) -> Result<()> {
		match self.release() {
			ReleaseOutcome::Consumed(result) => result,
			ReleaseOutcome::Refused(error) => {
				if let Some((handle, context)) = self.transfer_refused() {
					crate::finalizer::park_driver(handle, context, true);
				}
				Err(error)
			}
		}
	}
}

impl Drop for DriverLoop {
	fn drop(&mut self) {
		if let Err(error) = self.release_or_defer() {
			crate::record_runtime_failure(crate::FailureLayer::Driver, "driver-loop-drop-release", error);
		}
	}
}
