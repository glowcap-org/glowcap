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

use core::ffi::c_int;
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
use crate::sys::driver::{
	PancakeDriverEvent, PancakeDriverLoop, PancakeDriverOptions, PancakeTransportProvider,
};
use crate::sys::{self, driver as ffi, host as ffi_host};
use crate::trampoline::DeliverGuard;
use crate::uri::OwnedLocator;
use crate::{Error, Locator, Result};

/// One archive-owned provider package. Registration acquires the package lease;
/// the driver releases it after every copied callback and transport handle.
pub struct TransportProvider<'owner> {
	pub(crate) package: PancakeTransportProvider,
	pub(crate) _owner: PhantomData<&'owner ()>,
}

/// One drained loop event, in owned form (the C views die at the next pop).
pub enum LoopEvent {
	/// The admitted dial named by the ticket opened; the session handle takes
	/// every `pancake_host_*` verb.
	Opened {
		ticket: u64,
		session: *mut ffi_host::PancakeHostSession,
	},
	OpenFailed {
		ticket: u64,
		message: String,
	},
	Accepted {
		listener: u64,
		session: *mut ffi_host::PancakeHostSession,
	},
	/// The wire closed inside a step; the handle stays valid until
	/// [`DriverLoop::session_release`], its vows already broken.
	SessionClosed {
		session: *mut ffi_host::PancakeHostSession,
	},
	/// A vow settled with no in-process listener, in the byte-fed queue's own
	/// decoded shape (`Settle` or `Fail`).
	Completion(HostAction),
}

/// One stepping native loop over one multi-session host.
pub struct DriverLoop {
	raw: *mut PancakeDriverLoop,
	host: *mut ffi_host::PancakeHost,
	released: Cell<bool>,
}

/// Native loop construction policy. `wire_buffer_bytes` is retained per
/// stream direction, or once for multiplexed read staging, for each live session.
#[derive(Clone, Copy, Debug)]
pub struct DriverLoopOptions {
	pub wire_buffer_bytes: usize,
	pub max_pending_opens: usize,
	pub handshake_ms: u32,
	pub settle_ms: u32,
}

