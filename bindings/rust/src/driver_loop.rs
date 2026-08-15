//! The native loop tier (ADR-0112): the public `connect`/`listen` route for
//! the shapes the driver archive carries, over a thin owner of one
//! `PancakeDriverLoop`.
//!
//! The driver archive composes transport providers and owns sockets and pumping, so this module's
//! whole job is choreography. [`DriverLoop`] is the step-shaped floor (create
//! the loop, register separately linked transports, dial and listen, step,
//! drain events in owned
//! form); [`LoopShared`] is the tokio face over it — it parks the `LocalSet`
//! on the loop's one readiness descriptor with an `AsyncFd`, steps with a
//! zero timeout when it signals, and routes drained events into dial
//! futures, the accept queue, and the adopted wrapper Host's vow table. A
//! product composition may mint one loop per connection, bind a listener, or
//! begin a dial on a loop-owned Host. The byte-fed pump (`crate::pump`) serves explicit
//! externally supplied channels and Hosts that already own such channels.
//!
//! One thread drives one loop from `open` to drop; `wake` is the family's
//! one cross-thread call, and `detach_thread` the sequential handover.
//! Completions arrive as [`LoopEvent::Completion`] carrying the generated
//! [`HostAction`] decode — the byte-fed drain's own SETTLE/FAIL shapes — so
//! loop events route vow outcomes with the same vocabulary the pump uses.

use core::ffi::{c_int, c_void};
use core::future::Future;
use core::pin::Pin;
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet, VecDeque};
use std::marker::PhantomData;
use std::rc::{Rc, Weak};

use tokio::io::unix::AsyncFd;
use tokio::io::Interest;
use tokio::sync::{oneshot, Notify};

use crate::host::{drain_pending_releases, try_spawn_local, try_spawn_local_handle, HostShared};
use crate::host_action_gen::{self, HostAction};
use crate::session::Session;
use crate::session_shared::{io_err, SessionShared};
use crate::sys::driver::{PancakeDriverEvent, PancakeDriverLoop, PancakeDriverOptions, PancakeTransportProvider};
use crate::sys::{self, driver as ffi, host as ffi_host};
use crate::trampoline::DeliverGuard;
use crate::uri::OwnedLocator;
use crate::{ContextInner, Error, Locator, PendingWork, Result};

/// One archive-owned provider package. Registration acquires the package lease;
/// the driver releases it after every copied callback and transport handle.
pub struct ProviderPackage<'owner> {
	pub(crate) package: PancakeTransportProvider,
	pub(crate) _owner: PhantomData<&'owner ()>,
}

type InstallFuture = Pin<Box<dyn Future<Output = Result<()>>>>;

/// A configured transport package that can install itself into a native loop.
/// Transport modules construct this value; the driver registry alone records
/// which transport symbols the package registered.
#[derive(Clone)]
pub struct Provider {
	install: Rc<dyn Fn(Rc<LoopShared>) -> InstallFuture>,
}

impl Provider {
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion", feature = "relay"))]
	pub(crate) fn new<F, Fut>(install: F) -> Self
	where
		F: Fn(Rc<LoopShared>) -> Fut + 'static,
		Fut: Future<Output = Result<()>> + 'static,
	{
		Self {
			install: Rc::new(move |lp| Box::pin(install(lp))),
		}
	}

	pub(crate) async fn install(&self, lp: Rc<LoopShared>) -> Result<()> {
		(self.install)(lp).await
	}
}

