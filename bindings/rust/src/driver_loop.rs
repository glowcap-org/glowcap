//! The native loop tier (ADR-0112): the public `connect`/`listen` route for
//! the shapes the driver archive carries, over a thin package around one
//! `PancakeDriverLoop`.
//!
//! The driver archive composes transport providers and owns sockets and
//! pumping, so this package's whole job is choreography. [`DriverLoop`] is the
//! step-shaped floor (create
//! the loop, register separately linked transports, dial and listen, step,
//! drain events in owned
//! form); [`LoopShared`] is the Tokio state aggregate, while `progress.rs`
//! dispatches events, `sessions.rs` transfers session handles, and
//! `provider.rs` owns transport installation. The loop parks the `LocalSet`
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

use core::future::Future;
use core::pin::Pin;
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet, VecDeque};
use std::rc::{Rc, Weak};

use tokio::io::unix::AsyncFd;
use tokio::io::Interest;
use tokio::sync::{oneshot, Notify};

use crate::driver_event::failure_error as driver_event_failure;
pub use crate::driver_event::{DriverEventFailure, LoopEvent};
use crate::host::{try_spawn_local, try_spawn_local_handle, HostShared};
use crate::host_action_gen::HostAction;
use crate::session::Session;
use crate::session_shared::{io_err, SessionShared};
use crate::sys::{self, host as ffi_host};
use crate::trampoline::DeliverGuard;
use crate::{ContextInner, Error, Locator, PendingWork, Result};

mod close;
mod native;
mod progress;
mod provider;
mod sessions;

pub use native::{DriverLoop, DriverLoopOptions, ProviderPackage};
pub use provider::Provider;
pub(crate) use sessions::loop_session;

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

	/// Transfer a refused terminal release together with the Host shell whose
	/// native-facing state can retire only after a later consuming attempt.
	fn defer_failed_release(self: &Rc<Self>, host: Rc<HostShared>, mut failure: Error) {
		let retry = try_spawn_local_handle(async {
			crate::finalizer::drain();
		});
		if retry.is_none() {
			failure = failure.with_secondary(Error::with_detail(
				sys::ERR_INTERNAL,
				"driver release retry requires a later safe boundary".to_string(),
			));
		}
		let (raw, context) = self.driver.transfer_refused();
		self.released.set(true);
		crate::finalizer::park_failed_driver(raw, context, Rc::clone(&host), failure.clone());
		host.fail_close(failure);
		// A spawned task cannot run inside the callback that queued it. If no
		// LocalSet exists, the process queue remains the durable owner until
		// another safe boundary.
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
			let release = self.driver.release();
			match release.result {
				Ok(()) if release.consumed => {
					self.released.set(true);
					host.finish_failed_loop_teardown(error);
				}
				Err(release_error) if release.consumed => {
					self.released.set(true);
					host.finish_failed_loop_teardown(error.with_secondary(release_error));
				}
				Err(release_error) => self.defer_failed_release(host, error.with_secondary(release_error)),
				Ok(()) => self.defer_failed_release(
					host,
					error.with_secondary(Error::with_detail(
						sys::ERR_INTERNAL,
						"driver release refused without a failure".to_string(),
					)),
				),
			}
		} else {
			let terminal = match self.driver.release_or_defer() {
				Ok(()) => error,
				Err(release_error) => error.with_secondary(release_error),
			};
			self.released.set(true);
			self.fail_close_or_record(terminal);
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
		// Serving releases application frames parked behind the handshake and
		// may invoke a hosted behavior before the native call returns.
		let host = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
		let _deliver = host.as_ref().map(DeliverGuard::enter_host);
		self.driver.session_serve(session)?;
		self.schedule_step();
		Ok(())
	}
}

#[cfg(test)]
mod tests;