impl Default for DriverLoopOptions {
	fn default() -> Self {
		Self {
			wire_buffer_bytes: sys::DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
			max_pending_opens: sys::DRIVER_DEFAULT_MAX_PENDING_OPENS,
			handshake_ms: sys::DRIVER_DEFAULT_HANDSHAKE_MS,
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
	/// `options` owns the retained wire-buffer size and two positive wait bounds.
	pub fn open(seed: &[u8; 64], options: DriverLoopOptions) -> Result<Self> {
		let mut host: *mut ffi_host::PancakeHost = core::ptr::null_mut();
		crate::host::check_host(unsafe {
			ffi_host::pancake_host_new(
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
			Ok(loop_) => Ok(loop_),
			Err(err) => {
				unsafe { ffi_host::pancake_host_release(host) };
				Err(err)
			}
		}
	}

	/// Transfer an existing quiescent Host to a native loop. The C transaction
	/// leaves Host ownership unchanged on failure and makes this loop the sole
	/// transport/action-drain/release owner on success.
	pub(crate) fn take_host(
		host: *mut ffi_host::PancakeHost,
		options: DriverLoopOptions,
	) -> Result<Self> {
		let mut raw: *mut PancakeDriverLoop = core::ptr::null_mut();
		let options = options.to_c();
		check(unsafe { ffi::pancake_driver_take_host(host, &options, &mut raw) })?;
		let loop_ = Self {
			raw,
			host,
			released: Cell::new(false),
		};
		Ok(loop_)
	}

	/// The wrapped `PancakeHost` handle for application verbs. Never release
	/// it separately; dropping the loop releases both.
	pub fn host(&self) -> *mut ffi_host::PancakeHost {
		self.host
	}

	/// Install one provider package. Native registration retains its callback
	/// context before publication and releases it during loop teardown.
	pub fn add_provider(&self, provider: TransportProvider<'_>) -> Result<()> {
		check(unsafe { ffi::pancake_driver_add_provider(self.raw, &provider.package) })?;
		Ok(())
	}

	/// Report whether the native provider registry owns `transport`.
	pub fn has_transport(&self, transport: &str) -> Result<bool> {
		let mut present = 0u8;
		check(unsafe {
			ffi::pancake_driver_has_transport(
				self.raw,
				transport.as_ptr(),
				transport.len(),
				&mut present,
			)
		})?;
		Ok(present != 0)
	}

	/// Begin a nonblocking dial. A refusal before admission returns directly;
	/// after admission the outcome arrives as an `Opened`/`OpenFailed` event
	/// carrying the returned ticket. Connect completion and the handshake
	/// advance through later `step` calls.
	pub fn dial(&self, locator: &Locator) -> Result<u64> {
		let owned = OwnedLocator::new(locator)?;
		let mut ticket = 0u64;
		check(unsafe { ffi::pancake_driver_dial(self.raw, owned.borrow_view()?, &mut ticket) })?;
		Ok(ticket)
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

	/// Replace this listener's advertised locator through its native owner.
	pub fn advertise_listener(&self, listener: u64, locator: &Locator) -> Result<()> {
		let owned = OwnedLocator::new(locator)?;
		check(unsafe {
			ffi::pancake_driver_listener_advertise(self.raw, listener, owned.borrow_view()?)
		})
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
			out.push(decode_event(&event));
		}
	}

	/// Release one loop-owned session (never `pancake_host_session_release`
	/// on these). Queued events naming it are dropped by the loop.
	pub fn session_release(&self, session: *mut ffi_host::PancakeHostSession) -> Result<()> {
		check(unsafe { ffi::pancake_driver_session_release(self.raw, session) })
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

	fn release(&self) {
		if !self.released.replace(true) {
			unsafe {
				let _ = ffi::pancake_driver_release(self.raw);
			}
		}
	}
}

fn decode_event(event: &PancakeDriverEvent) -> LoopEvent {
	match event.kind {
		sys::DRIVER_EVENT_OPENED => LoopEvent::Opened {
			ticket: event.ticket,
			session: event.session,
		},
		sys::DRIVER_EVENT_OPEN_FAILED => LoopEvent::OpenFailed {
			ticket: event.ticket,
			message: message_of(event.message, event.message_len),
		},
		sys::DRIVER_EVENT_ACCEPTED => LoopEvent::Accepted {
			listener: event.ticket,
			session: event.session,
		},
		sys::DRIVER_EVENT_SESSION_CLOSED => LoopEvent::SessionClosed {
			session: event.session,
		},
		_ => LoopEvent::Completion(host_action_gen::decode(&event.action)),
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
		self.release();
	}
}

/// Classify an OPEN_FAILED event. The loop reports an admitted dial's failure by
/// error name; a handshake or settle budget overrun becomes the typed timeout
/// the public dial contract promises, everything else is I/O.
fn dial_failure(message: &str) -> Error {
	if message == "HandshakeTimedOut" || message == "WaitTimedOut" {
		return Error::with_detail(
			sys::ERR_TIMEOUT,
			"the partner did not finish the OCapN handshake within the loop's handshake budget"
				.to_string(),
		);
	}
	Error::with_detail(sys::ERR_IO, format!("dial failed: {message}"))
}

fn loop_closed_error() -> Error {
	Error::with_detail(sys::ERR_CLOSED, "the loop is closed".to_string())
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
	/// The identity half of the loop host's 64-byte seed, retained so the
	/// adopted wrapper Host answers `designator()` like a byte-fed one.
	seed: [u8; 32],
	released: Cell<bool>,
	/// Re-entrancy latch: `pancake_driver_step` must never nest (a behavior
	/// fired inside a step kicks through deferred tasks, never a direct step).
	stepping: Cell<bool>,
	parked: Cell<bool>,
	park: RefCell<Option<tokio::task::AbortHandle>>,
	pending_dials:
		RefCell<HashMap<u64, oneshot::Sender<Result<*mut ffi_host::PancakeHostSession>>>>,
	accepts: RefCell<VecDeque<(u64, *mut ffi_host::PancakeHostSession)>>,
	/// Event-delivered handles not yet wrapped by the binding. The bool records
	/// a SESSION_CLOSED event that followed OPENED/ACCEPTED in the same drain;
	/// the handle stays valid until adoption or explicit release.
	unclaimed_sessions: RefCell<HashMap<usize, bool>>,
	listeners: RefCell<HashSet<u64>>,
	closed_listeners: RefCell<HashSet<u64>>,
	accept_wake: Notify,
	wrapper: RefCell<Option<Weak<HostShared>>>,
}

impl LoopShared {
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
		getrandom::fill(&mut seed).expect("the OS RNG provides a Host identity seed");
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
		let mut seed32 = [0u8; 32];
		seed32.copy_from_slice(&seed[..32]);
		Ok(Rc::new(LoopShared {
			driver,
			seed: seed32,
			released: Cell::new(false),
			stepping: Cell::new(false),
			parked: Cell::new(false),
			park: RefCell::new(None),
			pending_dials: RefCell::new(HashMap::new()),
			accepts: RefCell::new(VecDeque::new()),
			unclaimed_sessions: RefCell::new(HashMap::new()),
			listeners: RefCell::new(HashSet::new()),
			closed_listeners: RefCell::new(HashSet::new()),
			accept_wake: Notify::new(),
			wrapper: RefCell::new(None),
		}))
	}

	/// Promote an existing wrapper Host to the native driver before its first
	/// network operation. The loop points back weakly; the Host owns the loop,
	/// so dropping or closing the Host remains the terminal lifetime boundary.
	pub(crate) fn take_host(
		host: &Rc<HostShared>,
		handshake_ms: u32,
		settle_ms: u32,
	) -> Result<Rc<LoopShared>> {
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
			seed: host.durable_seed(),
			released: Cell::new(false),
			stepping: Cell::new(false),
			parked: Cell::new(false),
			park: RefCell::new(None),
			pending_dials: RefCell::new(HashMap::new()),
			accepts: RefCell::new(VecDeque::new()),
			unclaimed_sessions: RefCell::new(HashMap::new()),
			listeners: RefCell::new(HashSet::new()),
			closed_listeners: RefCell::new(HashSet::new()),
			accept_wake: Notify::new(),
			wrapper: RefCell::new(Some(Rc::downgrade(host))),
		}))
	}

	fn guard_open(&self) -> Result<()> {
		if self.released.get() {
			Err(loop_closed_error())
		} else {
			Ok(())
		}
	}

	/// Register a provider through the native driver's occupancy authority.
	pub(crate) fn add_provider(&self, provider: TransportProvider<'_>) -> Result<()> {
		self.guard_open()?;
		self.driver.add_provider(provider)
	}

	pub(crate) fn has_transport(&self, transport: &str) -> Result<bool> {
		self.guard_open()?;
		self.driver.has_transport(transport)
	}

	/// The public wrapper Host adopted over this loop's native host: every
	/// application verb, publish trampoline, and vow settle works on it, while
	/// the loop stays the one action drain and the one release authority.
	/// Built on first call; call it on the driving thread.
	pub(crate) fn wrapper_host(self: &Rc<Self>) -> Result<Rc<HostShared>> {
		self.guard_open()?;
		if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
			return Ok(host);
		}
		let host = HostShared::adopt_loop(self.driver.host(), self.seed, Rc::clone(self))?;
		*self.wrapper.borrow_mut() = Some(Rc::downgrade(&host));
		Ok(host)
	}

