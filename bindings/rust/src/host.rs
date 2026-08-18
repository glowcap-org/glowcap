//! The CapTP [`Host`] — multi-session CapTP product over the byte-fed host archive
//! (`libpancake_host`, ADR-0072). It owns `engine.Node` (the sans-io handoff
//! router). Goblins' `mycapn` is two roles: product maps to Host, router tables map to
//! `engine.Node` — never a single-type equation (ADR-0079). The `PancakeHost`
//! owns every decision: the retained identity, session directory,
//! routing, transparent three-party redemption, and the gifter half's
//! origination. What lives here is only what the embedder contract leaves to
//! the binding: the host handle, the session-pointer to session registry the
//! action drain routes by, the vow table the drain's SETTLE/FAIL arms settle,
//! the action-drain kick loop, gift-id entropy, and the iroh redeem posture
//! the dial executor reads. Action decode + execute (`pop` / `run`) live in
//! `action.rs`; the pump lives in `pump.rs`; the dial executor lives in
//! `dial.rs`. [`Session`] lives in `session.rs`.
//!
//! Threading model: everything runs on one tokio current-thread `LocalSet`.
//! Tasks yield only at `.await` and no `pancake_host_*` call contains one, so
//! a verb-plus-register-plus-kick sequence is naturally atomic with no lock
//! and no progress semaphore. The one discipline rule that replaces a lock: no
//! `RefCell` borrow is held across an FFI call that can fire the behavior
//! trampoline (`pancake_host_session_feed_bytes`, `pancake_host_dialed`,
//! `pancake_host_provide_gift_id`) — take, drop,
//! call.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::rc::{Rc, Weak};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use tokio::sync::{oneshot, Notify};
use tokio::task::JoinHandle;

use crate::session_shared::SessionShared;
use crate::sys::host as ffi;
use crate::trampoline::{
	ctx_free, current_turn_for, inside_turn, outcome_behavior, reclaim_refused_cell, trampoline, ActorCell,
	InternalBehavior,
};
use crate::uri::OwnedLocator;
use crate::PendingWork;
use crate::Ref;
use crate::{sys, Argument, Behavior, Codec, Context, ContextInner, Error, Locator, Result};

/// Every connection's maximum admissible frame; mirrors
/// `PANCAKE_DEFAULT_FRAME_CAP`.
const HOST_FRAME_CAP: usize = sys::DEFAULT_FRAME_CAP;

/// Cap on stored outcomes whose vow is never awaited, so the store cannot grow
/// without bound; the oldest un-awaited outcome is evicted at the cap.
const MAX_UNOBSERVED_OUTCOMES: usize = 1024;

fn monotonic_ms() -> i64 {
	static EPOCH: OnceLock<Instant> = OnceLock::new();
	let elapsed = EPOCH.get_or_init(Instant::now).elapsed().as_millis();
	i64::try_from(elapsed).unwrap_or(i64::MAX)
}

fn close_result(code: i32) -> Result<()> {
	if code == sys::OK {
		Ok(())
	} else if code == sys::ERR_TIMEOUT {
		Err(Error::with_detail(
			code,
			"finish close exhausted its grace period".into(),
		))
	} else {
		Err(Error::with_detail(code, "native host close failed".into()))
	}
}

fn host_refusal(code: i32, operation: &str) -> Error {
	match check_host(code) {
		Err(error) => error,
		Ok(()) => Error::with_detail(
			sys::ERR_INTERNAL,
			format!("{operation} returned success without publishing its result"),
		),
	}
}

crate::error_slot::error_slot!(
	/// Like the core `check`, but for `pancake_host_*` calls: snapshot the host
	/// family's own thread-local last-error rather than the unrelated ocapn one.
	pub(crate) fn check_host;
	/// The calling thread's last `pancake_host_*` error message, read from the
	/// driver archive's own slot (never the ocapn family's).
	pub(crate) fn host_last_error;
	ffi::pancake_host_last_error
);

/// Spawn a task on the current `LocalSet`, tolerating teardown: `spawn_local`
/// panics when no `LocalSet` is running (a `Drop` firing while the set itself
/// unwinds), and a missed kick there is reclaimed by the host's own release
/// sweep, so the panic is contained instead of aborting a destructor.
pub(crate) fn try_spawn_local_handle<F>(future: F) -> Option<JoinHandle<()>>
where
	F: std::future::Future<Output = ()> + 'static,
{
	std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| tokio::task::spawn_local(future))).ok()
}

pub(crate) fn try_spawn_local<F>(future: F) -> bool
where
	F: std::future::Future<Output = ()> + 'static,
{
	try_spawn_local_handle(future).is_some()
}

// A release refused inside a behavior callback parks here — a `Drop` must
// never be a silent no-op-with-last-error — and the drain honors it once the
// enclosing verb has unwound. A parked connection release keeps its host alive
// (the `Rc`) so the release order stays session-before-host.
enum PendingRelease {
	Session {
		shared: Rc<SessionShared>,
	},
	/// Last-owner drop inside a callback. No Session can still retain the Host
	/// in this arm, so only the raw handle remains.
	HostRaw {
		host: *mut ffi::PancakeHost,
		context: Option<Rc<ContextInner>>,
	},
}

thread_local! {
	static PENDING_RELEASES: RefCell<VecDeque<PendingRelease>> = const { RefCell::new(VecDeque::new()) };
}

/// Park a connection release that a callback frame refused.
pub(crate) fn park_session_release(shared: Rc<SessionShared>) {
	PENDING_RELEASES.with(|list| list.borrow_mut().push_back(PendingRelease::Session { shared }));
}

/// Test observability: how many releases are parked on this thread, so a test
/// can assert a mid-turn close's parked release actually ran after the turn.
#[cfg(all(test, feature = "tcp"))]
pub(crate) fn pending_release_count() -> usize {
	PENDING_RELEASES.with(|list| list.borrow().len())
}

/// Run every parked release. Called at the head of each action drain, after
/// each feed batch, and after each locally-run behavior — always outside a
/// callback frame, where the releases are legal.
pub(crate) fn drain_pending_releases() {
	if inside_turn() {
		return;
	}
	loop {
		let Some(pending) = PENDING_RELEASES.with(|list| list.borrow_mut().pop_front()) else {
			return;
		};
		match pending {
			PendingRelease::Session { shared } => {
				if shared.finish_native_release().is_err() {
					PENDING_RELEASES.with(|list| list.borrow_mut().push_back(PendingRelease::Session { shared }));
					return;
				}
			}
			// HostRaw has no HostShared left to hold terminal state, but retains
			// the allocation policy the raw native Host still borrows.
			PendingRelease::HostRaw { host, context } => {
				crate::trace::detach_host(host);
				let rc = unsafe { ffi::pancake_host_release(host) };
				if !crate::lifecycle::release_consumed(rc) {
					PENDING_RELEASES
						.with(|list| list.borrow_mut().push_front(PendingRelease::HostRaw { host, context }));
					return;
				}
				if rc != sys::OK {
					if let Err(error) = check_host(rc) {
						crate::record_runtime_failure(crate::FailureLayer::Binding, "host-parked-drop-release", error);
					}
				}
			}
		}
	}
}

// A host vow's pending state: exactly three shapes, so the illegal "settled AND
// a live waiter" combination cannot be represented. Minted the instant the vow
// is registered (the mint IS the registration); an outcome that lands before
// anyone awaits is held as `Settled` for a late observation instead of hanging;
// a waiter lives only in `Awaited`, so an unobserved broken answer never strands
// a channel.
enum VowState {
	/// Registered, not yet awaited and not yet settled.
	Minted,
	/// A caller is awaiting; the outcome fires this sender.
	Awaited(oneshot::Sender<Result<Argument>>),
	/// The outcome landed before anyone awaited; held for a late observation.
	Settled(Result<Argument>),
}

