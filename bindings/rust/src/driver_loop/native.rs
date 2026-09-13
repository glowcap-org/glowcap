//! Synchronous ownership of one native driver loop.
//!
//! This leaf owns the raw archive handle, its construction policy, direct
//! verbs, and the consumed/refused release distinction. Async waiter and Host
//! choreography belongs to the parent `driver_loop` module.

use core::ffi::{c_int, c_void};
use std::cell::Cell;
use std::marker::PhantomData;
use std::rc::Rc;

use crate::driver_event::{LoopEvent, decode as decode_event};
use crate::sys::GlowcapTransportProvider;
use crate::sys::driver::{self as ffi, GlowcapDriverEvent, GlowcapDriverLoop, GlowcapDriverOptions};
use crate::sys::{self, host as ffi_host};
use crate::uri::OwnedLocator;
use crate::{ContextInner, Error, Locator, PendingWork, Result};

/// One archive-owned provider package. Registration acquires the package lease;
/// the driver releases it after every copied callback and transport handle.
pub struct ProviderPackage<'owner> {
	pub(crate) package: GlowcapTransportProvider,
	pub(crate) _owner: PhantomData<&'owner ()>,
}

/// One stepping native loop over one multi-session host.
pub struct DriverLoop {
	raw: *mut GlowcapDriverLoop,
	host: *mut ffi_host::GlowcapHost,
	released: Cell<bool>,
	_context: Option<Rc<ContextInner>>,
}