	/// Arm the readiness descriptor and park the running `LocalSet` on it:
	/// from here the loop steps whenever native work is ready. The descriptor
	/// is duplicated so the park task's registration can never race the
	/// loop's release into a reused fd.
	pub(crate) fn start(self: &Rc<Self>) -> Result<()> {
		self.guard_open()?;
		if self.parked.replace(true) {
			return Ok(());
		}
		let fd = self.driver.readiness_fd()?;
		let fd = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) }
			.try_clone_to_owned()
			.map_err(io_err)?;
		let lp = Rc::clone(self);
		let task = try_spawn_local_handle(async move {
			let Ok(afd) = AsyncFd::with_interest(fd, Interest::READABLE) else {
				return;
			};
			loop {
				let Ok(mut guard) = afd.readable().await else {
					return;
				};
				if lp.released.get() {
					return;
				}
				lp.step_now();
				guard.clear_ready();
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
		})?;
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
		let _ = try_spawn_local(async move {
			lp.step_now();
		});
	}

	/// Drain zero-timeout steps through quiescence and dispatch their events,
	/// on the loop thread. Reaching WOULD_BLOCK is what permits an
	/// edge-triggered readiness guard to clear without losing a sibling source.
	pub(crate) fn step_now(self: &Rc<Self>) {
		if self.released.get() || self.stepping.get() || crate::trampoline::inside_turn() {
			return;
		}
		loop {
			let outcome = {
				self.stepping.set(true);
				let host = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
				// The head of the byte-fed kick, one tier up: run parked releases
				// and reclaimed-import releases before the step, so a dropped
				// `Ref`'s op:gc-exports flushes in the very step this kick runs.
				drain_pending_releases();
				if let Some(host) = &host {
					crate::gc::drain(host);
				}
				// The step is the deliver: behaviors fire inside it, and the
				// bracket latches their turns to this loop's wrapper Host.
				let _bracket = host.as_ref().map(DeliverGuard::enter_host);
				let result = self.driver.step(0);
				self.stepping.set(false);
				result
			};
			drain_pending_releases();
			match outcome {
				Ok(Some(events)) => {
					if !events.is_empty() {
						self.dispatch(events);
					}
				}
				Ok(None) | Err(_) => break,
			}
		}
	}

	fn dispatch(self: &Rc<Self>, events: Vec<LoopEvent>) {
		let host = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
		for event in events {
			match event {
				LoopEvent::Opened { ticket, session } => {
					if let Some(waiter) = self.pending_dials.borrow_mut().remove(&ticket) {
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, false);
						if waiter.send(Ok(session)).is_err() {
							self.unclaimed_sessions
								.borrow_mut()
								.remove(&(session as usize));
							self.native_session_release(session);
						}
					} else {
						self.native_session_release(session);
					}
				}
				LoopEvent::OpenFailed { ticket, message } => {
					if let Some(waiter) = self.pending_dials.borrow_mut().remove(&ticket) {
						let _ = waiter.send(Err(dial_failure(&message)));
					}
				}
				LoopEvent::Accepted { listener, session } => {
					if !self.listeners.borrow().contains(&listener) {
						self.native_session_release(session);
						panic!("accepted session names unknown listener {listener}");
					}
					self.unclaimed_sessions
						.borrow_mut()
						.insert(session as usize, false);
					self.accepts.borrow_mut().push_back((listener, session));
					self.accept_wake.notify_waiters();
				}
				LoopEvent::SessionClosed { session } => {
					// The pump's EOF choreography, one tier up: mark teardown
					// first (ordered before this wire's FAIL completions, so
					// they classify as the typed closed error), then retire
					// the shell so a later verb refuses ERR_CLOSED. The
					// native side already broke the far vows in its close.
					let shell = host
						.as_ref()
						.and_then(|host| host.sessions.borrow().get(&(session as usize)).cloned());
					if let Some(shell) = shell {
						shell.closing.set(true);
						shell.close_transport();
					} else if let Some(closed) = self
						.unclaimed_sessions
						.borrow_mut()
						.get_mut(&(session as usize))
					{
						*closed = true;
					} else {
						// A loop-internal session that no application outcome can
						// still claim is dead; retire its native handle now.
						self.native_session_release(session);
					}
				}
				LoopEvent::Completion(action) => {
					let Some(host) = host.as_ref() else { continue };
					match action {
						HostAction::Settle { ticket, value } => {
							host.settle_vow(ticket, Ok(value));
						}
						HostAction::Fail { ticket, message } => {
							// The byte-fed drain's own FAIL classification: a
							// teardown break is the typed closed error —
							// carrying the binding's one disconnect wording,
							// the same words the byte-fed pump breaks with —
							// everything else a partner break.
							let refusal = if host.vow_session_closing(ticket) {
								Error::with_detail(sys::ERR_CLOSED, "connection closed".to_string())
							} else {
								Error::broken(message)
							};
							host.settle_vow(ticket, Err(refusal));
						}
						// FLUSH/CLOSE/DIAL/NEED_GIFT_ID never surface: the
						// loop executes transport-shaped actions internally.
						_ => {}
					}
				}
			}
		}
		drain_pending_releases();
	}

	/// Begin a nonblocking dial and await its session handle. The handshake advances
	/// across steps (`driver.HostRuntime.startConnectLocator`), so loops on one
	/// thread can dial each other and a stalled partner costs its budget,
	/// never the loop.
	pub(crate) async fn dial_locator(
		self: &Rc<Self>,
		locator: &Locator,
	) -> Result<*mut ffi_host::PancakeHostSession> {
		self.guard_open()?;
		let ticket = self.driver.dial(locator)?;
		let (waiter, outcome) = oneshot::channel();
		self.pending_dials.borrow_mut().insert(ticket, waiter);
		self.schedule_step();
		match outcome.await {
			Ok(outcome) => outcome,
			Err(_) => Err(loop_closed_error()),
		}
	}

	/// Await the next accepted session handle (bind a listener first). Fails
	/// with the typed `ERR_CLOSED` once the loop closes, so a server
	/// iteration ends rather than parking forever.
	pub(crate) async fn accept(
		self: &Rc<Self>,
		listener: u64,
	) -> Result<*mut ffi_host::PancakeHostSession> {
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
			if self.released.get() || self.closed_listeners.borrow().contains(&listener) {
				return Err(loop_closed_error());
			}
			notified.await;
		}
	}

	/// Bind one listener on an added transport; accepted sessions arrive
	/// through [`LoopShared::accept`].
	pub(crate) fn listen(&self, transport: &str, designator: &str) -> Result<u64> {
		self.guard_open()?;
		let listener = self.driver.listen(transport, designator)?;
		self.listeners.borrow_mut().insert(listener);
		Ok(listener)
	}

	/// The listener's complete canonical OCapN locator.
	pub(crate) fn listener_locator(&self, listener: u64) -> Result<Locator> {
		self.guard_open()?;
		self.driver.listener_locator(listener)
	}

	pub(crate) fn advertise_listener(&self, listener: u64, locator_uri: &str) -> Result<()> {
		self.guard_open()?;
		let locator = crate::uri::parse_locator(locator_uri)?;
		self.driver.advertise_listener(listener, &locator)
	}

	pub(crate) fn select_listener(&self, listener: u64) -> Result<()> {
		self.guard_open()?;
		self.driver.select_listener(listener)
	}

	/// Stop one listener while keeping the loop and yielded sessions alive.
	pub(crate) fn close_listener(self: &Rc<Self>, listener: u64) -> Result<()> {
		self.guard_open()?;
		self.driver.close_listener(listener)?;
		let events = self.driver.drain_events()?;
		if !events.is_empty() {
			self.dispatch(events);
		}
		let removed = self.listeners.borrow_mut().remove(&listener);
		assert!(removed, "closed unknown listener {listener}");
		self.closed_listeners.borrow_mut().insert(listener);
		self.accept_wake.notify_waiters();
		Ok(())
	}

	/// Release accepted sessions that a closing server never yielded. The
	/// native listener-close contract preserves committed events; the public
	/// server contract transfers only sessions returned by `accept`.
	pub(crate) fn discard_accepts(&self, listener: u64) {
		let queued = self.accepts.borrow().len();
		for _ in 0..queued {
			let Some((accepted_by, session)) = self.accepts.borrow_mut().pop_front() else {
				break;
			};
			if accepted_by == listener {
				self.unclaimed_sessions
					.borrow_mut()
					.remove(&(session as usize));
				self.native_session_release(session);
			} else {
				self.accepts.borrow_mut().push_back((accepted_by, session));
			}
		}
	}

	/// Transfer one event-delivered handle into a binding Session. Returns
	/// whether SESSION_CLOSED committed before the wrapper existed.
	fn claim_session(&self, session: *mut ffi_host::PancakeHostSession) -> bool {
		self.unclaimed_sessions
			.borrow_mut()
			.remove(&(session as usize))
			.unwrap_or(false)
	}

	/// Release one loop-owned session through the loop's own verb, which also
	/// drops queued events naming it. A no-op once the loop is released: the
	/// loop's release freed its sessions itself.
	pub(crate) fn native_session_release(&self, session: *mut ffi_host::PancakeHostSession) {
		if self.released.get() {
			return;
		}
		let _ = self.driver.session_release(session);
	}

	/// Stop stepping and close everything this loop owns: the listener, its
	/// sessions, the adopted wrapper Host's shells and vows. The native
	/// release (`pancake_driver_release`, which frees loop, sessions, and
	/// host together) is the terminal close barrier; later drops are inert.
	pub(crate) fn close(self: &Rc<Self>) {
		if self.released.replace(true) {
			return;
		}
		for (_, waiter) in self.pending_dials.borrow_mut().drain() {
			let _ = waiter.send(Err(loop_closed_error()));
		}
		self.accept_wake.notify_waiters();
		if let Some(park) = self.park.borrow_mut().take() {
			park.abort();
		}
		let wrapper = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
		if let Some(host) = wrapper {
			host.loop_teardown();
		}
		self.driver.release();
	}
}