/// One drained loop event, in owned form (the C views die at the next pop).
pub enum LoopEvent {
	/// The admitted dial named by the operation id opened; the session handle takes
	/// every `pancake_host_*` verb.
	Opened {
		operation_id: u64,
		session: *mut ffi_host::PancakeHostSession,
	},
	OpenFailed {
		operation_id: u64,
		failure: DriverEventFailure,
	},
	ListenerReady {
		listener: u64,
	},
	ListenerFailed {
		listener: u64,
		failure: DriverEventFailure,
	},
	Accepted {
		listener: u64,
		session: *mut ffi_host::PancakeHostSession,
	},
	/// The wire closed inside a step; the handle stays valid until
	/// [`DriverLoop::session_release`], its vows already broken.
	SessionClosed {
		session: *mut ffi_host::PancakeHostSession,
		failure: Option<DriverEventFailure>,
	},
	/// A vow settled with no in-process listener, in the byte-fed queue's own
	/// decoded shape (`Settle` or `Fail`).
	Completion(HostAction),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriverEventFailure {
	pub primary_result: i32,
	pub primary_name: String,
	pub secondary_result: i32,
	pub secondary_count: u32,
	pub secondary_name: String,
}

/// One stepping native loop over one multi-session host.
pub struct DriverLoop {
	raw: *mut PancakeDriverLoop,
	host: *mut ffi_host::PancakeHost,
	released: Cell<bool>,
	_context: Option<Rc<ContextInner>>,
}

/// Native loop construction policy. `wire_buffer_bytes` is retained per
/// stream direction, or once for multiplexed read staging, for each live session.
#[derive(Clone, Copy, Debug)]
pub struct DriverLoopOptions {
	pub wire_buffer_bytes: usize,
	pub max_pending_opens: usize,
	pub handshake_ms: u32,
	pub listener_setup_ms: u32,
	pub settle_ms: u32,
}

impl Default for DriverLoopOptions {
	fn default() -> Self {
		Self {
			wire_buffer_bytes: sys::DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
			max_pending_opens: sys::DRIVER_DEFAULT_MAX_PENDING_OPENS,
			handshake_ms: sys::DRIVER_DEFAULT_HANDSHAKE_MS,
			listener_setup_ms: sys::DRIVER_DEFAULT_LISTENER_SETUP_MS,
			settle_ms: sys::DRIVER_DEFAULT_SETTLE_MS,
		}
	}
}

impl DriverLoopOptions {
	fn to_c(self) -> PancakeDriverOptions {
		PancakeDriverOptions {
			abi_version: sys::DRIVER_OPTIONS_ABI_VERSION,
			struct_size: core::mem::size_of::<PancakeDriverOptions>(),
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
		let mut host: *mut ffi_host::PancakeHost = core::ptr::null_mut();
		crate::host::check_host(unsafe {
			ffi_host::pancake_host_new_in(
				context.raw,
				seed.as_ptr(),
				seed.len(),
				1 << 16,
				1,
				sys::CODEC_SYRUP,
				sys::CAPTP_V1_0,
				sys::FEATURE_FULL,
				0,
				&mut host,
			)
		})?;
		match Self::take_host(host, options) {
			Ok(mut loop_) => {
				loop_._context = Some(context);
				Ok(loop_)
			}
			Err(err) => {
				unsafe { ffi_host::pancake_host_release(host) };
				Err(err)
			}
		}
	}

	/// Transfer an existing quiescent Host to a native loop. The C transaction
	/// leaves Host ownership unchanged on failure and makes this loop the sole
	/// transport/action-drain/release owner on success.
	pub(crate) fn take_host(host: *mut ffi_host::PancakeHost, options: DriverLoopOptions) -> Result<Self> {
		let mut raw: *mut PancakeDriverLoop = core::ptr::null_mut();
		let options = options.to_c();
		check(unsafe { ffi::pancake_driver_take_host(host, &options, &mut raw) })?;
		let loop_ = Self {
			raw,
			host,
			released: Cell::new(false),
			_context: None,
		};
		Ok(loop_)
	}

	fn retained_context(&self) -> Option<Rc<ContextInner>> {
		self._context.as_ref().map(Rc::clone)
	}

	/// The wrapped `PancakeHost` handle for application verbs. Never release
	/// it separately; dropping the loop releases both.
	pub fn host(&self) -> *mut ffi_host::PancakeHost {
		self.host
	}

	/// Install one provider package. Native registration retains its callback
	/// context before publication and releases it during loop teardown.
	pub fn add_provider(&self, provider: ProviderPackage<'_>) -> Result<()> {
		check(unsafe { ffi::pancake_driver_add_provider(self.raw, &provider.package) })?;
		Ok(())
	}

	/// Report whether the native provider registry owns `transport`.
	pub fn has_transport(&self, transport: &str) -> Result<bool> {
		let mut present = 0u8;
		check(unsafe {
			ffi::pancake_driver_has_transport(self.raw, transport.as_ptr(), transport.len(), &mut present)
		})?;
		Ok(present != 0)
	}

	/// Begin a nonblocking dial. A refusal before admission returns directly;
	/// after admission the outcome arrives as an `Opened`/`OpenFailed` event
	/// carrying the returned operation id. Transport completion and the handshake
	/// advance through later `step` calls.
	pub fn dial(&self, locator: &Locator, options: Option<&[u8]>) -> Result<u64> {
		let owned = OwnedLocator::new(locator)?;
		let operation_options = options.map(|data| ffi::PancakeTransportOperationOptions {
			data: data.as_ptr().cast::<c_void>(),
			size: data.len(),
		});
		let mut operation_id = 0u64;
		check(unsafe {
			ffi::pancake_driver_dial(
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

	/// Bind one listener on an archive-native transport; accepted sessions arrive as
	/// `Accepted` events carrying the returned id.
	pub fn listen(&self, transport: &str, designator: &str) -> Result<u64> {
		let mut listener = 0u64;
		check(unsafe {
			ffi::pancake_driver_listen(
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
		let mut view: sys::PancakeLocatorView = unsafe { core::mem::zeroed() };
		check(unsafe { ffi::pancake_driver_listener_locator(self.raw, listener, &mut view) })?;
		OwnedLocator::clone_view(&view)?.value()
	}

	/// Copy opaque provider-owned listener state. The driver knows only that the
	/// bytes are a size-query/copy value; the transport package that produced
	/// them owns their meaning.
	pub fn listener_restoration_state(&self, listener: u64) -> Result<Vec<u8>> {
		let mut needed = 0usize;
		let rc = unsafe {
			ffi::pancake_driver_listener_restoration_state(self.raw, listener, core::ptr::null_mut(), 0, &mut needed)
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
			ffi::pancake_driver_listener_restoration_state(
				self.raw,
				listener,
				if state.is_empty() {
					core::ptr::null_mut()
				} else {
					state.as_mut_ptr()
				},
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
		check(unsafe { ffi::pancake_driver_listener_advertise(self.raw, listener, owned.borrow_view()?) })
	}

	/// Select this active listener's locator as the Host's acceptable location.
	pub fn select_listener(&self, listener: u64) -> Result<()> {
		check(unsafe { ffi::pancake_driver_listener_select(self.raw, listener) })
	}

	/// Stop one listener. Events committed before close remain drainable; no
	/// later accepted event can name it after this returns.
	pub fn close_listener(&self, listener: u64) -> Result<()> {
		check(unsafe { ffi::pancake_driver_listener_close(self.raw, listener) })
	}

	/// Resolve and claim the exporter session named by one Host capability.
	pub(crate) fn claim_reference_exporter(
		&self,
		reference: &sys::PancakeReference,
	) -> Result<Option<*mut ffi_host::PancakeHostSession>> {
		let mut session = core::ptr::null_mut();
		check(unsafe { ffi::pancake_driver_claim_reference_exporter(self.raw, reference, &mut session) })?;
		Ok((!session.is_null()).then_some(session))
	}

	/// The one descriptor to park on (readable while any work is pending).
	/// Owned by the loop; never close it.
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: c_int = -1;
		check(unsafe { ffi::pancake_driver_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// One step (parking up to `timeout_ms` when nothing is pending) plus a
	/// drain of the event queue into owned events. `None` means the loop is
	/// drained; edge-triggered runtimes must reach it before clearing readiness.
	pub fn step(&self, timeout_ms: i32) -> Result<Option<Vec<LoopEvent>>> {
		let rc = unsafe { ffi::pancake_driver_step(self.raw, timeout_ms) };
		if rc == sys::WOULD_BLOCK {
			return Ok(None);
		}
		check(rc)?;
		Ok(Some(self.drain_events()?))
	}

	/// Drain events already committed by earlier steps without advancing the
	/// loop. This is the listener-close boundary: close first prevents a later
	/// accept from committing, then this drain preserves everything that had.
	fn drain_events(&self) -> Result<Vec<LoopEvent>> {
		let mut out = Vec::new();
		loop {
			let mut event: PancakeDriverEvent = unsafe { core::mem::zeroed() };
			let rc = unsafe { ffi::pancake_driver_next_event(self.raw, &mut event) };
			if rc == sys::WOULD_BLOCK {
				return Ok(out);
			}
			check(rc)?;
			out.push(decode_event(&event)?);
		}
	}

	/// Release one loop-owned session (never `pancake_host_session_release`
	/// on these). Queued events naming it are dropped by the loop.
	pub fn session_release(&self, session: *mut ffi_host::PancakeHostSession) -> Result<()> {
		check(unsafe { ffi::pancake_driver_session_release(self.raw, session) })
	}

	/// Begin delivering application frames for a session surfaced by an
	/// [`Opened`](LoopEvent::Opened) or [`Accepted`](LoopEvent::Accepted) event.
	/// Call this after post-open setup; repeated calls are harmless.
	pub fn session_serve(&self, session: *mut ffi_host::PancakeHostSession) -> Result<()> {
		check(unsafe { ffi::pancake_driver_session_serve(self.raw, session) })
	}

	fn begin_session_close(&self, session: *mut ffi_host::PancakeHostSession, pending: PendingWork) -> Result<()> {
		let options = pending.to_ffi()?;
		check(unsafe { ffi::pancake_driver_session_close(self.raw, session, &options) })
	}

	fn session_lifecycle_state(&self, session: *mut ffi_host::PancakeHostSession) -> Result<(bool, i32)> {
		let mut lifecycle = 0;
		let rc = unsafe { ffi::pancake_driver_session_lifecycle_state(self.raw, session, &mut lifecycle) };
		if rc != sys::OK && rc != sys::ERR_TIMEOUT {
			check(rc)?;
		}
		Ok((lifecycle == sys::LIFECYCLE_CLOSED, rc))
	}

	/// Make a parked step return, from any thread — the family's one
	/// cross-thread call.
	pub fn wake(&self) -> Result<()> {
		check(unsafe { ffi::pancake_driver_wake(self.raw) })
	}

	/// Release the calling thread's claim at a quiescent boundary, before
	/// another thread begins stepping. A sequential handover, never
	/// permission for concurrent access.
	pub fn detach_thread(&self) -> Result<()> {
		check(unsafe { ffi::pancake_driver_detach_thread(self.raw) })
	}

	fn begin_close(&self, pending: PendingWork) -> Result<()> {
		let options = pending.to_ffi()?;
		check(unsafe { ffi::pancake_driver_close(self.raw, &options) })
	}

	fn lifecycle_state(&self) -> Result<(bool, i32)> {
		let mut lifecycle = 0;
		let rc = unsafe { ffi::pancake_driver_lifecycle_state(self.raw, &mut lifecycle) };
		if rc != sys::OK && rc != sys::ERR_TIMEOUT {
			check(rc)?;
		}
		Ok((lifecycle == sys::LIFECYCLE_CLOSED, rc))
	}

	/// The longest a close driver may park before stepping again with a zero
	/// timeout: the time until the nearest pending-work deadline (close grace,
	/// session close grace, or a dial or listener setup budget), clamped at
	/// zero, or `None` when no finite deadline is pending and readiness alone
	/// advances the loop. A deadline expiry takes effect only inside a step,
	/// so the timer wake is what applies it. Native refusal reaches the owning
	/// close driver; it must not become an unbounded park.
	fn step_wait(&self) -> Result<Option<std::time::Duration>> {
		let mut wait_ms: i32 = -1;
		let rc = unsafe { ffi::pancake_driver_step_wait_ms(self.raw, &mut wait_ms) };
		check(rc)?;
		if wait_ms >= 0 {
			Ok(Some(std::time::Duration::from_millis(wait_ms as u64)))
		} else {
			Ok(None)
		}
	}

	fn release(&self) -> Result<()> {
		if self.released.get() {
			return Ok(());
		}
		check(unsafe { ffi::pancake_driver_release(self.raw) })?;
		self.released.set(true);
		Ok(())
	}
}

fn decode_event(event: &PancakeDriverEvent) -> Result<LoopEvent> {
	let decoded = match event.kind {
		sys::DRIVER_EVENT_OPENED => LoopEvent::Opened {
			operation_id: event.operation_id,
			session: event.session,
		},
		sys::DRIVER_EVENT_OPEN_FAILED => LoopEvent::OpenFailed {
			operation_id: event.operation_id,
			failure: decode_failure(event),
		},
		sys::DRIVER_EVENT_LISTENER_READY => LoopEvent::ListenerReady {
			listener: event.listener_id,
		},
		sys::DRIVER_EVENT_LISTENER_FAILED => LoopEvent::ListenerFailed {
			listener: event.listener_id,
			failure: decode_failure(event),
		},
		sys::DRIVER_EVENT_ACCEPTED => LoopEvent::Accepted {
			listener: event.listener_id,
			session: event.session,
		},
		sys::DRIVER_EVENT_SESSION_CLOSED => LoopEvent::SessionClosed {
			session: event.session,
			failure: (event.primary_result != sys::OK).then(|| decode_failure(event)),
		},
		sys::DRIVER_EVENT_COMPLETION => {
			if !host_action_gen::is_known_kind(event.action.kind) {
				return Err(Error::with_detail(
					sys::ERR_INTERNAL,
					format!("driver returned unknown host action kind {}", event.action.kind),
				));
			}
			LoopEvent::Completion(host_action_gen::decode(&event.action))
		}
		_ => {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("driver returned unknown event kind {}", event.kind),
			));
		}
	};
	Ok(decoded)
}

fn decode_failure(event: &PancakeDriverEvent) -> DriverEventFailure {
	DriverEventFailure {
		primary_result: event.primary_result,
		primary_name: message_of(event.primary_name, event.primary_name_len),
		secondary_result: event.secondary_result,
		secondary_count: event.secondary_count,
		secondary_name: message_of(event.secondary_name, event.secondary_name_len),
	}
}

fn message_of(ptr: *const u8, len: usize) -> String {
	if ptr.is_null() || len == 0 {
		return String::new();
	}
	let view = unsafe { core::slice::from_raw_parts(ptr, len) };
	String::from_utf8_lossy(view).into_owned()
}

impl Drop for DriverLoop {
	fn drop(&mut self) {
		if let Err(error) = self.release() {
			crate::record_runtime_failure(crate::FailureLayer::Driver, "driver-loop-drop-release", error);
		}
	}
}

fn driver_event_failure(failure: DriverEventFailure, operation: &str) -> Error {
	let detail = if failure.primary_name.is_empty() {
		format!("{operation} failed")
	} else {
		format!("{operation} failed: {}", failure.primary_name)
	};
	let mut error = Error::with_detail(failure.primary_result, detail);
	if failure.secondary_count != 0 {
		error = error.with_secondary(Error::with_detail(failure.secondary_result, failure.secondary_name));
		error.secondary_count = failure.secondary_count;
	}
	error
}

fn loop_closed_error() -> Error {
	Error::with_detail(sys::ERR_CLOSED, "the loop is closed".to_string())
}

enum UnclaimedSession {
	Open,
	Closed(Option<Error>),
}

/// The tokio face of one native loop (ADR-0112): the shared owner the public
/// `connect`/`listen` route drives. It parks the running `LocalSet` on the
/// loop's readiness descriptor, steps with a zero timeout when it signals or
/// when a Host verb kicks, and routes drained events — dial outcomes into
/// futures, accepted sessions into a queue, completions into the adopted
/// wrapper Host's vow table. One `LocalSet` thread drives one loop; every
/// handle here is `!Send` by construction.
pub(crate) struct LoopShared {
	driver: DriverLoop,
	// A transferred Host may borrow a caller-supplied allocator. Native driver
	// teardown uses that allocator, so its lease must outlive the driver rather
	// than only the wrapper Host that no longer owns native release.
	_context: Option<Rc<ContextInner>>,
	/// The identity half of the loop host's 64-byte seed, retained so the
	/// adopted wrapper Host answers `designator()` like a byte-fed one.
	seed: [u8; 32],
	released: Cell<bool>,
	/// First background driver failure. Once set, every public operation
	/// refuses with the same exact cause instead of treating a dead step as idle.
	terminal_failure: RefCell<Option<Error>>,
	close_task_started: Cell<bool>,
	/// Re-entrancy latch: `pancake_driver_step` must never nest (a behavior
	/// fired inside a step kicks through deferred tasks, never a direct step).
	stepping: Cell<bool>,
	parked: Cell<bool>,
	park: RefCell<Option<tokio::task::AbortHandle>>,
	pending_dials: RefCell<HashMap<u64, oneshot::Sender<Result<*mut ffi_host::PancakeHostSession>>>>,
	pending_listeners: RefCell<HashMap<u64, oneshot::Sender<Result<()>>>>,
	accepts: RefCell<VecDeque<(u64, *mut ffi_host::PancakeHostSession)>>,
	/// Event-delivered handles not yet wrapped by the binding. A terminal event
	/// that follows OPENED/ACCEPTED in the same drain retains its exact failure;
	/// the handle stays valid until adoption or explicit release.
	unclaimed_sessions: RefCell<HashMap<usize, UnclaimedSession>>,
	listeners: RefCell<HashSet<u64>>,
	listener_failures: RefCell<HashMap<u64, Error>>,
	accept_wake: Notify,
	/// Wakes close drivers parked on loop progress. Every path that steps the
	/// loop or dispatches its events signals it afterward, so a driver's
	/// re-check never depends on a fixed re-poll interval.
	activity: Notify,
	wrapper: RefCell<Option<Weak<HostShared>>>,
}

#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
struct PendingListenerSetup {
	lp: Rc<LoopShared>,
	listener: u64,
	armed: bool,
}

#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
impl Drop for PendingListenerSetup {
	fn drop(&mut self) {
		if !self.armed || self.lp.released.get() {
			return;
		}
		self.lp.cancel_listener_setup(self.listener);
	}
}

impl LoopShared {
	pub(crate) fn retained_context(&self) -> Option<Rc<ContextInner>> {
		self._context.as_ref().map(Rc::clone)
	}

	/// Create the loop over a fresh host (identity and session-key root drawn
	/// here, at the binding's entropy boundary). The budgets must be positive:
	/// the loop refuses an unbounded wait by construction.
	pub(crate) fn open(handshake_ms: u32, settle_ms: u32) -> Result<Rc<LoopShared>> {
		Self::open_with_durable_seed(handshake_ms, settle_ms, None)
	}

	/// Open a loop with an optional durable identity seed and a fresh
	/// per-process session-key root.
	pub(crate) fn open_with_durable_seed(
		handshake_ms: u32,
		settle_ms: u32,
		durable_seed: Option<[u8; 32]>,
	) -> Result<Rc<LoopShared>> {
		let mut seed = [0u8; 64];
		getrandom::fill(&mut seed).map_err(|error| {
			Error::with_detail(sys::ERR_IO, format!("drawing the driver Host seed failed: {error}"))
		})?;
		if let Some(durable) = durable_seed {
			seed[..32].copy_from_slice(&durable);
		}
		let driver = DriverLoop::open(
			&seed,
			DriverLoopOptions {
				handshake_ms,
				settle_ms,
				..DriverLoopOptions::default()
			},
		)?;
		let context = driver.retained_context();
		let mut seed32 = [0u8; 32];
		seed32.copy_from_slice(&seed[..32]);
		Ok(Rc::new(LoopShared {
			driver,
			_context: context,
			seed: seed32,
			released: Cell::new(false),
			terminal_failure: RefCell::new(None),
			close_task_started: Cell::new(false),
			stepping: Cell::new(false),
			parked: Cell::new(false),
			park: RefCell::new(None),
			pending_dials: RefCell::new(HashMap::new()),
			pending_listeners: RefCell::new(HashMap::new()),
			accepts: RefCell::new(VecDeque::new()),
			unclaimed_sessions: RefCell::new(HashMap::new()),
			listeners: RefCell::new(HashSet::new()),
			listener_failures: RefCell::new(HashMap::new()),
			accept_wake: Notify::new(),
			activity: Notify::new(),
			wrapper: RefCell::new(None),
		}))
	}

	/// Promote an existing wrapper Host to the native driver before its first
	/// network operation. The loop points back weakly; the Host owns the loop,
	/// so dropping or closing the Host remains the terminal lifetime boundary.
	pub(crate) fn take_host(host: &Rc<HostShared>, handshake_ms: u32, settle_ms: u32) -> Result<Rc<LoopShared>> {
		let driver = DriverLoop::take_host(
			host.raw(),
			DriverLoopOptions {
				handshake_ms,
				settle_ms,
				..DriverLoopOptions::default()
			},
		)?;
		Ok(Rc::new(LoopShared {
			driver,
			_context: host.retained_context(),
			seed: host.durable_seed(),
			released: Cell::new(false),
			terminal_failure: RefCell::new(None),
			close_task_started: Cell::new(false),
			stepping: Cell::new(false),
			parked: Cell::new(false),
			park: RefCell::new(None),
			pending_dials: RefCell::new(HashMap::new()),
			pending_listeners: RefCell::new(HashMap::new()),
			accepts: RefCell::new(VecDeque::new()),
			unclaimed_sessions: RefCell::new(HashMap::new()),
			listeners: RefCell::new(HashSet::new()),
			listener_failures: RefCell::new(HashMap::new()),
			accept_wake: Notify::new(),
			activity: Notify::new(),
			wrapper: RefCell::new(Some(Rc::downgrade(host))),
		}))
	}

	pub(crate) fn guard_handle(&self) -> Result<()> {
		if let Some(error) = self.terminal_failure.borrow().clone() {
			Err(error)
		} else if self.released.get() {
			Err(loop_closed_error())
		} else {
			Ok(())
		}
	}

	/// Terminalize a background step or task-admission failure. Every pending
	/// binding waiter is completed before driver release, then the wrapper Host
	/// is retired through its ordinary loop-teardown authority. No caller has to
	/// infer failure from a loop that merely stopped making progress.
	pub(crate) fn fail_background(self: &Rc<Self>, error: Error) {
		{
			let mut retained = self.terminal_failure.borrow_mut();
			if retained.is_some() {
				return;
			}
			*retained = Some(error.clone());
		}
		let code = error.code();
		let detail = format!("driver loop failed: {error}");
		if let Some(park) = self.park.borrow_mut().take() {
			park.abort();
		}
		for (_, waiter) in self.pending_dials.borrow_mut().drain() {
			// A missing receiver is the caller's cancellation; the operation is
			// already terminal here and owns no native handle.
			drop(waiter.send(Err(error.clone())));
		}
		for (_, waiter) in self.pending_listeners.borrow_mut().drain() {
			// As above: cancellation removed the only observer, not cleanup work.
			drop(waiter.send(Err(error.clone())));
		}
		if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
			host.fail_pending_vows(code, &detail);
			match self.driver.release() {
				Ok(()) => {
					self.released.set(true);
					host.finish_failed_loop_teardown(error);
				}
				Err(release_error) => host.fail_close(error.with_secondary(release_error)),
			}
		} else {
			match self.driver.release() {
				Ok(()) => self.released.set(true),
				Err(release_error) => crate::record_runtime_failure(
					crate::FailureLayer::Driver,
					"orphaned-driver-loop-release",
					error.with_secondary(release_error),
				),
			}
		}
		self.listeners.borrow_mut().clear();
		self.accepts.borrow_mut().clear();
		self.unclaimed_sessions.borrow_mut().clear();
		self.accept_wake.notify_waiters();
		self.note_step_activity();
	}

	#[cfg(test)]
	pub(crate) fn is_released(&self) -> bool {
		self.released.get()
	}

	/// Register a provider through the native driver's occupancy authority.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion", feature = "relay"))]
	pub(crate) fn add_provider(&self, provider: ProviderPackage<'_>) -> Result<()> {
		self.guard_handle()?;
		self.driver.add_provider(provider)
	}

	/// The public wrapper Host adopted over this loop's native host: every
	/// application verb, publish trampoline, and vow settle works on it, while
	/// the loop stays the one action drain and the one release authority.
	/// Built on first call; call it on the driving thread.
	pub(crate) fn wrapper_host(self: &Rc<Self>) -> Result<Rc<HostShared>> {
		self.guard_handle()?;
		if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
			return Ok(host);
		}
		let host = HostShared::adopt_loop(self.driver.host(), self.seed, Rc::clone(self))?;
		*self.wrapper.borrow_mut() = Some(Rc::downgrade(&host));
		Ok(host)
	}

	/// Arm the readiness descriptor and the native driver's progress clock on
	/// the running `LocalSet`. Descriptor readiness advances I/O; the clock
	/// advances silent handshake, listener, and close deadlines. The descriptor
	/// is duplicated so the park task's registration can never race the loop's
	/// release into a reused fd.
	fn ensure_started(self: &Rc<Self>) -> Result<()> {
		self.guard_handle()?;
		if self.parked.replace(true) {
			return Ok(());
		}
		let started = (|| {
			let fd = self.driver.readiness_fd()?;
			let fd = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) }
				.try_clone_to_owned()
				.map_err(io_err)?;
			let lp = Rc::clone(self);
			try_spawn_local_handle(async move {
				let Ok(afd) = AsyncFd::with_interest(fd, Interest::READABLE) else {
					lp.fail_background(Error::with_detail(
						sys::ERR_INTERNAL,
						"the driver readiness descriptor could not be registered".to_string(),
					));
					return;
				};
				loop {
					// Arm activity before reading the deadline. A verb or sibling
					// step that changes the native wait between those operations
					// wakes this select and makes it rebuild the clock.
					let activity = lp.step_activity();
					tokio::pin!(activity);
					activity.as_mut().enable();
					let wait = match lp.driver.step_wait() {
						Ok(wait) => wait,
						Err(error) => {
							lp.fail_background(error);
							return;
						}
					};
					let ready = match wait {
						Some(wait) => tokio::select! {
							ready = afd.readable() => Some(ready),
							() = tokio::time::sleep(wait) => None,
							() = activity.as_mut() => continue,
						},
						None => tokio::select! {
							ready = afd.readable() => Some(ready),
							() = activity.as_mut() => continue,
						},
					};
					if lp.released.get() {
						return;
					}
					if let Err(error) = lp.step_now() {
						lp.fail_background(error);
						return;
					}
					if let Some(ready) = ready {
						let Ok(mut guard) = ready else {
							lp.fail_background(Error::with_detail(
								sys::ERR_INTERNAL,
								"the driver readiness wait failed".to_string(),
							));
							return;
						};
						// Clear only after step_now reached WOULD_BLOCK, preserving
						// the edge-triggered drain contract.
						guard.clear_ready();
					}
					if lp.released.get() {
						return;
					}
				}
			})
			.ok_or_else(|| {
				Error::with_detail(
					sys::ERR_INTERNAL,
					"the loop needs a running LocalSet to park on".to_string(),
				)
			})
		})();
		let task = match started {
			Ok(task) => task,
			Err(error) => {
				self.parked.set(false);
				return Err(error);
			}
		};
		*self.park.borrow_mut() = Some(task.abort_handle());
		Ok(())
	}

	/// Schedule one loop step soon — how a wrapper verb's kick reaches the
	/// drain. Deferred through a task, so a kick from inside a behavior turn
	/// steps only after the enclosing step (or feed) unwinds.
	pub(crate) fn schedule_step(self: &Rc<Self>) {
		if self.released.get() {
			return;
		}
		let lp = Rc::clone(self);
		if !try_spawn_local(async move {
			if let Err(error) = lp.step_now() {
				lp.fail_background(error);
			}
		}) {
			self.fail_background(Error::with_detail(
				sys::ERR_INTERNAL,
				"the driver loop needs a running LocalSet to schedule progress".to_string(),
			));
		}
	}

	/// The registration half of a close driver's wait. The returned future
	/// must be pinned and enabled before the step and state check it guards,
	/// so a rival path's step landing between that check and the park still
	/// wakes the driver.
	pub(crate) fn step_activity(&self) -> tokio::sync::futures::Notified<'_> {
		self.activity.notified()
	}

	/// Wake every close driver parked on loop activity. Waiters re-check
	/// state on every wake, so a spare signal costs one check and a missed
	/// one is a hang.
	fn note_step_activity(&self) {
		self.activity.notify_waiters();
	}

	/// The close drivers' park bound, delegated to the native deadline export.
	pub(crate) fn step_wait(&self) -> Result<Option<std::time::Duration>> {
		self.driver.step_wait()
	}

	/// Announce the embedder is serving `session`: post-open setup is done, so
	/// the loop may deliver its inbound (early bytes replay in order).
	/// Idempotent; the byte-fed serve-resume contract at the loop tier.
	pub(crate) fn serve_session(self: &Rc<Self>, session: *mut ffi_host::PancakeHostSession) -> Result<()> {
		if self.released.get() || session.is_null() {
			return Ok(());
		}
		self.guard_handle()?;
		self.driver.session_serve(session)?;
		self.schedule_step();
		Ok(())
	}

	/// Drain zero-timeout steps through quiescence and dispatch their events,
	/// on the loop thread. Reaching WOULD_BLOCK is what permits an
	/// edge-triggered readiness guard to clear without losing a sibling source.
	pub(crate) fn step_now(self: &Rc<Self>) -> Result<()> {
		if self.released.get() || self.stepping.get() || crate::trampoline::inside_turn() {
			return Ok(());
		}
		let mut stepped = false;
		loop {
			let outcome = {
				self.stepping.set(true);
				let host = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
				// The head of the byte-fed kick, one tier up: run parked releases
				// and reclaimed-import releases before the step, so a dropped
				// `Ref`'s op:gc-exports flushes in the very step this kick runs.
				drain_pending_releases();
				let gc_result = host.as_ref().map_or(Ok(()), |host| crate::gc::drain(host));
				let result = match gc_result {
					Ok(()) => {
						// The step is the deliver: behaviors fire inside it, and the
						// bracket latches their turns to this loop's wrapper Host.
						let _bracket = host.as_ref().map(DeliverGuard::enter_host);
						self.driver.step(0)
					}
					Err(error) => Err(error),
				};
				self.stepping.set(false);
				result
			};
			drain_pending_releases();
			match outcome {
				Ok(Some(events)) => {
					stepped = true;
					if !events.is_empty() {
						self.dispatch(events);
					}
				}
				Ok(None) => break,
				Err(error) => return Err(error),
			}
		}
		// A pass that ran at least one native step advanced state a close
		// driver may be parked on. An idle pass stays silent, which keeps a
		// parked driver's own quiescent re-step from waking itself in an
		// endless exchange.
		if stepped {
			self.note_step_activity();
		}
		Ok(())
	}

	fn dispatch(self: &Rc<Self>, events: Vec<LoopEvent>) {
		let host = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
		for event in events {
			match event {
				LoopEvent::Opened { operation_id, session } => {
					if let Some(waiter) = self.pending_dials.borrow_mut().remove(&operation_id) {
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, UnclaimedSession::Open);
						if waiter.send(Ok(session)).is_err() {
							self.release_unclaimed_session(session);
						}
					} else {
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, UnclaimedSession::Open);
						self.release_unclaimed_session(session);
					}
				}
				LoopEvent::OpenFailed { operation_id, failure } => {
					if let Some(waiter) = self.pending_dials.borrow_mut().remove(&operation_id) {
						// Failure has no associated native session. If the receiver went
						// away, cancellation is its terminal observation.
						drop(waiter.send(Err(driver_event_failure(failure, "dial"))));
					}
				}
				LoopEvent::ListenerReady { listener } => {
					let Some(waiter) = self.pending_listeners.borrow_mut().remove(&listener) else {
						if let Err(error) = self.driver.close_listener(listener) {
							self.fail_background(error);
							return;
						}
						continue;
					};
					self.listeners.borrow_mut().insert(listener);
					if waiter.send(Ok(())).is_err() {
						self.listeners.borrow_mut().remove(&listener);
						if let Err(error) = self.driver.close_listener(listener) {
							self.fail_background(error);
							return;
						}
					}
				}
				LoopEvent::ListenerFailed { listener, failure } => {
					let error = driver_event_failure(failure, "listener");
					if let Some(waiter) = self.pending_listeners.borrow_mut().remove(&listener) {
						// Native listener setup already terminated; a dropped receiver is
						// therefore caller cancellation, with no cleanup left to lose.
						drop(waiter.send(Err(error)));
					} else if self.listeners.borrow_mut().remove(&listener) {
						self.listener_failures.borrow_mut().insert(listener, error);
						self.accept_wake.notify_waiters();
					}
				}
				LoopEvent::Accepted { listener, session } => {
					if !self.listeners.borrow().contains(&listener) {
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, UnclaimedSession::Open);
						self.release_unclaimed_session(session);
						self.fail_background(Error::with_detail(
							sys::ERR_INTERNAL,
							format!("accepted session names unknown listener {listener}"),
						));
						return;
					}
					self.unclaimed_sessions
						.borrow_mut()
						.insert(session as usize, UnclaimedSession::Open);
					self.accepts.borrow_mut().push_back((listener, session));
					self.accept_wake.notify_waiters();
				}
				LoopEvent::SessionClosed { session, failure } => {
					// The pump's EOF choreography, one tier up: record local
					// teardown, then retire the shell so a later verb refuses
					// ERR_CLOSED. The native side already broke the far vows
					// and classified their FAIL completions.
					let shell = host
						.as_ref()
						.and_then(|host| host.sessions.borrow().get(&(session as usize)).cloned());
					if let Some(shell) = shell {
						let close_result = self
							.driver
							.session_lifecycle_state(session)
							.map(|(_, code)| code)
							.unwrap_or_else(|error| error.code());
						if let Some(failure) = failure.clone() {
							shell.record_wire_failure(driver_event_failure(failure, "session"));
						}
						shell.closing.set(true);
						shell.record_close_result(close_result);
						shell.close_transport();
					} else if let Some(state) = self.unclaimed_sessions.borrow_mut().get_mut(&(session as usize)) {
						*state =
							UnclaimedSession::Closed(failure.map(|failure| driver_event_failure(failure, "session")));
					} else {
						// A loop-internal session that no application outcome can
						// still claim is dead; retire its native handle now.
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, UnclaimedSession::Closed(None));
						self.release_unclaimed_session(session);
					}
				}
				LoopEvent::Completion(action) => {
					let Some(host) = host.as_ref() else { continue };
					match action {
						HostAction::Settle { ticket, value } => {
							host.settle_vow(ticket, Ok(value));
						}
						HostAction::Fail {
							ticket,
							result,
							message,
						} => {
							host.settle_vow(ticket, Err(Error::with_detail(result, message)));
						}
						// FLUSH/CLOSE/DIAL/NEED_GIFT_ID never surface: the
						// loop executes transport-shaped actions internally.
						_ => {}
					}
				}
			}
		}
		drain_pending_releases();
		// Dispatch runs only with events in hand, so it always advanced state
		// a close driver may be parked on (a released session, a settled vow,
		// a retired listener). The direct dispatch callers (listener close's
		// preserve-committed drain) reach waiters through this same signal.
		self.note_step_activity();
	}

	/// Begin a nonblocking dial and await its session handle. The handshake advances
	/// across steps (`driver.HostRuntime.startDial`), so loops on one
	/// thread can dial each other and a stalled partner costs its budget,
	/// never the loop.
	pub(crate) async fn dial_locator(
		self: &Rc<Self>,
		locator: &Locator,
		options: Option<&[u8]>,
	) -> Result<*mut ffi_host::PancakeHostSession> {
		self.guard_handle()?;
		self.ensure_started()?;
		let operation_id = self.driver.dial(locator, options)?;
		let (waiter, outcome) = oneshot::channel();
		self.pending_dials.borrow_mut().insert(operation_id, waiter);
		// The park task may have read "no deadline" before this operation was
		// admitted. Make it rebuild its native-authoritative progress clock.
		self.note_step_activity();
		self.schedule_step();
		match outcome.await {
			Ok(outcome) => outcome,
			Err(_) => Err(loop_closed_error()),
		}
	}

	/// Await the next accepted session handle (bind a listener first). Fails
	/// with the typed `ERR_CLOSED` once the loop closes, so a server
	/// iteration ends rather than parking forever.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) async fn accept(self: &Rc<Self>, listener: u64) -> Result<*mut ffi_host::PancakeHostSession> {
		loop {
			let notified = self.accept_wake.notified();
			tokio::pin!(notified);
			notified.as_mut().enable();
			let position = self
				.accepts
				.borrow()
				.iter()
				.position(|(accepted_by, _)| *accepted_by == listener);
			if let Some(position) = position {
				return Ok(self.accepts.borrow_mut().remove(position).unwrap().1);
			}
			if self.released.get() || !self.listeners.borrow().contains(&listener) {
				if let Some(error) = self.listener_failures.borrow().get(&listener) {
					return Err(error.clone());
				}
				return Err(loop_closed_error());
			}
			notified.await;
		}
	}