struct VowRow {
	state: VowState,
	/// Session whose opt-in owns finalizer policy for this application-facing
	/// outcome. Weak: a late settlement cannot keep a closed Session alive.
	gc_session: Option<std::rc::Weak<SessionShared>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CloseBarrierState {
	Idle,
	Running,
	Complete(i32),
	Failed,
}

/// Removes a detached DIAL task from its Host on every terminal path, including
/// panic and cancellation. It carries only a Weak owner, so task tracking never
/// creates a Host -> task -> Host retention cycle.
pub(crate) struct OwnedTaskRegistration {
	host: Weak<HostShared>,
}

impl Drop for OwnedTaskRegistration {
	fn drop(&mut self) {
		if let Some(host) = self.host.upgrade() {
			host.owned_task_finished();
		}
	}
}

struct DialTaskRegistration {
	host: Weak<HostShared>,
	ticket: u64,
	_owned: OwnedTaskRegistration,
}

struct AbortTaskOnDrop(Option<tokio::task::JoinHandle<()>>);

impl Drop for AbortTaskOnDrop {
	fn drop(&mut self) {
		if let Some(task) = self.0.take() {
			task.abort();
		}
	}
}

impl Drop for DialTaskRegistration {
	fn drop(&mut self) {
		if let Some(host) = self.host.upgrade() {
			host.dial_tasks.borrow_mut().remove(&self.ticket);
		}
	}
}

/// The binding half of one CapTP Host: the raw `PancakeHost`, the CapTP session
/// registry, the vow table, and the redeem posture, shared behind an `Rc` by
/// the public [`Host`] and every [`SessionShared`] — which is what mechanically
/// enforces the header's "release the host always after its CapTP sessions" (the
/// host pointer cannot be released while any session wrapper lives).
pub(crate) struct HostShared {
	raw: Cell<*mut ffi::PancakeHost>,
	/// Binding-local close barrier coordination. Native Host lifecycle remains
	/// authoritative; `Failed` retains the raw handle for diagnosis and a final
	/// Drop attempt rather than pretending release succeeded.
	close_barrier: Cell<CloseBarrierState>,
	/// Exact first failure behind `CloseBarrierState::Failed`. The state remains
	/// `Copy` for cheap barrier checks while this owns the diagnostic payload.
	close_failure: RefCell<Option<Error>>,
	// Every live CapTP session shell by its PancakeHostSession address, so a FLUSH
	// action routes to the transport that owns the bytes and a dialed exporter
	// stays reachable for teardown. A session unregisters at close, which is
	// what breaks the Rc cycle between host and session state. `action::run`
	// reads it for FLUSH / CLOSE.
	pub(crate) sessions: RefCell<HashMap<usize, Rc<SessionShared>>>,
	// Host-owned async tasks whose futures may still hold native Session state.
	// Cancellation is only a request; the count falls from each future's RAII
	// registration when its complete state has actually been dropped.
	owned_tasks: Cell<usize>,
	release_notify: Notify,
	// The host-activity signal the event-driven close waits park on. Every
	// binding path whose native verb can advance close-relevant state (a byte
	// feed, a productive action drain, a resolver settle, a close request or
	// escalation, a session release, a reported dial outcome) wakes all parked
	// close drivers here. Signaling is wake-all against re-checking waiters,
	// so a spare signal is harmless; a missed source is a hang.
	activity: Notify,
	// Detached DIAL actions may await sockets, discovery, or relay setup after
	// the action drain returns. The Host owns their cancellation until terminal
	// reporting; no task may resume against a released native Host.
	dial_tasks: RefCell<HashMap<u64, JoinHandle<()>>>,
	close_task_started: Cell<bool>,
	// The vow table the drain's SETTLE/FAIL arms settle.
	vows: RefCell<HashMap<u64, VowRow>>,
	// Finalizer-reclaimed Host reference ids. A reference may be homed on a
	// sibling session and outlive the session that delivered it.
	pub(crate) gc_pending: RefCell<VecDeque<u64>>,
	// The first failure from a detached Host-progress task. Such a task has no
	// caller result; the next verb head takes this exact typed cause instead.
	background_failure: RefCell<Option<Error>>,
	// Opaque Host capability id -> hosted cell. Actors outlive the Port that
	// first projected them, so every sibling Session resolves through this one
	// Host-owned index. The core owns each cell and runs ctx_free at Host release.
	pub(crate) hosted: RefCell<HashMap<u64, *const ActorCell>>,
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	unobserved: RefCell<VecDeque<u64>>,
	/// The 32-byte Ed25519 identity seed this host was minted with — retained
	/// so a keyed-tcp listener can derive its public designator without a
	/// second identity (ADR-0075).
	seed: [u8; 32],
	// The hosted cell of each giftable, by published name, so
	// `Session::published_ref` can bind it to the identity that session surfaced
	// and a local send composes in process. The C tier owns the cells (it was
	// given a `ctx_free`); this only points at them. Re-publishing a name replaces
	// the entry, while the cell it displaced stays alive because existing
	// capabilities and gifts still reach its Host-Vat actor. The C tier frees
	// every cell at Host release.
	pub(crate) giftables: RefCell<HashMap<String, *const ActorCell>>,
	// A Host allocated in a caller Context borrows that native policy. Rc makes
	// the order structural, including teardown parked from a callback.
	context: Option<Rc<ContextInner>>,
	/// Stable identity in the retained Context's diagnostic namespace.
	diagnostic_id: u64,
	// The native loop this Host was adopted over (ADR-0112), or `None` for a
	// byte-fed Host this binding pumps itself. On a loop-adopted Host the loop
	// is the one action drain and the one release authority: kicks become loop
	// steps, no `pancake_host_pump_drain` runs here, and teardown routes
	// through `LoopShared::close` (which releases the wrapped native Host).
	driver_loop: RefCell<Option<Rc<crate::driver_loop::LoopShared>>>,
	// Explicit byte-fed connectors, indexed by the transport symbols their
	// owning package advertises. Native provider composition lives in the
	// driver loop instead; this registry is only for embedder-owned channels.
	connectors: RefCell<HashMap<&'static str, crate::Connector>>,
}

impl HostShared {
	fn new(
		seed: [u8; 32],
		codec: Codec,
		captp_version: crate::CaptpVersion,
		features: crate::FeatureSet,
		local_turn_budget: u32,
		context: Option<&Context>,
	) -> Result<Rc<HostShared>> {
		// The durable identity followed by a session-key root drawn here, at
		// this binding's entropy boundary, because the library draws none
		// (ADR-0097). The root is fresh per process, so every CapTP session
		// signs with its own key and a restart cannot recreate a prior
		// session's handoff names; the durable half stays exactly the caller's
		// seed, since a keyed locator's designator derives from it.
		let mut seed_with_root = [0u8; 64];
		seed_with_root[..32].copy_from_slice(&seed);
		getrandom::fill(&mut seed_with_root[32..]).map_err(|error| {
			Error::with_detail(
				sys::ERR_IO,
				format!("drawing the per-process session-key root failed: {error}"),
			)
		})?;
		// Compute every fallible wrapper-side value before native Host
		// construction, so `?` cannot leak a raw Host during setup.
		let mut designator = [0u8; 64];
		check_host(unsafe {
			ffi::pancake_host_designator_from_seed(seed.as_ptr(), seed.len(), designator.as_mut_ptr(), designator.len())
		})?;
		let context = match context {
			Some(context) => context.retain_inner(),
			None => Rc::new(ContextInner::new()?),
		};
		let mut raw: *mut ffi::PancakeHost = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_new_in(
				context.raw,
				seed_with_root.as_ptr(),
				seed_with_root.len(),
				HOST_FRAME_CAP,
				1,
				codec.to_c(),
				captp_version.to_c(),
				features.to_c(),
				local_turn_budget,
				&mut raw,
			)
		})?;
		let mut diagnostic_id = 0;
		if let Err(error) = check_host(unsafe { ffi::pancake_host_diagnostic_id(raw, &mut diagnostic_id) }) {
			let cleanup_rc = unsafe { ffi::pancake_host_release(raw) };
			let cleanup = check_host(cleanup_rc);
			if !crate::lifecycle::release_consumed(cleanup_rc) {
				core::mem::forget(context);
			}
			return Err(crate::retain_cleanup_failure(error, cleanup));
		}
		// The host's own key designator labels the live trace so one peer
		// remains one node in a feed several producers share.
		crate::trace::attach_host(
			raw,
			String::from_utf8_lossy(&designator).into_owned(),
			Rc::clone(&context),
			diagnostic_id,
		);
		Ok(Rc::new(HostShared {
			raw: Cell::new(raw),
			close_barrier: Cell::new(CloseBarrierState::Idle),
			close_failure: RefCell::new(None),
			sessions: RefCell::new(HashMap::new()),
			owned_tasks: Cell::new(0),
			release_notify: Notify::new(),
			activity: Notify::new(),
			dial_tasks: RefCell::new(HashMap::new()),
			close_task_started: Cell::new(false),
			vows: RefCell::new(HashMap::new()),
			gc_pending: RefCell::new(VecDeque::new()),
			background_failure: RefCell::new(None),
			hosted: RefCell::new(HashMap::new()),
			unobserved: RefCell::new(VecDeque::new()),
			giftables: RefCell::new(HashMap::new()),
			seed,
			context: Some(context),
			diagnostic_id,
			driver_loop: RefCell::new(None),
			connectors: RefCell::new(HashMap::new()),
		}))
	}

	/// Adopt the native Host a `DriverLoop` minted (ADR-0112): the wrapper
	/// every application verb, publish trampoline, and vow settle works on,
	/// while the loop stays the one action drain and the one release
	/// authority. `seed` is the identity half of the loop's 64-byte seed, so
	/// `Host::designator` answers the same as on a byte-fed Host.
	pub(crate) fn adopt_loop(
		raw: *mut ffi::PancakeHost,
		seed: [u8; 32],
		driver_loop: Rc<crate::driver_loop::LoopShared>,
	) -> Result<Rc<HostShared>> {
		let mut designator = [0u8; 64];
		check_host(unsafe {
			ffi::pancake_host_designator_from_seed(seed.as_ptr(), seed.len(), designator.as_mut_ptr(), designator.len())
		})?;
		let context = driver_loop.retained_context();
		let mut diagnostic_id = 0;
		check_host(unsafe { ffi::pancake_host_diagnostic_id(raw, &mut diagnostic_id) })?;
		if let Some(context) = context.as_ref() {
			crate::trace::attach_host(
				raw,
				String::from_utf8_lossy(&designator).into_owned(),
				Rc::clone(context),
				diagnostic_id,
			);
		}
		Ok(Rc::new(HostShared {
			raw: Cell::new(raw),
			close_barrier: Cell::new(CloseBarrierState::Idle),
			close_failure: RefCell::new(None),
			sessions: RefCell::new(HashMap::new()),
			owned_tasks: Cell::new(0),
			release_notify: Notify::new(),
			activity: Notify::new(),
			dial_tasks: RefCell::new(HashMap::new()),
			close_task_started: Cell::new(false),
			vows: RefCell::new(HashMap::new()),
			gc_pending: RefCell::new(VecDeque::new()),
			background_failure: RefCell::new(None),
			hosted: RefCell::new(HashMap::new()),
			unobserved: RefCell::new(VecDeque::new()),
			giftables: RefCell::new(HashMap::new()),
			seed,
			context,
			diagnostic_id,
			driver_loop: RefCell::new(Some(driver_loop)),
			connectors: RefCell::new(HashMap::new()),
		}))
	}

	pub(crate) fn install_connectors(&self, connectors: &[crate::Connector]) -> Result<()> {
		self.guard_handle()?;
		let mut installed = self.connectors.borrow_mut();
		let mut pending = HashMap::new();
		for connector in connectors {
			if connector.transports().is_empty() {
				return Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"Runtime requires at least one connector transport".to_string(),
				));
			}
			for &transport in connector.transports() {
				if transport.is_empty() {
					return Err(Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						"connector transport symbols must not be empty".to_string(),
					));
				}
				if pending.contains_key(transport) {
					return Err(Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						format!("Runtime composition repeats transport {transport:?}"),
					));
				}
				if let Some(existing) = installed.get(transport) {
					if !existing.same_instance(connector) {
						return Err(Error::with_detail(
							sys::ERR_INVALID_ARGUMENT,
							format!("a different connector already owns transport {transport:?}"),
						));
					}
					continue;
				}
				pending.insert(transport, connector.clone());
			}
		}
		for (transport, connector) in pending {
			installed.insert(transport, connector);
		}
		Ok(())
	}

	pub(crate) fn connector(&self, transport: &str) -> Option<crate::Connector> {
		self.connectors.borrow().get(transport).cloned()
	}

	/// The native loop this Host is adopted over, or `None` for a byte-fed
	/// Host. The dial and listen routers read it to stage on the owning loop
	/// instead of opening a byte channel on a host the loop drains.
	pub(crate) fn driver_loop(&self) -> Option<Rc<crate::driver_loop::LoopShared>> {
		self.driver_loop.borrow().clone()
	}

	/// Establish this Host's one native runtime owner before its first network
	/// operation. Existing loop-backed Hosts reuse their loop; a byte-fed Host
	/// transfers transactionally through the C ABI.
	pub(crate) fn ensure_driver_loop(
		self: &Rc<Self>,
		handshake_ms: u32,
		settle_ms: u32,
	) -> Result<Rc<crate::driver_loop::LoopShared>> {
		self.guard_handle()?;
		if let Some(lp) = self.driver_loop() {
			return Ok(lp);
		}
		let lp = crate::driver_loop::LoopShared::take_host(self, handshake_ms, settle_ms)?;
		*self.driver_loop.borrow_mut() = Some(Rc::clone(&lp));
		Ok(lp)
	}

	/// Release one native session handle through the verb that owns it: the
	/// loop's own `pancake_driver_session_release` for a loop-minted session
	/// (which also drops queued events naming it), `pancake_host_session_release`
	/// for a byte-fed one. A loop already released frees its sessions itself,
	/// so the loop arm is a no-op then.
	pub(crate) fn release_native_session(&self, session: *mut ffi::PancakeHostSession) -> Result<()> {
		match self.driver_loop() {
			Some(lp) => lp.native_session_release(session)?,
			None => check_host(unsafe { ffi::pancake_host_session_release(session) })?,
		}
		// A released session retires its pending close work, so a driver
		// parked on host activity must re-check progress.
		self.note_close_activity();
		Ok(())
	}

	/// Finish the wrapper half after the native loop has reached its close
	/// barrier and projected every committed event. The native Host itself dies
	/// with `pancake_driver_release`, never through `pancake_host_release`.
	pub(crate) fn finish_loop_teardown(self: &Rc<HostShared>, close_code: i32) {
		self.finish_loop_teardown_with(CloseBarrierState::Complete(close_code), None);
	}

	/// The same ownership retirement when the loop terminated because of a
	/// background failure. Native state is still fully released, while every
	/// Host close observer receives the exact first cause.
	pub(crate) fn finish_failed_loop_teardown(self: &Rc<HostShared>, error: Error) {
		self.finish_loop_teardown_with(CloseBarrierState::Failed, Some(error));
	}

	fn finish_loop_teardown_with(self: &Rc<HostShared>, terminal: CloseBarrierState, failure: Option<Error>) {
		if matches!(
			self.close_barrier.get(),
			CloseBarrierState::Complete(_) | CloseBarrierState::Failed
		) {
			return;
		}
		self.close_barrier.set(CloseBarrierState::Running);
		let sessions: Vec<_> = self.sessions.borrow_mut().drain().map(|(_, session)| session).collect();
		for session in sessions {
			session.commit_native_release();
		}
		PENDING_RELEASES.with(|list| {
			list.borrow_mut()
				.retain(|item| !matches!(item, PendingRelease::Session { shared } if Rc::ptr_eq(&shared.host, self)));
		});
		debug_assert!(self
			.vows
			.borrow()
			.values()
			.all(|row| matches!(row.state, VowState::Settled(_))));
		let raw = self.raw.replace(core::ptr::null_mut());
		if !raw.is_null() {
			crate::trace::detach_host(raw);
		}
		self.vows.borrow_mut().clear();
		self.unobserved.borrow_mut().clear();
		if let Some(error) = failure {
			*self.close_failure.borrow_mut() = Some(error);
		}
		self.close_barrier.set(terminal);
		self.release_notify.notify_waiters();
		// The loop's release runs every ctx-free callback; these maps hold only
		// non-owning pointers and must not serve stale lookups meanwhile.
		self.hosted.borrow_mut().clear();
		self.giftables.borrow_mut().clear();
	}

	/// The raw `PancakeHost` handle.
	pub(crate) fn raw(&self) -> *mut ffi::PancakeHost {
		self.raw.get()
	}

	pub(crate) fn durable_seed(&self) -> [u8; 32] {
		self.seed
	}

	pub(crate) fn retained_context(&self) -> Option<Rc<ContextInner>> {
		self.context.as_ref().map(Rc::clone)
	}

	pub(crate) fn actor_cell(&self, behavior: InternalBehavior) -> Result<*mut ActorCell> {
		let context = self.retained_context().ok_or_else(|| {
			Error::with_detail(
				sys::ERR_CLOSED,
				"host diagnostic context was released before actor publication".to_string(),
			)
		})?;
		Ok(Box::into_raw(Box::new(ActorCell {
			behavior: RefCell::new(behavior),
			context,
			diagnostic_id: self.diagnostic_id(),
		})))
	}

	pub(crate) fn diagnostic_id(&self) -> u64 {
		self.diagnostic_id
	}

	pub(crate) fn guard_handle(&self) -> Result<()> {
		if self.raw.get().is_null() {
			Err(Error::with_detail(sys::ERR_CLOSED, "host closed".to_string()))
		} else {
			Ok(())
		}
	}

	pub(crate) fn closing(&self) -> bool {
		self.close_barrier.get() != CloseBarrierState::Idle
	}

	pub(crate) fn fail_close(&self, error: Error) {
		if matches!(
			self.close_barrier.get(),
			CloseBarrierState::Complete(_) | CloseBarrierState::Failed
		) {
			return;
		}
		*self.close_failure.borrow_mut() = Some(error);
		self.close_barrier.set(CloseBarrierState::Failed);
		self.release_notify.notify_waiters();
	}

	fn retained_close_failure(&self) -> Error {
		self.close_failure.borrow().clone().unwrap_or_else(|| {
			Error::with_detail(
				sys::ERR_INTERNAL,
				"host close failed without retaining its cause".to_string(),
			)
		})
	}

	pub(crate) fn native_close_committed(&self) {
		if self.close_barrier.get() == CloseBarrierState::Idle {
			self.close_barrier.set(CloseBarrierState::Running);
		}
	}

	/// Wake every close driver parked on host activity. Call it after any
	/// native verb that can advance close-relevant state; waiters re-check
	/// progress on every wake, so a spare signal costs one check and a missed
	/// one is a hang.
	pub(crate) fn note_close_activity(&self) {
		self.activity.notify_waiters();
	}

	/// The registration half of a close driver's wait. The returned future
	/// must be pinned and enabled before the close-progress check it guards,
	/// so a signal landing between that check and the await still wakes the
	/// driver.
	pub(crate) fn close_activity(&self) -> tokio::sync::futures::Notified<'_> {
		self.activity.notified()
	}

	/// The longest a close driver may wait for new input before re-checking
	/// close progress: the time until the nearest FINISH grace deadline (the
	/// Host's own or any session's), clamped at zero, or `None` when no finite
	/// deadline is pending and only host activity can advance terminal
	/// progress. Native refusal reaches the close driver; treating it as "no
	/// deadline" would turn a diagnosable failure into an unbounded park.
	pub(crate) fn close_wait(&self) -> Result<Option<Duration>> {
		let mut wait_ms: i64 = -1;
		let rc = unsafe { ffi::pancake_host_close_wait_ms(self.raw(), monotonic_ms(), &mut wait_ms) };
		check_host(rc)?;
		if wait_ms >= 0 {
			Ok(Some(Duration::from_millis(wait_ms as u64)))
		} else {
			Ok(None)
		}
	}

	pub(crate) fn start_owned_task(self: &Rc<Self>) -> Result<OwnedTaskRegistration> {
		let count = self
			.owned_tasks
			.get()
			.checked_add(1)
			.ok_or_else(|| Error::with_detail(sys::ERR_INTERNAL, "Host-owned task count exhausted".to_string()))?;
		self.owned_tasks.set(count);
		Ok(OwnedTaskRegistration {
			host: Rc::downgrade(self),
		})
	}

	fn owned_task_finished(self: &Rc<Self>) {
		let Some(remaining) = self.owned_tasks.get().checked_sub(1) else {
			self.record_background_failure(Error::with_detail(
				sys::ERR_INTERNAL,
				"Host-owned task registration underflow".to_string(),
			));
			return;
		};
		self.owned_tasks.set(remaining);
		if remaining == 0 {
			self.release_notify.notify_waiters();
		}
	}

	/// Spawn one detached DIAL executor under this Host's terminal lifetime.
	/// Tokio cancellation is the right primitive here: every binding task runs
	/// on one current-thread LocalSet, so close cannot race a task currently on
	/// another thread, and `abort` prevents its next poll before native teardown.
	pub(crate) fn spawn_dial_task<F, Fut>(self: &Rc<Self>, ticket: u64, run: F) -> Result<bool>
	where
		F: FnOnce(Rc<HostShared>) -> Fut + 'static,
		Fut: Future<Output = ()> + 'static,
	{
		if self.raw.get().is_null() {
			return Ok(false);
		}
		let host = Rc::clone(self);
		let registration = DialTaskRegistration {
			host: Rc::downgrade(self),
			ticket,
			_owned: self.start_owned_task()?,
		};
		let Some(task) = try_spawn_local_handle(async move {
			let _registration = registration;
			let observer = Rc::clone(&host);
			let mut inner = AbortTaskOnDrop(Some(tokio::task::spawn_local(run(host))));
			let outcome = match inner.0.as_mut() {
				Some(handle) => handle.await,
				None => return,
			};
			inner.0.take();
			if let Err(join) = outcome {
				let primary = if join.is_panic() {
					Error::with_detail(
						sys::ERR_INTERNAL,
						format!(
							"dial task panicked: {}",
							crate::panic_message(join.into_panic().as_ref())
						),
					)
				} else {
					Error::with_detail(sys::ERR_INTERNAL, format!("dial task failed: {join}"))
				};
				let cancellation = check_host(unsafe { ffi::pancake_host_dial_cancelled(observer.raw(), ticket) });
				observer.record_background_failure(crate::retain_cleanup_failure(primary, cancellation));
			}
		}) else {
			return Ok(false);
		};
		self.dial_tasks.borrow_mut().insert(ticket, task);
		Ok(true)
	}

	pub(crate) async fn cancel_dial_task(&self, ticket: u64) -> Result<()> {
		let task = self.dial_tasks.borrow_mut().remove(&ticket);
		let task_failure = if let Some(task) = task {
			task.abort();
			match task.await {
				Ok(()) => None,
				Err(join) if join.is_cancelled() => None,
				Err(join) if join.is_panic() => Some(Error::with_detail(
					sys::ERR_INTERNAL,
					format!(
						"dial task panicked: {}",
						crate::panic_message(join.into_panic().as_ref())
					),
				)),
				Err(join) => Some(Error::with_detail(
					sys::ERR_INTERNAL,
					format!("dial task join failed: {join}"),
				)),
			}
		} else {
			None
		};
		let cancellation = check_host(unsafe { ffi::pancake_host_dial_cancelled(self.raw(), ticket) });
		match task_failure {
			Some(primary) => Err(crate::retain_cleanup_failure(primary, cancellation)),
			None => cancellation,
		}
	}

	pub(crate) fn set_advertised_locator(&self, locator: &Locator) -> Result<()> {
		self.guard_handle()?;
		let owned = OwnedLocator::new(locator)?;
		check_host(unsafe { ffi::pancake_host_set_advertised_locator(self.raw.get(), owned.borrow_view()?) })
	}

	pub(crate) fn remove_advertised_locator(&self, transport: &str) -> Result<()> {
		self.guard_handle()?;
		check_host(unsafe {
			ffi::pancake_host_remove_advertised_locator(self.raw.get(), transport.as_ptr(), transport.len())
		})
	}

	/// Selective session-limit knobs (ADR-0082). Pass `0` to leave a field
	/// unchanged. Affects peers minted after this call.
	pub(crate) fn set_session_limits(
		&self,
		max_frame_bytes: usize,
		queue_cap: usize,
		outbound_high_water_bytes: usize,
	) -> Result<()> {
		self.guard_handle()?;
		check_host(unsafe {
			ffi::pancake_host_set_session_limits(self.raw.get(), max_frame_bytes, queue_cap, outbound_high_water_bytes)
		})
	}

	// ── Session registry ────────────────────────────────────────────────────

	/// Track a live CapTP session shell by its PancakeHostSession address; the
	/// `SessionShared` constructor calls it.
	pub(crate) fn register_session(&self, key: usize, session: Rc<SessionShared>) {
		self.sessions.borrow_mut().insert(key, session);
	}

	/// Stop tracking a released CapTP session shell.
	pub(crate) fn unregister_session(&self, key: usize) {
		self.sessions.borrow_mut().remove(&key);
	}

	/// Resolve the Host-owned session address carried by a callback turn to the
	/// existing public wrapper. A loop-internal redeem leg may have no wrapper;
	/// callers preserve their Host-only turn context in that case.
	pub(crate) fn session_for_ptr(&self, ptr: *mut ffi::PancakeHostSession) -> Option<Rc<SessionShared>> {
		self.sessions.borrow().get(&(ptr as usize)).cloned()
	}

	/// The hosted cell behind a Host-scoped local capability.
	pub(crate) fn hosted_cell(&self, ref_id: u64) -> Option<*const ActorCell> {
		self.hosted.borrow().get(&ref_id).copied()
	}

	/// The live session homing a remote capability, or `None` for a local,
	/// stale, foreign-Host, or closed-session capability. `send_redeeming`
	/// suppresses the sending session itself and surfaces only another exporter.
	///
	/// The answer is deterministic because it is read out of the capability
	/// itself: the token carries which exporter session hosts it, so this
	/// never watches for a dial to complete. It is therefore right with several
	/// redeems in flight at once, and it still names the exporter when the
	/// redeem reused a session an earlier one already dialed, where no fresh
	/// dial happened at all. `Session::send_redeeming` calls it on the reply it
	/// just awaited.
	pub(crate) fn exporter_for(self: &Rc<Self>, capability: &Ref) -> Result<Option<Rc<SessionShared>>> {
		self.guard_handle()?;
		let wire = capability.to_sys()?;
		let out = if let Some(lp) = self.driver_loop() {
			lp.claim_reference_exporter(&wire)?.unwrap_or(core::ptr::null_mut())
		} else {
			let mut out: *mut ffi::PancakeHostSession = core::ptr::null_mut();
			check_host(unsafe { ffi::pancake_host_reference_exporter(self.raw.get(), &wire, &mut out) })?;
			out
		};
		if out.is_null() {
			return Ok(None);
		}
		if let Some(existing) = self.sessions.borrow().get(&(out as usize)).cloned() {
			return Ok(Some(existing));
		}
		// A loop-adopted Host redeems handoffs inside its own steps, so the
		// exporter session may be loop-internal with no shell yet: wrap it
		// lazily as a loop-backed shell (registered, so a repeat resolves to
		// the same one), the way the byte-fed drain's redeem registers its own.
		if let Some(lp) = self.driver_loop() {
			let shared = SessionShared::new_loop(out, Rc::clone(self), lp);
			shared.spawn_serve();
			return Ok(Some(shared));
		}
		Ok(None)
	}

	/// Terminally release this Host. A callback cannot free the native Host
	/// whose actor cell is on its stack, so it parks one Host-owned transaction;
	/// the outer feed or local-run drain performs the same ordered teardown.
	pub(crate) fn close_host(self: &Rc<HostShared>, pending: PendingWork) -> Result<()> {
		pending.to_ffi()?;
		match self.close_barrier.get() {
			CloseBarrierState::Complete(code) => return close_result(code),
			CloseBarrierState::Failed => return Err(self.retained_close_failure()),
			CloseBarrierState::Idle | CloseBarrierState::Running => {}
		}
		// A loop-adopted Host tears down through its loop, which releases the
		// wrapped native Host itself; `loop_teardown` (called back from
		// `LoopShared::close`) retires this wrapper's shells and vows.
		if let Some(lp) = self.driver_loop() {
			return lp.request_close(pending);
		}
		self.request_native_release(pending)
	}

	async fn wait_closed(&self) -> Result<()> {
		loop {
			let notified = self.release_notify.notified();
			match self.close_barrier.get() {
				CloseBarrierState::Complete(code) => return close_result(code),
				CloseBarrierState::Failed => return Err(self.retained_close_failure()),
				CloseBarrierState::Idle | CloseBarrierState::Running => notified.await,
			}
		}
	}

	/// Release Session shells that unregistered while their callbacks were
	/// still on the stack. They are absent from `sessions`, but the native Host
	/// still owns them and must not be freed first.
	fn drain_parked_sessions(self: &Rc<HostShared>) -> Result<()> {
		loop {
			let parked = PENDING_RELEASES.with(|list| {
				let mut list = list.borrow_mut();
				let index = list.iter().position(
					|item| matches!(item, PendingRelease::Session { shared } if Rc::ptr_eq(&shared.host, self)),
				);
				index.and_then(|index| list.remove(index))
			});
			let Some(PendingRelease::Session { shared }) = parked else {
				return Ok(());
			};
			if let Err(error) = shared.finish_native_release() {
				PENDING_RELEASES.with(|list| list.borrow_mut().push_back(PendingRelease::Session { shared }));
				return Err(error);
			}
		}
	}

	fn request_native_release(self: &Rc<HostShared>, pending: PendingWork) -> Result<()> {
		self.drain_parked_sessions()?;
		let options = pending.to_ffi()?;
		let rc = unsafe { ffi::pancake_host_close(self.raw(), &options, monotonic_ms()) };
		if rc != sys::OK {
			return check_host(rc);
		}
		self.native_close_committed();
		// A close request or escalation is close-relevant activity: a driver
		// parked on a now-superseded wait must re-check progress.
		self.note_close_activity();
		if !self.close_task_started.get() {
			let host = Rc::clone(self);
			if try_spawn_local_handle(async move { host.drive_native_close().await }).is_none() {
				return Err(Error::with_detail(
					sys::ERR_INTERNAL,
					"host close requires a running LocalSet".into(),
				));
			}
			self.close_task_started.set(true);
		}
		Ok(())
	}

	async fn drive_native_close(self: Rc<HostShared>) {
		let close_code = loop {
			if self.close_barrier.get() != CloseBarrierState::Running {
				return;
			}
			// Register the activity waiter before the progress check, so a
			// verb completing between the check and the await still wakes
			// this loop instead of being lost.
			let notified = self.close_activity();
			tokio::pin!(notified);
			notified.as_mut().enable();
			let mut lifecycle = 0;
			let rc = unsafe { ffi::pancake_host_close_progress(self.raw(), monotonic_ms(), &mut lifecycle) };
			if rc != sys::OK && rc != sys::ERR_TIMEOUT {
				self.fail_close(host_refusal(rc, "advancing host close"));
				return;
			}
			let closed = match crate::lifecycle_is_closed(lifecycle) {
				Ok(closed) => closed,
				Err(error) => {
					self.fail_close(error);
					return;
				}
			};
			if closed {
				break rc;
			}
			// Drain what progress queued before parking. A productive drain
			// signals the waiter registered above, forcing one more progress
			// check rather than parking over undrained work.
			if let Err(error) = self.kick_actions().await {
				self.fail_close(error);
				return;
			}
			// Wake on host activity or on the nearest FINISH grace deadline;
			// with no finite deadline pending, only activity can advance
			// terminal progress, so the driver parks on activity alone.
			match self.close_wait() {
				Ok(Some(wait)) => {
					tokio::select! {
						() = notified.as_mut() => {}
						() = tokio::time::sleep(wait) => {}
					}
				}
				Ok(None) => notified.await,
				Err(error) => {
					self.fail_close(error);
					return;
				}
			}
		};
		loop {
			let notified = self.release_notify.notified();
			if self.owned_tasks.get() == 0 {
				break;
			}
			notified.await;
		}
		self.finish_native_release(close_code);
	}

	fn finish_native_release(self: &Rc<HostShared>, close_code: i32) {
		if self.close_barrier.get() != CloseBarrierState::Running {
			return;
		}
		// A task may fail after the close driver's final action drain but before
		// its owned-task count reaches zero. Claim that exact cause here, at the
		// last surviving barrier, while still releasing native state below.
		let background_failure = self.take_background_failure();
		let raw = self.raw.get();
		if raw.is_null() {
			if let Some(error) = background_failure {
				*self.close_failure.borrow_mut() = Some(error);
				self.close_barrier.set(CloseBarrierState::Failed);
			} else {
				self.close_barrier.set(CloseBarrierState::Complete(close_code));
			}
			self.release_notify.notify_waiters();
			return;
		}
		debug_assert_eq!(self.owned_tasks.get(), 0);
		if let Err(error) = self.drain_parked_sessions() {
			self.fail_close(background_failure.map_or(error.clone(), |primary| primary.with_secondary(error)));
			return;
		}
		debug_assert!(self.sessions.borrow().is_empty());
		debug_assert!(self
			.vows
			.borrow()
			.values()
			.all(|row| matches!(row.state, VowState::Settled(_))));
		let rc = unsafe { ffi::pancake_host_release(raw) };
		if rc != sys::OK {
			let release = host_refusal(rc, "releasing host");
			if crate::lifecycle::release_consumed(rc) {
				self.retire_native_host(raw);
			}
			self.fail_close(background_failure.map_or(release.clone(), |primary| primary.with_secondary(release)));
			return;
		}
		self.retire_native_host(raw);
		if let Some(error) = background_failure {
			*self.close_failure.borrow_mut() = Some(error);
			self.close_barrier.set(CloseBarrierState::Failed);
		} else {
			self.close_barrier.set(CloseBarrierState::Complete(close_code));
		}
		self.release_notify.notify_waiters();
	}

	fn retire_native_host(&self, raw: *mut ffi::PancakeHost) {
		crate::trace::detach_host(raw);
		self.raw.set(core::ptr::null_mut());
		self.vows.borrow_mut().clear();
		self.unobserved.borrow_mut().clear();
		// Native release ran every ctx-free callback. These maps contain only
		// non-owning pointers and cannot retain stale lookup results afterward.
		self.hosted.borrow_mut().clear();
		self.giftables.borrow_mut().clear();
	}

	// ── The vow table ──────────────────────────────────────────────────────────

	/// Record a freshly minted vow so the drain can route its completion. Must
	/// run in the same synchronous block as the minting FFI call, so no drain
	/// can pop the completion first.
	pub(crate) fn vow_minted(&self, vow: u64, gc_session: Option<&Rc<SessionShared>>) {
		// Finalizer policy belongs to the operation that exposes the value, so
		// sample the opt-in at mint rather than letting a later toggle rewrite
		// an already-admitted outcome's ownership contract.
		let gc_session = gc_session.filter(|session| session.gc.get()).map(Rc::downgrade);
		self.vows.borrow_mut().insert(
			vow,
			VowRow {
				state: VowState::Minted,
				gc_session,
			},
		);
	}

	/// The vow's eventual outcome: the fulfilled wire value, or a typed
	/// rejection — `ErrorKind::Broken` for a partner break, `ErrorKind::Closed`
	/// when the settle was the disconnect's own break. Settles immediately
	/// from the recorded state when the outcome already landed.
	pub(crate) fn await_vow(self: &Rc<HostShared>, vow: u64) -> impl std::future::Future<Output = Result<Argument>> {
		enum Waiting {
			Now(Result<Argument>),
			Settled(oneshot::Receiver<Result<Argument>>),
		}
		let waiting = {
			let mut vows = self.vows.borrow_mut();
			match vows.get_mut(&vow) {
				// Evicted (never awaited until past the cap) or never minted here.
				None => Waiting::Now(Err(Error::with_detail(
					sys::ERR_CLOSED,
					"the vow's outcome is gone (unobserved past the cap)".to_string(),
				))),
				Some(row) => match std::mem::replace(&mut row.state, VowState::Minted) {
					VowState::Settled(outcome) => {
						vows.remove(&vow);
						Waiting::Now(outcome)
					}
					// Minted, or re-awaited: (re)park a waiter. A prior
					// `Awaited`'s sender is dropped here, breaking that stale
					// receiver — the same overwrite the two-field form performed.
					VowState::Minted | VowState::Awaited(_) => {
						let (tx, rx) = oneshot::channel();
						row.state = VowState::Awaited(tx);
						Waiting::Settled(rx)
					}
				},
			}
		};
		// The future holds the host alive so a parked waiter cannot outlive the
		// vow table it is registered in.
		let host = Rc::clone(self);
		async move {
			let _hold = host;
			match waiting {
				Waiting::Now(outcome) => outcome,
				Waiting::Settled(rx) => rx.await.unwrap_or_else(|_| {
					Err(Error::with_detail(
						sys::ERR_CLOSED,
						"the host was released with the vow still pending".to_string(),
					))
				}),
			}
		}
	}

	// The drain's settle arms: fire the waiter, or record the outcome for a
	// late observation (bounded FIFO — an outcome nobody ever awaits is evicted
	// at the cap). Called from `action::run`'s SETTLE / FAIL arms.
	pub(crate) fn settle_vow(&self, vow: u64, mut outcome: Result<Argument>) {
		{
			let mut vows = self.vows.borrow_mut();
			let Some(row) = vows.get_mut(&vow) else {
				return; // an outcome nobody registered for
			};
			if let (Ok(value), Some(session)) = (&mut outcome, row.gc_session.as_ref().and_then(std::rc::Weak::upgrade))
			{
				crate::gc::track_argument(&session, value);
			}
			match std::mem::replace(&mut row.state, VowState::Minted) {
				VowState::Awaited(waiter) => {
					vows.remove(&vow);
					drop(vows);
					// Send failure proves the awaiting future was cancelled. The vow
					// row is terminal and removed, and no native handle belongs to this
					// binding-side delivery.
					drop(waiter.send(outcome));
					return;
				}
				// Minted, or an already-settled row re-settled: hold the
				// outcome for a late observation.
				VowState::Minted | VowState::Settled(_) => {
					row.state = VowState::Settled(outcome);
				}
			}
		}
		let mut unobserved = self.unobserved.borrow_mut();
		unobserved.push_back(vow);
		while unobserved.len() > MAX_UNOBSERVED_OUTCOMES {
			let Some(oldest) = unobserved.pop_front() else {
				break;
			};
			let mut vows = self.vows.borrow_mut();
			// Only evict a row still parked unobserved; an observed one is gone.
			let evict = matches!(
				vows.get(&oldest),
				Some(stale) if matches!(stale.state, VowState::Settled(_))
			);
			if evict {
				vows.remove(&oldest);
			}
		}
	}

	/// Settle every binding-side waiter after the loop itself has failed before
	/// it could project C ABI FAIL events. The core Host remains the semantic
	/// authority; this only prevents its wrapper promises from parking forever
	/// when the projection path is what died.
	pub(crate) fn fail_pending_vows(&self, code: i32, detail: &str) {
		let vows: Vec<u64> = self.vows.borrow().keys().copied().collect();
		for vow in vows {
			self.settle_vow(vow, Err(Error::with_detail(code, detail.to_string())));
		}
	}

	pub(crate) fn record_background_failure(&self, error: Error) {
		let mut retained = self.background_failure.borrow_mut();
		*retained = Some(match retained.take() {
			Some(primary) => primary.with_secondary(error),
			None => error,
		});
		self.note_close_activity();
	}

	pub(crate) fn take_background_failure(&self) -> Option<Error> {
		self.background_failure.borrow_mut().take()
	}

	// ── The action drain (the one loop rule) ──────────────────────────────────

	/// Kick the action drain from a synchronous verb: schedule it as its own
	/// task on the `LocalSet`.
	pub(crate) fn schedule_kick(self: &Rc<HostShared>) -> Result<()> {
		// On a loop-adopted Host the native loop is the one drain, so the kick
		// becomes a scheduled loop step — deferred, so a kick from inside a
		// turn steps only after the enclosing step unwinds.
		if let Some(lp) = self.driver_loop() {
			lp.schedule_step();
			return lp.guard_handle();
		}
		if inside_turn() || self.raw.get().is_null() {
			return Ok(());
		}
		if self.closing() {
			// The close driver owns the drain while the barrier runs, so a
			// kick cannot spawn one; wake the driver instead, and the work
			// this verb queued drains in its next pass.
			self.note_close_activity();
			return Ok(());
		}
		let registration = self.start_owned_task()?;
		let host = Rc::clone(self);
		if !try_spawn_local(async move {
			let _registration = registration;
			if let Err(error) = host.kick_actions().await {
				let detail = format!("action drain failed: {error}");
				host.fail_pending_vows(error.code(), &detail);
				host.record_background_failure(error);
			}
		}) {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"action progress requires a running LocalSet; queued work was not discarded".to_string(),
			));
		}
		Ok(())
	}

	/// Schedule progress for an unowned destructor/finalizer effect. The work
	/// stays queued, and refused admission is retained for the next verb head.
	pub(crate) fn schedule_kick_or_record(self: &Rc<HostShared>) {
		if let Err(error) = self.schedule_kick() {
			self.record_background_failure(error);
		}
	}

	/// Run the shared C action drain, then honor each parked arm. Reentrant on
	/// purpose, the async spelling of the Racket binding's reentrant host lock:
	/// the DIAL arm's dial executor establishes a whole new session *inside*
	/// an action, and that establish must itself drain (its start-session
	/// FLUSH) — a single-flighted drain would await its own completion there.
	/// Arms are parked under `pancake_host_pump_drain` (sync hooks only) and
	/// awaited after the C loop returns, so overlapping kickers never await
	/// inside the C callback. Re-parks until empty: a NEED_GIFT_ID's
	/// `provide_gift_id` can queue FLUSH legs after the C drain returns (same
	/// as Racket's `drain-host-actions!`). A no-op inside a hosted turn: the
	/// host refuses the driving verbs there, and everything the turn enqueued
	/// pumps when the enclosing feed unwinds into this same drain.
	pub(crate) async fn kick_actions(self: &Rc<HostShared>) -> Result<()> {
		if inside_turn() || self.raw.get().is_null() {
			return Ok(());
		}
		drain_pending_releases();
		crate::gc::drain(self)?;
		// The native loop is the drain on a loop-adopted Host: one step flushes
		// what a verb queued and routes completions as loop events. No
		// `pancake_host_pump_drain` may run beside it — the loop owns the queue.
		if let Some(lp) = self.driver_loop() {
			return match lp.step_now() {
				Ok(()) => Ok(()),
				Err(error) => {
					let surfaced = error.clone();
					lp.fail_background(error);
					Err(surfaced)
				}
			};
		}
		loop {
			if self.raw.get().is_null() {
				return Ok(());
			}
			let (parked, yielded) = crate::action::park(self)?;
			if parked.is_empty() && !yielded {
				return Ok(());
			}
			let mut first_failure = None;
			for action in parked {
				// One failing action must not strand the rest of the drain: a
				// FLUSH to a session whose socket just died fails here while
				// the actions behind it belong to other, live sessions. The
				// failed session tears itself down through its own serve loop
				// (a DIAL failure is reported to the core inside the arm).
				if let Err(error) = crate::action::run(self, action).await {
					if first_failure.is_none() {
						first_failure = Some(error);
					}
				}
			}
			// This pass did work that can advance close-relevant state; wake
			// any parked close driver so it re-checks progress. An idle pass
			// returns above without signaling, which keeps two parked close
			// drivers from waking each other in an endless idle exchange.
			self.note_close_activity();
			if let Some(error) = first_failure {
				return Err(error);
			}
			if yielded {
				tokio::task::yield_now().await;
			}
		}
	}
}