/// Wrap a loop-minted session handle as the public [`Session`], over the
/// adopted wrapper Host: every session verb, promise, and trampoline works on
/// it, with the native loop as the transport and the drain.
pub(crate) fn loop_session(
	lp: &Rc<LoopShared>,
	session: *mut ffi_host::PancakeHostSession,
	owns_host: bool,
) -> Result<Session> {
	let host = lp.wrapper_host()?;
	let shared = SessionShared::new_loop(session, host, Rc::clone(lp));
	shared.spawn_serve();
	if lp.claim_session(session) {
		shared.closing.set(true);
		shared.close_transport();
	}
	let mut session = Session::owning(shared);
	session.set_owns_host(owns_host);
	Ok(session)
}

#[cfg(test)]
mod tests {
	use std::sync::atomic::{AtomicBool, Ordering};
	use std::sync::{mpsc, Arc};

	use super::*;

	fn seed(byte: u8) -> [u8; 64] {
		let mut material = [byte; 64];
		for half in material[32..].iter_mut() {
			*half = byte ^ 0xa5;
		}
		material
	}

	/// The loop tier from Rust (ADR-0112): two stepping loops over loopback
	/// TCP, the server driven wholly by its own thread, dial as a ticket, the
	/// session as an Opened event, and a vow's break as a Completion event —
	/// the byte-fed drain's own Fail shape, ticket-matched. The success arm
	/// rides the live iroh parity test below.
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
			let netlayer = crate::tcp::Netlayer::new().unwrap();
			lp.add_provider(netlayer.transport_provider().unwrap())
				.unwrap();
			let listener = lp.listen("tcp", "127.0.0.1:0").unwrap();
			lp.select_listener(listener).unwrap();
			let locator = lp.listener_locator(listener).unwrap();
			designator_tx.send(locator.designator).unwrap();
			while !stop_thread.load(Ordering::Acquire) {
				let _ = lp.step(20).unwrap();
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
		let netlayer = crate::tcp::Netlayer::new().unwrap();
		lp.add_provider(netlayer.transport_provider().unwrap())
			.unwrap();
		let locator_uri = crate::uri::format_peer_locator("tcp", &designator, "").unwrap();
		let locator = crate::uri::parse_locator(&locator_uri).unwrap();
		let ticket = lp.dial(&locator).unwrap();
		let mut session: *mut ffi_host::PancakeHostSession = core::ptr::null_mut();
		'dial: for _ in 0..1000 {
			for event in lp.step(20).unwrap().unwrap_or_default() {
				match event {
					LoopEvent::Opened {
						ticket: t,
						session: s,
					} => {
						assert_eq!(t, ticket);
						session = s;
						break 'dial;
					}
					LoopEvent::OpenFailed { message, .. } => panic!("dial failed: {message}"),
					_ => {}
				}
			}
		}
		assert!(!session.is_null(), "the dial never completed");