	/// Bind one listener on an added transport; accepted sessions arrive
	/// through [`LoopShared::accept`].
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) async fn listen(self: &Rc<Self>, transport: &str, designator: &str) -> Result<u64> {
		self.guard_handle()?;
		self.ensure_started()?;
		let listener = self.driver.listen(transport, designator)?;
		let (waiter, outcome) = oneshot::channel();
		self.pending_listeners.borrow_mut().insert(listener, waiter);
		let mut pending = PendingListenerSetup {
			lp: Rc::clone(self),
			listener,
			armed: true,
		};
		// Pending provider setup can install a finite listener deadline without
		// descriptor readiness. Re-arm the park task from the driver's clock.
		self.note_step_activity();
		self.schedule_step();
		let result = match outcome.await {
			Ok(result) => result,
			Err(_) => Err(loop_closed_error()),
		};
		pending.armed = false;
		result.map(|()| listener)
	}

	/// The listener's complete canonical OCapN locator.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) fn listener_locator(&self, listener: u64) -> Result<Locator> {
		self.guard_handle()?;
		self.driver.listener_locator(listener)
	}

	#[cfg(feature = "onion")]
	pub(crate) fn listener_restoration_state(&self, listener: u64) -> Result<Vec<u8>> {
		self.guard_handle()?;
		self.driver.listener_restoration_state(listener)
	}

	#[cfg(feature = "tcp")]
	pub(crate) fn advertise_listener(&self, listener: u64, locator_uri: &str) -> Result<()> {
		self.guard_handle()?;
		let locator = crate::uri::parse_locator(locator_uri)?;
		self.driver.advertise_listener(listener, &locator)
	}

	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) fn select_listener(&self, listener: u64) -> Result<()> {
		self.guard_handle()?;
		self.driver.select_listener(listener)
	}

	/// Stop one listener while keeping the loop and yielded sessions alive.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) fn close_listener(self: &Rc<Self>, listener: u64) -> Result<()> {
		self.guard_handle()?;
		self.close_native_listener(listener)?;
		let removed = self.listeners.borrow_mut().remove(&listener);
		if !removed {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("native driver closed unknown listener {listener}"),
			));
		}
		self.accept_wake.notify_waiters();
		Ok(())
	}

	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	fn close_native_listener(self: &Rc<Self>, listener: u64) -> Result<()> {
		self.driver.close_listener(listener)?;
		let events = self.driver.drain_events()?;
		if !events.is_empty() {
			self.dispatch(events);
		}
		Ok(())
	}

	/// A dropped setup future may race a committed READY event. Remove its
	/// waiter before draining native events, then retire either the still-pending
	/// or newly-active binding state without exposing a listener to the caller.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	fn cancel_listener_setup(self: &Rc<Self>, listener: u64) {
		self.pending_listeners.borrow_mut().remove(&listener);
		if self.released.get() {
			return;
		}
		if let Err(error) = self.close_native_listener(listener) {
			self.fail_background(error);
			return;
		}
		self.listeners.borrow_mut().remove(&listener);
		self.discard_accepts(listener);
		self.accept_wake.notify_waiters();
	}

	/// Release accepted sessions that a closing server never yielded. The
	/// native listener-close contract preserves committed events; the public
	/// server contract transfers only sessions returned by `accept`.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) fn discard_accepts(&self, listener: u64) {
		let queued = self.accepts.borrow().len();
		for _ in 0..queued {
			let Some((accepted_by, session)) = self.accepts.borrow_mut().pop_front() else {
				break;
			};
			if accepted_by == listener {
				self.release_unclaimed_session(session);
			} else {
				self.accepts.borrow_mut().push_back((accepted_by, session));
			}
		}
	}

	/// Transfer one event-delivered handle into a binding Session, preserving a
	/// terminal event that committed before the wrapper existed.
	fn claim_session(&self, session: *mut ffi_host::PancakeHostSession) -> UnclaimedSession {
		self.unclaimed_sessions
			.borrow_mut()
			.remove(&(session as usize))
			.unwrap_or(UnclaimedSession::Open)
	}

	/// Release a handle the binding never transferred to an application. The
	/// loop remains its owner on refusal, so tracking is removed only after the
	/// native release commits.
	fn release_unclaimed_session(&self, session: *mut ffi_host::PancakeHostSession) {
		if self.native_session_release(session).is_ok() {
			self.unclaimed_sessions.borrow_mut().remove(&(session as usize));
		}
	}

	pub(crate) fn claim_reference_exporter(
		&self,
		reference: &sys::PancakeReference,
	) -> Result<Option<*mut ffi_host::PancakeHostSession>> {
		self.driver.claim_reference_exporter(reference)
	}

	/// Release one loop-owned session through the loop's own verb, which also
	/// drops queued events naming it. A no-op once the loop is released: the
	/// loop's release freed its sessions itself.
	pub(crate) fn native_session_release(&self, session: *mut ffi_host::PancakeHostSession) -> Result<()> {
		if self.released.get() {
			return Ok(());
		}
		self.driver.session_release(session)
	}

	/// Begin or escalate one session close. The driver/core own the policy and
	/// barrier; the loop task supplies transport progress and event projection.
	pub(crate) fn request_session_close(
		self: &Rc<Self>,
		session: *mut ffi_host::PancakeHostSession,
		pending: PendingWork,
	) -> Result<()> {
		if self.released.get() {
			return Ok(());
		}
		self.guard_handle()?;
		self.driver.begin_session_close(session, pending)?;
		self.schedule_step();
		// A close request or escalation is close-relevant activity: it may
		// only arm a deadline, which no productive step reports, so a driver
		// parked with no finite deadline must re-read its wait.
		self.note_step_activity();
		Ok(())
	}

	/// Begin or escalate the native close barrier. The driver owns admission,
	/// pending-work policy, transport interruption, and terminal completion;
	/// this task only keeps stepping and projecting its events.
	pub(crate) fn request_close(self: &Rc<Self>, pending: PendingWork) -> Result<()> {
		if self.released.get() {
			return Ok(());
		}
		self.guard_handle()?;
		self.driver.begin_close(pending)?;
		// Same as the session arm above: an escalation of an already-running
		// barrier re-arms deadlines a parked driver must re-read.
		self.note_step_activity();
		if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
			host.native_close_committed();
		}
		if !self.close_task_started.get() {
			let loop_ = Rc::clone(self);
			if try_spawn_local_handle(async move { loop_.drive_close().await }).is_none() {
				return Err(Error::with_detail(
					sys::ERR_INTERNAL,
					"loop close requires a running LocalSet".into(),
				));
			}
			self.close_task_started.set(true);
		}
		Ok(())
	}

	async fn drive_close(self: Rc<Self>) {
		let close_code = loop {
			// Register the activity waiter before stepping, so a rival path's
			// step landing between this step and the park still wakes this
			// driver instead of being lost. This driver's own productive step
			// signals the same waiter, forcing one more check rather than
			// parking over unexamined progress.
			let notified = self.step_activity();
			tokio::pin!(notified);
			notified.as_mut().enable();
			if let Err(error) = self.step_now() {
				self.fail_background(error);
				return;
			}
			match self.driver.lifecycle_state() {
				Ok((true, code)) => break code,
				Ok((false, _)) => {
					// Park on loop activity or on the nearest pending-work
					// deadline. An expiry takes effect only inside a step, so
					// the timer wake is what applies it; with no finite
					// deadline pending, readiness-driven steps alone advance
					// the loop and the driver parks on activity alone.
					match self.driver.step_wait() {
						Ok(Some(wait)) => {
							tokio::select! {
								() = notified.as_mut() => {}
								() = tokio::time::sleep(wait) => {}
							}
						}
						Ok(None) => notified.await,
						Err(error) => {
							if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
								host.fail_close(error);
							}
							return;
						}
					}
				}
				Err(error) => {
					if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
						host.fail_close(error);
					}
					return;
				}
			}
		};

		if let Some(park) = self.park.borrow_mut().take() {
			park.abort();
		}
		debug_assert!(self.pending_dials.borrow().is_empty());
		debug_assert!(self.pending_listeners.borrow().is_empty());
		if let Err(error) = self.driver.release() {
			if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
				host.fail_close(error);
			}
			return;
		}
		self.released.set(true);
		if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
			host.finish_loop_teardown(close_code);
		}
		self.listeners.borrow_mut().clear();
		self.accepts.borrow_mut().clear();
		self.unclaimed_sessions.borrow_mut().clear();
		self.accept_wake.notify_waiters();
	}

	/// Implicit cleanup is cancel and cannot wait. Start the ordinary barrier
	/// when a LocalSet is live; otherwise the low-level release performs the same
	/// cancel-shaped ownership sweep.
	pub(crate) fn close(self: &Rc<Self>) {
		if self.request_close(PendingWork::Cancel).is_err() {
			if self.driver.release().is_ok() {
				self.released.set(true);
				if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
					host.finish_loop_teardown(sys::OK);
				}
			}
		}
	}
}