impl Drop for HostShared {
	fn drop(&mut self) {
		// A loop-adopted Host's native handle dies with `pancake_driver_release`
		// (at the loop's own drop), never through `pancake_host_release`. The
		// wrapper dropping without an explicit close still closes the loop, so
		// the park task and the native loop cannot outlive every handle.
		if let Some(lp) = self.driver_loop.get_mut().take() {
			let raw = self.raw.replace(core::ptr::null_mut());
			if !raw.is_null() {
				crate::trace::detach_host(raw);
			}
			lp.close();
			return;
		}
		let raw = self.raw.get();
		if raw.is_null() {
			return;
		}
		// The release is refused inside a callback; park it for the next drain
		// rather than dropping it on the floor.
		if inside_turn() {
			self.raw.set(core::ptr::null_mut());
			PENDING_RELEASES.with(|list| {
				list.borrow_mut().push_back(PendingRelease::HostRaw {
					host: raw,
					context: self.context.take(),
				})
			});
		} else {
			crate::trace::detach_host(raw);
			let rc = unsafe { ffi::pancake_host_release(raw) };
			if crate::lifecycle::release_consumed(rc) {
				self.raw.set(core::ptr::null_mut());
			}
			if rc != sys::OK {
				if let Err(error) = check_host(rc) {
					crate::record_runtime_failure(crate::FailureLayer::Binding, "host-drop-release", error);
				}
				if !crate::lifecycle::release_consumed(rc) {
					let context = self.context.take();
					if let Some(context) = context {
						// The leaked raw Host still borrows this policy.
						core::mem::forget(context);
					}
				}
			}
		}
	}
}