/// One release attempt, including whether native ownership was consumed.
pub(super) struct ReleaseOutcome {
	pub consumed: bool,
	pub result: Result<()>,
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
	/// 64-byte contract (durable identity, then a fresh session-key root);
	/// `options` owns the retained wire-buffer size and three positive wait bounds.
	pub fn open(seed: &[u8; 64], options: DriverLoopOptions) -> Result<Self> {
		let context = Rc::new(ContextInner::new()?);
		crate::require_archive_fingerprint(
			"host",
			unsafe { ffi_host::glowcap_host_archive_fingerprint() },
			sys::HOST_ARCHIVE_FINGERPRINT,
		)?;
		let mut host: *mut ffi_host::GlowcapHost = core::ptr::null_mut();
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
			unsafe { ffi::glowcap_driver_archive_fingerprint() },
			sys::DRIVER_ARCHIVE_FINGERPRINT,
		)?;
		let mut raw: *mut GlowcapDriverLoop = core::ptr::null_mut();
		let options = options.to_c();
		check(unsafe { ffi::glowcap_driver_take_host(host, &options, &mut raw) })?;
		Ok(Self {
			raw,
			host,
			released: Cell::new(false),
			_context: None,
		})
	}

	pub(super) fn retained_context(&self) -> Option<Rc<ContextInner>> {
		self._context.as_ref().map(Rc::clone)
	}

	/// The wrapped `GlowcapHost` handle for application verbs. Never release
	/// it separately; dropping the loop releases both.
	pub fn host(&self) -> *mut ffi_host::GlowcapHost {
		self.host
	}

	/// Install one provider package. Native registration retains its callback
	/// context before publication and releases it during loop teardown.
	pub fn add_provider(&self, provider: ProviderPackage<'_>) -> Result<()> {
		crate::driver_failure::add_provider(self.raw, &provider.package)
	}

	/// Report whether the native provider registry owns `transport`.
	pub fn has_transport(&self, transport: &str) -> Result<bool> {
		let mut present = 0u8;
		check(unsafe {
			ffi::glowcap_driver_has_transport(self.raw, transport.as_ptr(), transport.len(), &mut present)
		})?;
		Ok(present != 0)
	}

	/// Begin a nonblocking dial. A refusal before admission returns directly;
	/// after admission the outcome arrives as an `Opened`/`OpenFailed` event.
	pub fn dial(&self, locator: &Locator, options: Option<&[u8]>) -> Result<u64> {
		let owned = OwnedLocator::new(locator)?;
		let operation_options = options.map(|data| ffi::GlowcapTransportOperationOptions {
			data: data.as_ptr().cast::<c_void>(),
			size: data.len(),
		});
		let mut operation_id = 0u64;
		check(unsafe {
			ffi::glowcap_driver_dial(
				self.raw,
				owned.borrow_view()?,
				operation_options
					.as_ref()
					.map_or(core::ptr::null(), |options| options as *const _),
				&mut operation_id,
			)
		})?;
		Ok(operation_id)
	}

	/// Bind one listener; accepted sessions arrive as `Accepted` events.
	pub fn listen(&self, transport: &str, designator: &str) -> Result<u64> {
		let mut listener = 0u64;
		check(unsafe {
			ffi::glowcap_driver_listen(
				self.raw,
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
		let mut view: sys::GlowcapLocatorView = unsafe { core::mem::zeroed() };
		check(unsafe { ffi::glowcap_driver_listener_locator(self.raw, listener, &mut view) })?;
		OwnedLocator::clone_view(&view)?.value()
	}

	/// Copy opaque provider-owned listener state.
	pub fn listener_restoration_state(&self, listener: u64) -> Result<Vec<u8>> {
		let mut needed = 0usize;
		let rc = unsafe {
			ffi::glowcap_driver_listener_restoration_state(self.raw, listener, core::ptr::null_mut(), 0, &mut needed)
		};
		if rc != sys::OK && rc != sys::ERR_BUFFER_TOO_SMALL {
			check(rc)?;
		}
		if needed == 0 {
			return Ok(Vec::new());
		}
		let mut state = vec![0u8; needed];
		let mut copied = 0usize;
		check(unsafe {
			ffi::glowcap_driver_listener_restoration_state(
				self.raw,
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
		let owned = OwnedLocator::new(locator)?;
		check(unsafe { ffi::glowcap_driver_listener_advertise(self.raw, listener, owned.borrow_view()?) })
	}

	/// Select this active listener's locator as the Host's acceptable location.
	pub fn select_listener(&self, listener: u64) -> Result<()> {
		check(unsafe { ffi::glowcap_driver_listener_select(self.raw, listener) })
	}

	/// Stop one listener while preserving already committed events.
	pub fn close_listener(&self, listener: u64) -> Result<bool> {
		crate::driver_failure::close_listener(self.raw, listener)
	}

	pub(crate) fn claim_reference_exporter(
		&self,
		reference: &sys::GlowcapReference,
	) -> Result<Option<*mut ffi_host::GlowcapHostSession>> {
		let mut session = core::ptr::null_mut();
		check(unsafe { ffi::glowcap_driver_claim_reference_exporter(self.raw, reference, &mut session) })?;
		Ok((!session.is_null()).then_some(session))
	}

	/// The one descriptor to park on. Owned by the loop; never close it.
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: c_int = -1;
		check(unsafe { ffi::glowcap_driver_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// One step plus a drain of the event queue into owned events.
	pub fn step(&self, timeout_ms: i32) -> Result<Option<Vec<LoopEvent>>> {
		let rc = unsafe { ffi::glowcap_driver_step(self.raw, timeout_ms) };
		if rc == sys::WOULD_BLOCK {
			return Ok(None);
		}
		check(rc)?;
		Ok(Some(self.drain_events()?))
	}

	pub(super) fn drain_events(&self) -> Result<Vec<LoopEvent>> {
		let mut out = Vec::new();
		loop {
			let mut event: GlowcapDriverEvent = unsafe { core::mem::zeroed() };
			let rc = unsafe { ffi::glowcap_driver_next_event(self.raw, &mut event) };
			if rc == sys::WOULD_BLOCK {
				return Ok(out);
			}
			check(rc)?;
			out.push(decode_event(&event)?);
		}
	}

	pub(super) fn session_release(&self, session: *mut ffi_host::GlowcapHostSession) -> Result<()> {
		check(unsafe { ffi::glowcap_driver_session_release(self.raw, session) })
	}

	pub(super) fn session_serve(&self, session: *mut ffi_host::GlowcapHostSession) -> Result<()> {
		check(unsafe { ffi::glowcap_driver_session_serve(self.raw, session) })
	}

	pub(super) fn begin_session_close(
		&self,
		session: *mut ffi_host::GlowcapHostSession,
		pending: PendingWork,
	) -> Result<()> {
		let options = pending.to_ffi()?;
		check(unsafe { ffi::glowcap_driver_session_close(self.raw, session, &options) })
	}

	pub(super) fn session_lifecycle_state(&self, session: *mut ffi_host::GlowcapHostSession) -> Result<(bool, i32)> {
		let mut lifecycle = 0;
		let rc = unsafe { ffi::glowcap_driver_session_lifecycle_state(self.raw, session, &mut lifecycle) };
		if rc != sys::OK && rc != sys::ERR_TIMEOUT {
			check(rc)?;
		}
		Ok((crate::lifecycle_is_closed(lifecycle)?, rc))
	}

	pub fn wake(&self) -> Result<()> {
		check(unsafe { ffi::glowcap_driver_wake(self.raw) })
	}

	pub fn detach_thread(&self) -> Result<()> {
		check(unsafe { ffi::glowcap_driver_detach_thread(self.raw) })
	}

	pub(super) fn begin_close(&self, pending: PendingWork) -> Result<()> {
		let options = pending.to_ffi()?;
		check(unsafe { ffi::glowcap_driver_close(self.raw, &options) })
	}

	pub(super) fn lifecycle_state(&self) -> Result<(bool, i32)> {
		let mut lifecycle = 0;
		let rc = unsafe { ffi::glowcap_driver_lifecycle_state(self.raw, &mut lifecycle) };
		if rc != sys::OK && rc != sys::ERR_TIMEOUT {
			check(rc)?;
		}
		Ok((crate::lifecycle_is_closed(lifecycle)?, rc))
	}

	pub(super) fn step_wait(&self) -> Result<Option<std::time::Duration>> {
		let mut wait_ms: i32 = -1;
		check(unsafe { ffi::glowcap_driver_step_wait_ms(self.raw, &mut wait_ms) })?;
		Ok((wait_ms >= 0).then(|| std::time::Duration::from_millis(wait_ms as u64)))
	}

	pub(super) fn release(&self) -> ReleaseOutcome {
		if self.released.get() {
			return ReleaseOutcome {
				consumed: true,
				result: Ok(()),
			};
		}
		let (code, result) = crate::driver_failure::release(self.raw);
		let consumed = if crate::lifecycle::release_consumed(code) {
			self.released.set(true);
			true
		} else {
			false
		};
		ReleaseOutcome { consumed, result }
	}

	/// Transfer a refused release to a durable retry owner.
	pub(super) fn transfer_refused(&self) -> (*mut GlowcapDriverLoop, Option<Rc<ContextInner>>) {
		debug_assert!(!self.released.get());
		self.released.set(true);
		(self.raw, self.retained_context())
	}

	/// Release from a last-owner path. A refusal transfers the raw loop and its
	/// allocator policy to the recurring finalizer owner.
	pub(super) fn release_or_defer(&self) -> Result<()> {
		let release = self.release();
		if !release.consumed {
			let (raw, context) = self.transfer_refused();
			crate::finalizer::park_driver(raw, context, release.result.is_err());
		}
		release.result
	}
}

impl Drop for DriverLoop {
	fn drop(&mut self) {
		if let Err(error) = self.release_or_defer() {
			crate::record_runtime_failure(crate::FailureLayer::Driver, "driver-loop-drop-release", error);
		}
	}
}