/// Wrap a loop-minted session handle as the public [`Session`], over the
/// adopted wrapper Host: every session verb, promise, and trampoline works on
/// it, with the native loop as the transport and the drain.
pub(crate) fn loop_session(lp: &Rc<LoopShared>, session: *mut ffi_host::PancakeHostSession) -> Result<Session> {
	let host = lp.wrapper_host()?;
	let shared = SessionShared::new_loop(session, host, Rc::clone(lp));
	shared.spawn_serve();
	if let UnclaimedSession::Closed(failure) = lp.claim_session(session) {
		if let Some(failure) = failure {
			shared.record_wire_failure(failure);
		}
		shared.closing.set(true);
		shared.close_transport();
	}
	Ok(Session::owning(shared))
}

#[cfg(test)]
mod tests {
	#[cfg(any(feature = "tcp", feature = "iroh"))]
	use super::*;
	#[cfg(feature = "tcp")]
	use std::sync::atomic::{AtomicBool, Ordering};
	#[cfg(feature = "tcp")]
	use std::sync::{mpsc, Arc};

	#[cfg(any(feature = "tcp", feature = "iroh"))]
	#[test]
	fn unknown_native_event_and_completion_kinds_are_returned_failures() {
		let mut event: PancakeDriverEvent = unsafe { core::mem::zeroed() };
		event.kind = u32::MAX;
		let error = decode_event(&event).err().expect("unknown event is rejected");
		assert_eq!(error.code(), sys::ERR_INTERNAL);

		event.kind = sys::DRIVER_EVENT_COMPLETION;
		event.action.kind = u32::MAX;
		let error = decode_event(&event).err().expect("unknown completion is rejected");
		assert_eq!(error.code(), sys::ERR_INTERNAL);
	}