/// The CapTP Host: one identity, one actor graph, one routing and redeem
/// authority, shared by every session minted against it. Owns `engine.Node`
/// (router half of Goblins mycapn; Host carries the product role — ADR-0079).
/// The cross-session machinery lives in the Zig core behind `libpancake_host`
/// (ADR-0072); this is the host-idiom residue over it — the session registry,
/// the vow table, the action drain that performs the I/O the host asks for
/// (dial, flush, settle, entropy), and the iroh redeem posture. Cloning shares
/// the same Host; the native host is released when the last clone (and last
/// session) drops.
#[derive(Clone)]
pub struct Host {
	shared: Rc<HostShared>,
}

/// Identity authority for a listening Host.
///
/// A seed restores the Host's durable identity without retaining an existing
/// session directory. Supplying a [`Host`] shares both its identity and its
/// live publications, sessions, and handoff router.
#[derive(Clone, Default)]
pub enum ListenerIdentity {
	#[default]
	Fresh,
	Seed([u8; 32]),
	Host(Host),
}

#[cfg(any(feature = "tcp", feature = "onion"))]
impl ListenerIdentity {
	pub(crate) fn into_host(self) -> Result<Host> {
		match self {
			Self::Fresh => Host::with_codec(Codec::Syrup),
			Self::Seed(seed) => Host::from_seed(seed),
			Self::Host(host) => Ok(host),
		}
	}
}