		let mut vow = 0u64;
		let name = b"nobody-home";
		let rc = unsafe {
			ffi_host::pancake_host_session_fetch(session, name.as_ptr(), name.len(), &mut vow)
		};
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

	/// The live parity proof (`zig build rust-iroh-driver-provider`): the
	/// binding's native-loop iroh listener serves while a second loop dials the
	/// same endpoint through the C multiplexed-transport table, and the fetch's
	/// settle arrives as a Completion event in the byte-fed Settle shape.
	#[test]
	#[ignore = "live iroh QUIC; run via `zig build rust-iroh-driver-provider`"]
	#[cfg(feature = "iroh")]
	fn iroh_provider_dials_live() {
		use crate::iroh::{listen_iroh, IrohConfig, IrohNetlayer};
		use crate::Reachability;
		use crate::{Argument, Session};
		use std::rc::Rc;

		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.unwrap();
		let local = tokio::task::LocalSet::new();
		runtime.block_on(local.run_until(async move {
			let server = Rc::new(
				listen_iroh(IrohConfig::new(Reachability::LocalDiscovery))
					.await
					.unwrap(),
			);
			let node_id = server.node_id().to_string();
			// Host-wide, before any accept: a loop client's fetch can land the
			// instant the handshake opens, so a per-session publish inside the
			// accept task would race it.
			server.host().publish_giftable("greeter", || {
				Box::new(|_verb, _args| Ok(Argument::Symbol("hi".into())))
			});
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
						.block_on(IrohNetlayer::from_seed(
							IrohConfig::new(Reachability::LocalDiscovery),
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
					let locator_uri = crate::uri::format_peer_locator("iroh", &node_id, "")
						.map_err(|e| e.to_string())?;
					let locator =
						crate::uri::parse_locator(&locator_uri).map_err(|e| e.to_string())?;
					let ticket = lp.dial(&locator).map_err(|e| e.to_string())?;
					let mut session: *mut ffi_host::PancakeHostSession = core::ptr::null_mut();
					'dial: for _ in 0..2000 {
						for event in lp.step(20).map_err(|e| e.to_string())?.unwrap_or_default() {
							match event {
								LoopEvent::Opened {
									ticket: t,
									session: s,
								} => {
									if t != ticket {
										return Err("ticket mismatch".into());
									}
									session = s;
									break 'dial;
								}
								LoopEvent::OpenFailed { message, .. } => {
									return Err(format!("dial failed: {message}"));
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
					let rc = unsafe {
						ffi_host::pancake_host_session_fetch(
							session,
							name.as_ptr(),
							name.len(),
							&mut vow,
						)
					};
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