	#[cfg(feature = "tcp")]
	fn seed(byte: u8) -> [u8; 64] {
		let mut material = [byte; 64];
		for half in material[32..].iter_mut() {
			*half = byte ^ 0xa5;
		}
		material
	}

	#[cfg(feature = "tcp")]
	fn wait_listener_ready(lp: &DriverLoop, listener: u64) {
		for _ in 0..1_000 {
			for event in lp.step(20).unwrap().unwrap_or_default() {
				match event {
					LoopEvent::ListenerReady { listener: ready } if ready == listener => return,
					LoopEvent::ListenerFailed {
						listener: failed,
						failure,
					} if failed == listener => panic!("listener failed: {}", failure.primary_name),
					_ => {}
				}
			}
		}
		panic!("listener setup timed out");
	}

	#[cfg(feature = "tcp")]
	#[test]
	fn failed_park_admission_does_not_publish_a_started_loop() {
		let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
		let refused = lp.ensure_started().unwrap_err();
		assert_eq!(refused.kind(), crate::ErrorKind::Internal);
		assert!(!lp.parked.get(), "a refused LocalSet spawn remains retryable");

		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			lp.ensure_started().unwrap();
			assert!(lp.parked.get());
			lp.close();
			while !lp.released.get() {
				tokio::task::yield_now().await;
			}
		});
	}

	/// A handshake deadline is a clock edge, not descriptor readiness. The
	/// async loop must therefore ask the native driver when its next progress
	/// step is due; otherwise a partner that accepts TCP and says nothing can
	/// leave this future parked forever.
	#[cfg(feature = "tcp")]
	#[tokio::test]
	async fn a_silent_loop_dial_reaches_its_native_handshake_deadline() {
		let local = tokio::task::LocalSet::new();
		local
			.run_until(async {
				let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
				let port = listener.local_addr().unwrap().port();

				let lp = LoopShared::open(50, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
				let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
				lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
				let locator_uri = crate::uri::format_peer_locator("tcp", &format!("127.0.0.1:{port}"), "").unwrap();
				let locator = crate::uri::parse_locator(&locator_uri).unwrap();

				let error = tokio::time::timeout(std::time::Duration::from_secs(1), lp.dial_locator(&locator, None))
					.await
					.expect("the native handshake deadline must wake the loop")
					.expect_err("a silent partner must not open a session");
				assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
				lp.close();
			})
			.await;
	}

	#[cfg(feature = "tcp")]
	#[test]
	fn refused_background_step_is_terminal_and_observable() {
		let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
		lp.schedule_step();
		let retained = lp.terminal_failure.borrow().clone().unwrap();
		assert_eq!(retained.code(), sys::ERR_INTERNAL);
		assert!(retained.to_string().contains("running LocalSet"), "{retained}");
		assert!(
			lp.released.get(),
			"terminal background failure releases the driver loop"
		);
		assert_eq!(lp.guard_handle().unwrap_err().kind(), crate::ErrorKind::Internal);
	}

	#[cfg(feature = "tcp")]
	#[test]
	fn dropped_listener_setup_retires_a_committed_ready_listener() {
		let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
		let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
		lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();

		let listener = lp.driver.listen("tcp", "127.0.0.1:0").unwrap();
		let (waiter, _outcome) = oneshot::channel();
		lp.pending_listeners.borrow_mut().insert(listener, waiter);
		let pending = PendingListenerSetup {
			lp: Rc::clone(&lp),
			listener,
			armed: true,
		};
		lp.dispatch(lp.driver.drain_events().unwrap());
		assert!(lp.listeners.borrow().contains(&listener));

		drop(pending);
		assert!(!lp.listeners.borrow().contains(&listener));
		assert!(!lp.pending_listeners.borrow().contains_key(&listener));
		assert!(lp.driver.listener_locator(listener).is_err());
		lp.close();
	}

	/// The loop tier from Rust (ADR-0112): two stepping loops over loopback
	/// TCP, the server driven wholly by its own thread, dial as an operation id, the
	/// session as an Opened event, and a vow's break as a Completion event —
	/// the byte-fed drain's own Fail shape, ticket-matched. The success arm
	/// rides the live iroh parity test below.
	#[cfg(feature = "tcp")]
	#[test]
	fn tcp_loopback_steps_dial_fetch_and_hangup() {
		let stop = Arc::new(AtomicBool::new(false));
		let (designator_tx, designator_rx) = mpsc::channel::<String>();
		let stop_thread = Arc::clone(&stop);
		let server = std::thread::spawn(move || {
			let lp = DriverLoop::open(
				&seed(0x61),
				DriverLoopOptions {
					wire_buffer_bytes: 1024,
					max_pending_opens: 8,
					..DriverLoopOptions::default()
				},
			)
			.unwrap();
			let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
			lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
			let listener = lp.listen("tcp", "127.0.0.1:0").unwrap();
			wait_listener_ready(&lp, listener);
			lp.select_listener(listener).unwrap();
			let locator = lp.listener_locator(listener).unwrap();
			designator_tx.send(locator.designator).unwrap();
			while !stop_thread.load(Ordering::Acquire) {
				for event in lp.step(20).unwrap().unwrap_or_default() {
					if let LoopEvent::Accepted { session, .. } = event {
						lp.session_serve(session).unwrap();
					}
				}
			}
		});
		let designator = designator_rx.recv().unwrap();

		let lp = DriverLoop::open(
			&seed(0x62),
			DriverLoopOptions {
				wire_buffer_bytes: 1024,
				..DriverLoopOptions::default()
			},
		)
		.unwrap();
		let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
		lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
		let locator_uri = crate::uri::format_peer_locator("tcp", &designator, "").unwrap();
		let locator = crate::uri::parse_locator(&locator_uri).unwrap();
		let operation_id = lp.dial(&locator, None).unwrap();
		let mut session: *mut ffi_host::PancakeHostSession = core::ptr::null_mut();
		'dial: for _ in 0..1000 {
			for event in lp.step(20).unwrap().unwrap_or_default() {
				match event {
					LoopEvent::Opened {
						operation_id: opened_id,
						session: s,
					} => {
						assert_eq!(opened_id, operation_id);
						session = s;
						break 'dial;
					}
					LoopEvent::OpenFailed { failure, .. } => panic!("dial failed: {}", failure.primary_name),
					_ => {}
				}
			}
		}
		assert!(!session.is_null(), "the dial never completed");
		lp.session_serve(session).unwrap();

		let mut vow = 0u64;
		let name = b"nobody-home";
		let rc = unsafe { ffi_host::pancake_host_session_fetch(session, name.as_ptr(), name.len(), &mut vow) };
		assert_eq!(rc, sys::OK);
		let mut broke = false;
		'fetch: for _ in 0..1000 {
			for event in lp.step(20).unwrap().unwrap_or_default() {
				if let LoopEvent::Completion(HostAction::Fail { ticket: t, .. }) = event {
					assert_eq!(t, vow);
					broke = true;
					break 'fetch;
				}
			}
		}
		assert!(broke, "the fetch's break never arrived as a loop event");
		lp.session_release(session).unwrap();
		stop.store(true, Ordering::Release);
		server.join().unwrap();
	}

	/// Loop-tier FINISH (ADR-0114), mirroring the byte-fed Host timeout
	/// scenario in `host.rs`: a dial still negotiating against a silent TCP
	/// partner is admitted pending work, so a finite grace expires and the
	/// loop close barrier reports its timeout. The expiry takes effect only
	/// inside a step, so this is the proof of the close driver's deadline
	/// timer: parked on loop activity alone it would never step again.
	#[cfg(feature = "tcp")]
	#[tokio::test]
	async fn a_finite_finish_close_times_out_over_a_negotiating_loop_dial() {
		let local = tokio::task::LocalSet::new();
		local
			.run_until(async {
				// Bound but never accepted from: the kernel backlog completes
				// the TCP connect, and the CapTP handshake never answers.
				let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
				let port = listener.local_addr().unwrap().port();

				let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
				let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
				lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
				let host = crate::host::Host::from_shared(lp.wrapper_host().unwrap());

				let locator_uri = crate::uri::format_peer_locator("tcp", &format!("127.0.0.1:{port}"), "").unwrap();
				let locator = crate::uri::parse_locator(&locator_uri).unwrap();
				let dial = {
					let lp = Rc::clone(&lp);
					tokio::task::spawn_local(async move { lp.dial_locator(&locator, None).await })
				};
				for _ in 0..1_000 {
					if !lp.pending_dials.borrow().is_empty() {
						break;
					}
					tokio::task::yield_now().await;
				}
				assert!(!lp.pending_dials.borrow().is_empty(), "the dial was never admitted");

				let error = host
					.close(crate::PendingWork::Finish {
						grace: Some(std::time::Duration::from_millis(20)),
					})
					.await
					.expect_err("a negotiating dial keeps the finite finish from settling in time");
				assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
				assert!(dial.await.unwrap().is_err(), "close failed the admitted dial");
			})
			.await;
	}

	/// The live parity proof (`zig build rust-iroh-driver-provider`): the
	/// binding's native-loop iroh listener serves while a second loop dials the
	/// same endpoint through the C multiplexed-transport table, and the fetch's
	/// settle arrives as a Completion event in the byte-fed Settle shape.
	#[test]
	#[ignore = "live iroh QUIC; run via `zig build rust-iroh-driver-provider`"]
	#[cfg(feature = "iroh")]
	fn iroh_provider_dials_live() {
		use crate::iroh::Reachability;
		use crate::iroh::{listen, Config, ListenOptions, Netlayer};
		use crate::{Argument, Session};
		use std::rc::Rc;

		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.unwrap();
		let local = tokio::task::LocalSet::new();
		runtime.block_on(local.run_until(async move {
			let server = Rc::new(
				listen(Config::new(Reachability::LocalDiscovery), ListenOptions::default())
					.await
					.unwrap(),
			);
			let node_id = server.node_id().to_string();
			// Host-wide, before any accept: a loop client's fetch can land the
			// instant the handshake opens, so a per-session publish inside the
			// accept task would race it.
			server
				.host()
				.publish_giftable("greeter", || Box::new(|_verb, _args| Ok(Argument::Symbol("hi".into()))))
				.unwrap();
			let accept_server = Rc::clone(&server);
			let accept_task = tokio::task::spawn_local(async move {
				let mut served: Vec<Session> = Vec::new();
				while let Ok(session) = accept_server.accept().await {
					served.push(session);
				}
				served
			});

			// The client half lives wholly on its own OS thread: its own
			// runtime for the netlayer constructor, then plain stepping —
			// so a client step parked on its timeout never starves this
			// serving thread.
			let (done_tx, done_rx) = mpsc::channel::<std::result::Result<(), String>>();
			std::thread::spawn(move || {
				let outcome = (|| -> std::result::Result<(), String> {
					let client_rt = tokio::runtime::Builder::new_current_thread()
						.enable_all()
						.build()
						.map_err(|e| e.to_string())?;
					let netlayer = client_rt
						.block_on(Netlayer::from_seed(
							Config::new(Reachability::LocalDiscovery),
							[0x63u8; 32],
						))
						.map_err(|e| e.to_string())?;
					let provider = netlayer.transport_provider().map_err(|e| e.to_string())?;
					let lp = DriverLoop::open(
						&seed(0x63),
						DriverLoopOptions {
							handshake_ms: 20_000,
							settle_ms: 20_000,
							..DriverLoopOptions::default()
						},
					)
					.map_err(|e| e.to_string())?;
					lp.add_provider(provider).map_err(|e| e.to_string())?;
					let locator_uri =
						crate::uri::format_peer_locator("iroh", &node_id, "").map_err(|e| e.to_string())?;
					let locator = crate::uri::parse_locator(&locator_uri).map_err(|e| e.to_string())?;
					let operation_id = lp.dial(&locator, None).map_err(|e| e.to_string())?;
					let mut session: *mut ffi_host::PancakeHostSession = core::ptr::null_mut();
					'dial: for _ in 0..2000 {
						for event in lp.step(20).map_err(|e| e.to_string())?.unwrap_or_default() {
							match event {
								LoopEvent::Opened {
									operation_id: opened_id,
									session: s,
								} => {
									if opened_id != operation_id {
										return Err("operation id mismatch".into());
									}
									session = s;
									break 'dial;
								}
								LoopEvent::OpenFailed { failure, .. } => {
									return Err(format!("dial failed: {}", failure.primary_name));
								}
								_ => {}
							}
						}
					}
					if session.is_null() {
						return Err("the dial never completed".into());
					}
					let mut vow = 0u64;
					let name = b"greeter";
					let rc =
						unsafe { ffi_host::pancake_host_session_fetch(session, name.as_ptr(), name.len(), &mut vow) };
					if rc != sys::OK {
						return Err(format!("fetch refused: {rc}"));
					}
					let mut settled = false;
					'fetch: for _ in 0..2000 {
						for event in lp.step(20).map_err(|e| e.to_string())?.unwrap_or_default() {
							match event {
								LoopEvent::Completion(HostAction::Settle { ticket: t, .. }) => {
									if t != vow {
										return Err("settle ticket mismatch".into());
									}
									settled = true;
									break 'fetch;
								}
								LoopEvent::Completion(HostAction::Fail { message, .. }) => {
									return Err(format!("fetch broke: {message}"));
								}
								_ => {}
							}
						}
					}
					if !settled {
						return Err("the settle never arrived as a loop event".into());
					}
					lp.session_release(session).map_err(|e| e.to_string())?;
					Ok(())
				})();
				let _ = done_tx.send(outcome);
			});

			let outcome = tokio::task::spawn_blocking(move || done_rx.recv())
				.await
				.unwrap()
				.unwrap();
			outcome.unwrap();
			server.close().unwrap();
			let _ = accept_task.await;
		}));
	}
}