/// Construction knobs for [`Host`]. Codec, CapTP profile, feature offer, and
/// local-turn budget are mint-time; each session settles version and codec with
/// its partner, falling back to v1.0/Syrup when needed, and runs only the
/// intersection of the two offered feature sets. Selective session limits stay
/// on [`Host::set_session_limits`] (ADR-0082).
#[derive(Debug, Clone, Copy)]
pub struct HostOptions {
	pub codec: Codec,
	/// The CapTP profile this Host prefers; see
	/// [`CaptpVersion`](crate::CaptpVersion).
	pub captp_version: crate::CaptpVersion,
	/// Optional CapTP features this Host advertises.
	pub features: crate::FeatureSet,
	/// `0` = unbounded (default); nonzero caps local-turn amplification per drive
	/// (ADR-0076).
	pub local_turn_budget: u32,
}

impl Default for HostOptions {
	fn default() -> Self {
		Self {
			codec: Codec::Syrup,
			captp_version: crate::CaptpVersion::V1_0,
			features: crate::FeatureSet::FULL,
			local_turn_budget: 0,
		}
	}
}

impl HostOptions {
	pub fn with_codec(codec: Codec) -> Self {
		Self {
			codec,
			..Self::default()
		}
	}
}

impl Host {
	/// Close every session this host holds, then release the native Host and its
	/// hosted callbacks. Every clone becomes closed. When called by a hosted
	/// behavior, teardown is parked until that callback returns.
	///
	/// Closing a [`Session`](crate::Session) closes that one connection and
	/// nothing else, so this is how an application that shares one host across
	/// several sessions tears the whole thing down. The returned future is the
	/// completion barrier for Host-owned work and native state.
	pub async fn close(&self, pending: PendingWork) -> Result<()> {
		self.shared.close_host(pending)?;
		self.shared.wait_closed().await
	}

	#[cfg(test)]
	pub(crate) fn request_close(&self) {
		let _ = self.shared.close_host(PendingWork::Cancel);
	}

	// Test convenience over the fallible public constructor. Production callers
	// always receive initialization and entropy failures through `Result`.
	#[cfg(test)]
	pub(crate) fn new_host() -> Host {
		Host::with_codec(Codec::Syrup).expect("test Host initialization")
	}

	/// A fresh Host whose sessions all negotiate in `codec` — the codec is a
	/// Host property, so every session minted against a shared Host speaks
	/// the same grammar (`Codec::Syrup` is what [`RuntimeConfig::providers`](crate::RuntimeConfig::providers) and
	/// [`tcp::listen`](crate::tcp::listen) mint by default). Pass the Host to
	/// [`RuntimeConfig::adopt_host`](crate::RuntimeConfig::adopt_host),
	/// or to [`tcp::listen`](crate::tcp::listen) through
	/// [`tcp::ListenOptions`](crate::tcp::ListenOptions).
	pub fn with_codec(codec: Codec) -> Result<Host> {
		Host::with_options(HostOptions::with_codec(codec))
	}

	/// A fresh Host from [`HostOptions`] (codec + local-turn budget).
	pub fn with_options(options: HostOptions) -> Result<Host> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).map_err(|error| {
			Error::with_detail(sys::ERR_IO, format!("drawing the Host identity seed failed: {error}"))
		})?;
		Host::from_seed_with_options(seed, options)
	}

	/// A Host whose retained Ed25519 identity is reconstructed from `seed`.
	/// This keeps a keyed-TCP designator stable across a rebind while each
	/// session still receives a fresh signing key (ADR-0075, ADR-0097).
	/// `Codec::Syrup` is the default wire grammar.
	pub fn from_seed(seed: [u8; 32]) -> Result<Host> {
		Host::from_seed_with_options(seed, HostOptions::with_codec(Codec::Syrup))
	}

	/// [`from_seed`] with full [`HostOptions`] (codec + local-turn budget).
	pub fn from_seed_with_options(seed: [u8; 32], options: HostOptions) -> Result<Host> {
		Ok(Host {
			shared: HostShared::new(
				seed,
				options.codec,
				options.captp_version,
				options.features,
				options.local_turn_budget,
				None,
			)?,
		})
	}

	/// Selective session-limit knobs (ADR-0082). Pass `0` to leave a field
	/// unchanged. Affects peers minted after this call.
	pub fn set_session_limits(
		&self,
		max_frame_bytes: usize,
		queue_cap: usize,
		outbound_high_water_bytes: usize,
	) -> Result<()> {
		self.shared
			.set_session_limits(max_frame_bytes, queue_cap, outbound_high_water_bytes)
	}

	/// Claim every callerless failure retained by this Host's allocation
	/// context. This is the same queue a caller-supplied [`Context`] exposes;
	/// returned and close-barrier failures are not duplicated here.
	pub fn take_failures(&self) -> Result<Vec<crate::FailureEvent>> {
		let Some(context) = self.shared.retained_context() else {
			return Ok(Vec::new());
		};
		let mut failures = Vec::new();
		while let Some(failure) = context.next_failure()? {
			failures.push(failure);
		}
		Ok(failures)
	}

	/// Retain and select this Host's complete acceptable location. Later
	/// sessions advertise it regardless of their transport; existing sessions
	/// retain the locator their hello signed.
	pub fn set_advertised_locator(&self, locator: &Locator) -> Result<()> {
		self.shared.set_advertised_locator(locator)
	}

	/// Remove this Host's retained locator for `transport`.
	pub fn remove_advertised_locator(&self, transport: &str) -> Result<()> {
		self.shared.remove_advertised_locator(transport)
	}

	/// The canonical key designator (64 lowercase hex digits) for this host's
	/// identity seed — what a keyed-tcp locator names as its designator.
	pub fn designator(&self) -> Result<String> {
		let mut out = [0u8; 64];
		check_host(unsafe {
			ffi::pancake_host_designator_from_seed(
				self.shared.seed.as_ptr(),
				self.shared.seed.len(),
				out.as_mut_ptr(),
				out.len(),
			)
		})?;
		Ok(String::from_utf8_lossy(&out).into_owned())
	}

	// A Host in a caller-supplied allocation scope; the Host must be dropped
	// before the context. Test-only: the allocator dogfood drives it.
	#[cfg(all(test, feature = "tcp"))]
	pub(crate) fn new_in(context: &Context, codec: Codec) -> Result<Host> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).map_err(|_| Error::with_detail(sys::ERR_INTERNAL, "no OS entropy".to_string()))?;
		Ok(Host {
			shared: HostShared::new(
				seed,
				codec,
				crate::CaptpVersion::V1_0,
				crate::FeatureSet::FULL,
				0,
				Some(context),
			)?,
		})
	}

	pub(crate) fn from_shared(shared: Rc<HostShared>) -> Host {
		Host { shared }
	}

	pub(crate) fn shared(&self) -> Rc<HostShared> {
		Rc::clone(&self.shared)
	}

	/// Atomically install explicit byte-fed connectors on this Host. The Host
	/// retains one connector per transport symbol so later handoff redeem uses
	/// the same caller-selected channel authority.
	pub fn install_connectors(&self, connectors: &[crate::Connector]) -> Result<()> {
		self.shared.install_connectors(connectors)
	}

	/// Enliven a complete sturdyref without naming a session (ADR-0098): the
	/// host enlivens it over a live session it already dialed to that peer, or
	/// dials one itself through this host's own DIAL action and finishes when
	/// the dial reports. [`Session::enliven`] is the narrower verb — it never
	/// dials, and refuses a sturdyref for another peer.
	pub async fn enliven(&self, sturdyref: &str) -> Result<Ref> {
		self.shared.guard_handle()?;
		let mut vow: u64 = 0;
		check_host(unsafe {
			ffi::pancake_host_enliven(self.shared.raw(), sturdyref.as_ptr(), sturdyref.len(), &mut vow)
		})?;
		// The vow may be parked on a dial with no session of its own, which is
		// exactly the `None` session row the vow table already admits.
		// Host-level enliven is owned by the durable dedup cache, not a
		// GC-enabled arrival session (ADR-0063).
		self.shared.vow_minted(vow, None);
		let settled = self.shared.await_vow(vow);
		self.shared.kick_actions().await?;
		match settled.await? {
			Argument::Reference(reference) => Ok(reference),
			_ => Err(Error::broken(format!("{sturdyref:?} did not resolve to a capability"))),
		}
	}

	/// Atomically defer the current behavior turn onto a fresh resolver vow
	/// (off-turn settlement, ADR-0102). The returned [`Resolver`] is the
	/// one-shot settle authority; refusal publishes neither half of the pair.
	pub fn defer_turn(&self) -> Result<Resolver> {
		let turn = current_turn_for(Rc::as_ptr(&self.shared) as usize).ok_or_else(|| {
			Error::with_transport_detail(
				sys::ERR_INVALID_ARGUMENT,
				Some("defer_turn is a turn verb: call it inside a behavior of this host".into()),
			)
		})?;
		let mut resolver_id: u64 = 0;
		check_host(unsafe { ffi::pancake_host_turn_defer(turn, &mut resolver_id) })?;
		Ok(Resolver {
			shared: Rc::clone(&self.shared),
			id: Some(resolver_id),
		})
	}

	/// Host `make`'s behavior once and bind `name` as a Host-wide alias. Fetch
	/// lazily projects the actor onto a session, and a deposited gift keeps that
	/// exact actor when a recipient withdraws over its own exporter session
	/// (ADR-0009). `make` preserves the factory-shaped API for a `!Clone` `FnMut`;
	/// the Host invokes it once.
	pub fn publish_giftable(&self, name: &str, make: impl Fn() -> Behavior + 'static) -> Result<()> {
		self.shared.guard_handle()?;
		// A giftable is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		let mut behavior = make();
		let cell = self
			.shared
			.actor_cell(outcome_behavior(move |verb, args| behavior(verb, args)))?;
		let rc = unsafe {
			ffi::pancake_host_publish(
				self.shared.raw.get(),
				name.as_ptr(),
				name.len(),
				trampoline,
				cell as *mut core::ffi::c_void,
				ctx_free,
			)
		};
		if rc != sys::OK {
			let primary = host_refusal(rc, "host publication");
			let cleanup = unsafe { reclaim_refused_cell(rc, cell) };
			return Err(crate::retain_cleanup_failure(primary, cleanup));
		}
		self.shared.giftables.borrow_mut().insert(name.to_string(), cell);
		Ok(())
	}

	/// Publish `make`'s behavior under a freshly minted durable swiss name and
	/// return that name — the swiss to place in a sturdyref beside this host's
	/// own locator (ADR-0098). Unpredictable, never reassigned, structurally
	/// disjoint from every mutable alias, and removable only through
	/// [`Host::remove_durable`]. Entropy is drawn here, from the OS RNG.
	pub fn publish_durable(&self, make: impl Fn() -> Behavior + 'static) -> Result<String> {
		self.shared.guard_handle()?;
		let mut entropy = [0u8; 16];
		getrandom::fill(&mut entropy).map_err(|error| {
			Error::with_detail(sys::ERR_IO, format!("drawing durable swiss entropy failed: {error}"))
		})?;
		let mut behavior = make();
		let cell = self
			.shared
			.actor_cell(outcome_behavior(move |verb, args| behavior(verb, args)))?;
		let mut swiss = [0u8; 64];
		let rc = unsafe {
			ffi::pancake_host_publish_durable(
				self.shared.raw.get(),
				entropy.as_ptr(),
				entropy.len(),
				trampoline,
				cell as *mut core::ffi::c_void,
				ctx_free,
				swiss.as_mut_ptr(),
				swiss.len(),
			)
		};
		if rc <= 0 {
			let primary = host_refusal(rc, "durable host publication");
			let cleanup = unsafe { reclaim_refused_cell(rc, cell) };
			return Err(crate::retain_cleanup_failure(primary, cleanup));
		}
		let name = String::from_utf8_lossy(&swiss[..rc as usize]).into_owned();
		self.shared.giftables.borrow_mut().insert(name.clone(), cell);
		Ok(name)
	}

	/// Remove a minted durable publication (ADR-0098): the old sturdyref
	/// misses from now on, while capabilities already issued and deposited
	/// gifts keep the exact actor. Returns `false` when no such durable name
	/// exists.
	pub fn remove_durable(&self, swiss: &str) -> Result<bool> {
		self.shared.guard_handle()?;
		let rc = unsafe { ffi::pancake_host_remove_durable(self.shared.raw.get(), swiss.as_ptr(), swiss.len()) };
		if rc == sys::ERR_NOT_FOUND {
			return Ok(false);
		}
		check_host(rc)?;
		self.shared.giftables.borrow_mut().remove(swiss);
		Ok(true)
	}

	/// Remove the Host-wide alias `name` (alias-only, ADR-0096): a later fetch
	/// misses on every session, while capabilities already issued and deposited
	/// gifts keep the exact actor, whose behavior stays hosted for the Host's
	/// life. Returns `false` when no such alias exists; every other refusal is
	/// returned with its native diagnostic.
	pub fn unpublish_giftable(&self, name: &str) -> Result<bool> {
		self.shared.guard_handle()?;
		let rc = unsafe { ffi::pancake_host_unpublish(self.shared.raw.get(), name.as_ptr(), name.len()) };
		if rc == sys::ERR_NOT_FOUND {
			return Ok(false);
		}
		check_host(rc)?;
		// The alias is gone but the actor is not: the C row still owns the
		// behavior cell (freed at release), so only the name bookkeeping drops.
		self.shared.giftables.borrow_mut().remove(name);
		Ok(true)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::cell::Cell;

	struct DropProbe(Rc<Cell<bool>>);

	impl Drop for DropProbe {
		fn drop(&mut self) {
			self.0.set(true);
		}
	}

	// A hosted behavior may retain a Host clone. Native Host ownership of the
	// behavior then closes an Rc cycle; explicit close must release the native
	// actor row and break that cycle instead of waiting for HostShared::drop.
	#[test]
	fn close_breaks_a_hosted_behavior_host_cycle() {
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = Host::new_host();
			let captured_host = host.clone();
			let dropped = Rc::new(Cell::new(false));
			let dropped_by_behavior = Rc::clone(&dropped);
			host.publish_giftable("cycle", move || {
				let retained_host = captured_host.clone();
				let probe = DropProbe(Rc::clone(&dropped_by_behavior));
				Box::new(move |_verb, _args| {
					let _keep_host = &retained_host;
					let _keep_probe = &probe;
					Ok(Argument::Void)
				})
			})
			.unwrap();

			host.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(host.shared.raw.get().is_null());
			assert!(dropped.get(), "native Host release drops the captured behavior");
		});
	}

	#[test]
	fn closed_host_publication_verbs_return_their_refusal() {
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = Host::new_host();
			host.close(crate::PendingWork::Cancel).await.unwrap();

			let publish = host
				.publish_giftable("late", || Box::new(|_verb, _args| Ok(Argument::Void)))
				.unwrap_err();
			assert_eq!(publish.code(), sys::ERR_CLOSED);
			let durable = host
				.publish_durable(|| Box::new(|_verb, _args| Ok(Argument::Void)))
				.unwrap_err();
			assert_eq!(durable.code(), sys::ERR_CLOSED);
			assert_eq!(host.remove_durable("late").unwrap_err().code(), sys::ERR_CLOSED);
			assert_eq!(host.unpublish_giftable("late").unwrap_err().code(), sys::ERR_CLOSED);
		});
	}

	#[test]
	fn host_publication_results_cover_success_and_absence() {
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = Host::new_host();
			host.publish_giftable("alias", || Box::new(|_verb, _args| Ok(Argument::Void)))
				.unwrap();
			assert!(host.unpublish_giftable("alias").unwrap());
			assert!(!host.unpublish_giftable("alias").unwrap());

			let swiss = host
				.publish_durable(|| Box::new(|_verb, _args| Ok(Argument::Void)))
				.unwrap();
			assert!(host.remove_durable(&swiss).unwrap());
			assert!(!host.remove_durable(&swiss).unwrap());
			host.close(crate::PendingWork::Cancel).await.unwrap();
		});
	}

	#[test]
	fn cancel_dial_action_joins_its_ticketed_task() {
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = Host::new_host();
			let dropped = Rc::new(Cell::new(false));
			let task_dropped = Rc::clone(&dropped);
			assert!(host
				.shared
				.spawn_dial_task(1, move |_host| async move {
					let _probe = DropProbe(task_dropped);
					std::future::pending::<()>().await;
				})
				.unwrap());
			tokio::task::yield_now().await;

			host.shared.cancel_dial_task(1).await.unwrap();
			assert!(dropped.get(), "CANCEL_DIAL joins the ticketed DIAL future");
			host.close(crate::PendingWork::Cancel).await.unwrap();
		});
	}

	#[test]
	fn panicking_dial_task_reaches_the_host_close_barrier() {
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = Host::new_host();
			assert!(host
				.shared
				.spawn_dial_task(1, move |_host| async move {
					panic!("dial executor panic");
				})
				.unwrap());
			tokio::task::yield_now().await;
			tokio::task::yield_now().await;

			let error = host.close(crate::PendingWork::Cancel).await.unwrap_err();
			assert_eq!(error.code(), sys::ERR_INTERNAL);
			assert!(error
				.message()
				.is_some_and(|message| message.contains("dial executor panic")));
		});
	}

	#[test]
	fn panicking_actor_cell_drop_is_contained_and_diagnosed() {
		struct PanicOnDrop;
		impl Drop for PanicOnDrop {
			fn drop(&mut self) {
				panic!("actor cell destructor panic");
			}
		}

		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		let diagnostics = local.block_on(&runtime, async {
			let host = Host::new_host();
			host.publish_giftable("panicking-drop", move || {
				let guard = PanicOnDrop;
				Box::new(move |_verb, _args| {
					let _keep_captured = &guard;
					Ok(Argument::Void)
				})
			})
			.unwrap();
			host.close(crate::PendingWork::Cancel).await.unwrap();
			host.take_failures().unwrap()
		});

		assert!(diagnostics.iter().any(|failure| {
			failure.operation == "actor-cell.drop" && failure.primary_message == "actor cell destructor panic"
		}));
	}

	#[test]
	fn refused_publication_attaches_panicking_actor_cell_drop() {
		struct PanicOnDrop;
		impl Drop for PanicOnDrop {
			fn drop(&mut self) {
				panic!("refused actor cell destructor panic");
			}
		}

		let host = Host::new_host();
		let guard = PanicOnDrop;
		let cell = Box::into_raw(Box::new(ActorCell {
			behavior: RefCell::new(outcome_behavior(move |_verb, _args| {
				let _keep_captured = &guard;
				Ok(Argument::Void)
			})),
			context: host.shared.retained_context().unwrap(),
			diagnostic_id: host.shared.diagnostic_id(),
		}));
		let cleanup = unsafe { reclaim_refused_cell(sys::ERR_INVALID_ARGUMENT, cell) };
		let error = crate::retain_cleanup_failure(
			Error::with_detail(sys::ERR_INVALID_ARGUMENT, "publication refused".to_string()),
			cleanup,
		);

		assert_eq!(error.code(), sys::ERR_INVALID_ARGUMENT);
		assert_eq!(error.secondary_error_count(), 1);
		assert!(error.secondary_errors()[0]
			.message()
			.is_some_and(|message| message.contains("refused actor cell destructor panic")));
		// Rollback did not poison or consume the Host.
		host.publish_giftable("still-live", || Box::new(|_verb, _args| Ok(Argument::Void)))
			.unwrap();
	}

	#[test]
	fn close_waits_for_an_admitted_action_drain_before_native_release() {
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = Host::new_host();
			host.shared.schedule_kick().unwrap();
			assert_eq!(host.shared.owned_tasks.get(), 1);

			host.request_close();
			assert!(
				!host.shared.raw.get().is_null(),
				"close released native state beneath an admitted action drain"
			);
			host.close(crate::PendingWork::Cancel).await.unwrap();
			assert!(host.shared.raw.get().is_null());
			assert_eq!(host.shared.owned_tasks.get(), 0);
		});
	}

	// Host-level FINISH (ADR-0114): a negotiating session is admitted pending
	// work, so a finite grace expires and the close barrier reports its
	// timeout. The barrier retains that terminal outcome, so a repeated close
	// observes the same timeout instead of silently succeeding.
	#[test]
	fn a_finite_finish_close_reports_its_timeout_and_a_repeat_observes_it() {
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = Host::new_host();
			let pending = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:1");
			let owned = crate::uri::OwnedLocator::new(&pending).unwrap();
			let mut ptr = core::ptr::null_mut();
			check_host(unsafe {
				ffi::pancake_host_session_open_dialed_locator(host.shared.raw(), owned.borrow_view().unwrap(), &mut ptr)
			})
			.unwrap();

			let error = host
				.close(crate::PendingWork::Finish {
					grace: Some(std::time::Duration::from_millis(20)),
				})
				.await
				.expect_err("a negotiating session keeps the finite finish from settling in time");
			assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
			assert!(
				host.shared.raw.get().is_null(),
				"the timed-out finish still releases native state"
			);

			let again = host
				.close(crate::PendingWork::Cancel)
				.await
				.expect_err("a repeated close observes the recorded timeout");
			assert_eq!(again.kind(), crate::ErrorKind::TimedOut);
		});
	}

	#[test]
	fn close_barrier_retains_the_exact_first_failure() {
		let host = Host::new_host();
		let first = Error::with_detail(sys::ERR_IO, "close transport lost its wake descriptor".to_string());
		host.shared.fail_close(first.clone());
		host.shared.fail_close(Error::with_detail(
			sys::ERR_INTERNAL,
			"later cleanup failure".to_string(),
		));

		let observed = host
			.shared
			.close_host(crate::PendingWork::Cancel)
			.expect_err("a terminal close failure remains observable");
		assert_eq!(observed, first);
	}

	#[test]
	fn committed_close_can_retry_its_driver_spawn() {
		let host = Host::new_host();
		let first = host.shared.close_host(crate::PendingWork::Cancel);
		assert!(first.is_err(), "close outside a LocalSet must refuse its driver spawn");
		assert_eq!(host.shared.close_barrier.get(), CloseBarrierState::Running);
		assert!(!host.shared.close_task_started.get());

		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.expect("current-thread runtime");
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			host.close(crate::PendingWork::Cancel).await.unwrap();
		});
		assert!(host.shared.raw.get().is_null());
	}

	#[test]
	fn action_kick_without_a_local_set_reports_admission_failure() {
		let host = Host::new_host();
		let error = host.shared.schedule_kick().unwrap_err();
		assert_eq!(error.kind(), crate::ErrorKind::Internal);
		assert_eq!(
			host.shared.owned_tasks.get(),
			0,
			"refused admission releases its task registration"
		);
	}

	// Public Host surfaces the ADR-0082 selective knobs (not only HostShared).
	#[test]
	fn set_session_limits_is_callable_on_host() {
		let host = Host::new_host();
		host.set_session_limits(0, 0, 0)
			.expect("0 leaves both fields unchanged");
		host.set_session_limits(64 * 1024, 0, 0)
			.expect("max_frame_bytes alone is accepted");
	}

	#[test]
	fn advertised_locator_lifecycle_is_callable_on_host() {
		let host = Host::new_host();
		let locator = Locator {
			transport: "tcp".to_string(),
			designator: "127.0.0.1:7441".to_string(),
			hints: Default::default(),
			hint_wire_form: crate::HintWireForm::Map,
		};
		host.set_advertised_locator(&locator)
			.expect("a complete locator is accepted");
		host.remove_advertised_locator("tcp")
			.expect("the published locator is removed");
	}

	#[test]
	fn host_options_carry_local_turn_budget() {
		let host = Host::with_options(HostOptions {
			codec: Codec::Syrup,
			local_turn_budget: 64,
			..Default::default()
		})
		.unwrap();
		host.set_session_limits(0, 0, 0).expect("minted host answers limits");
	}

	#[test]
	fn connector_installation_publishes_no_partial_batch() {
		let host = Host::new_host();
		let mixed = crate::Connector::new(
			&["new-good", ""],
			|_host: Host,
			 _locator: &Locator,
			 _redeem: bool,
			 _transport_options: Option<&[u8]>,
			 _timeout: Option<std::time::Duration>| {
				Box::pin(async { Err(Error::with_detail(sys::ERR_INTERNAL, "unused".to_string())) })
			},
		)
		.unwrap();
		assert!(host.install_connectors(&[mixed]).is_err());
		assert!(host.shared.connector("new-good").is_none());

		let good = crate::Connector::new(
			&["new-good"],
			|_host: Host,
			 _locator: &Locator,
			 _redeem: bool,
			 _transport_options: Option<&[u8]>,
			 _timeout: Option<std::time::Duration>| {
				Box::pin(async { Err(Error::with_detail(sys::ERR_INTERNAL, "unused".to_string())) })
			},
		)
		.unwrap();
		host.install_connectors(&[good]).unwrap();
		assert!(host.shared.connector("new-good").is_some());
	}
}

/// The settle authority of a resolver pair (off-turn settlement, ADR-0102),
/// minted while [`Host::defer_turn`] atomically defers a behavior's answer.
/// The behavior hands the resolver to whatever completes the work, and the
/// completion settles it from the host's thread.
/// A successful settle consumes its native authority; a refused conversion or
/// native call leaves the resolver retryable. A deferred settle carries plain
/// data only — a value that names a capability is refused, and an answer that
/// carries authority forwards to a send instead.
pub struct Resolver {
	shared: Rc<HostShared>,
	id: Option<u64>,
}

impl Resolver {
	fn live_id(&self) -> Result<u64> {
		self.id.ok_or_else(|| {
			Error::with_transport_detail(sys::ERR_INVALID_ARGUMENT, Some("resolver already settled".into()))
		})
	}

	/// Settle the deferred answer fulfilled with a capability-free `value`.
	/// Top-level: refused inside a behavior callback; the settle pumps the
	/// sessions the deferred answers dirtied. A refused conversion or native
	/// settle leaves this resolver live so the caller can retry or break it.
	pub fn fulfill(&mut self, value: &Argument) -> Result<()> {
		let id = self.live_id()?;
		let mut arena = crate::SendArena::default();
		let c_value = arena.one(value)?;
		check_host(unsafe { ffi::pancake_host_resolver_fulfill(self.shared.raw.get(), id, &c_value) })?;
		self.id = None;
		// A settle can advance a FINISH close; wake any parked close driver.
		self.shared.note_close_activity();
		self.shared.schedule_kick()?;
		Ok(())
	}

	/// Settle the deferred answer broken with the worker's own words. The
	/// same top-level, one-shot contract as [`Resolver::fulfill`].
	pub fn break_with(&mut self, reason: &str) -> Result<()> {
		let id = self.live_id()?;
		check_host(unsafe {
			ffi::pancake_host_resolver_break(self.shared.raw.get(), id, reason.as_ptr(), reason.len())
		})?;
		self.id = None;
		// A settle can advance a FINISH close; wake any parked close driver.
		self.shared.note_close_activity();
		self.shared.schedule_kick()?;
		Ok(())
	}
}
