//! The CapTP [`Host`] — multi-session CapTP product over the byte-fed host archive
//! (`libglowcap_host`, ADR-0072). It owns `engine.Node` (the sans-io handoff
//! router). Goblins' `mycapn` is two roles: product maps to Host, router tables map to
//! `engine.Node` — never a single-type equation (ADR-0079). The `GlowcapHost`
//! owns every decision: the retained identity, session directory,
//! routing, transparent three-party redemption, and the gifter half's
//! origination. This package owns only what the embedder contract leaves to the
//! binding: `host.rs` is the shared state aggregate, `public.rs` is the Host
//! surface, `vows.rs` owns binding-side observation, `progress.rs` owns the
//! action-drain schedule, and `lifecycle.rs` owns terminal retirement. Action
//! decode + execute (`pop` / `run`) live in `action.rs`; the pump lives in
//! `pump.rs`; the dial executor lives in `dial.rs`. [`Session`] lives in
//! `session.rs`.
//!
//! Threading model: everything runs on one Tokio `LocalSet`. Native callers
//! drive it with a current-thread runtime; browser callers use their executor.
//! Tasks yield only at `.await` and no `glowcap_host_*` call contains one, so
//! a verb-plus-register-plus-kick sequence is naturally atomic with no lock
//! and no progress semaphore. The one discipline rule that replaces a lock: no
//! `RefCell` borrow is held across an FFI call that can fire the behavior
//! trampoline (`glowcap_host_session_feed_bytes`, `glowcap_host_dialed`,
//! `glowcap_host_provide_gift_id`) — take, drop,
//! call.

use crate::execution::monotonic_ms;
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::rc::{Rc, Weak};
use std::time::Duration;

use tokio::sync::{Notify, oneshot};
use tokio::task::JoinHandle;

use crate::PendingWork;
use crate::Ref;
use crate::session_shared::SessionShared;
use crate::sys::host as ffi;
use crate::trampoline::{
	ActorCell, InternalBehavior, ctx_free, current_turn_for, inside_turn, outcome_behavior, register_actor_cell,
	trampoline,
};
use crate::uri::OwnedLocator;
use crate::{Argument, Behavior, Codec, Context, ContextInner, Error, Locator, Result, sys};

mod application;
mod lifecycle;
#[cfg(all(target_arch = "wasm32", feature = "browser"))]
pub(crate) use lifecycle::OwnedTaskRegistration;
#[cfg(not(target_arch = "wasm32"))]
mod loop_teardown;
mod progress;
mod public;
mod vows;

use lifecycle::CloseBarrierState;
use vows::VowTable;

pub use public::{Host, HostOptions, ListenerIdentity, Resolver, SessionLimitOptions};

/// Every connection's maximum admissible frame; mirrors
/// `GLOWCAP_DEFAULT_FRAME_CAP`.
const HOST_FRAME_CAP: usize = sys::DEFAULT_FRAME_CAP;

/// Cap on stored outcomes whose vow is never awaited, so the store cannot grow
/// without bound; the oldest un-awaited outcome is evicted at the cap.
const MAX_UNOBSERVED_OUTCOMES: usize = crate::abi_constants::BINDING_UNOBSERVED_OUTCOME_CAP;

pub(crate) fn close_result(code: i32) -> Result<()> {
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

pub(crate) fn host_refusal(code: i32, operation: &str) -> Error {
	match check_host(code) {
		Err(error) => error,
		Ok(()) => Error::with_detail(
			sys::ERR_INTERNAL,
			format!("{operation} returned success without publishing its result"),
		),
	}
}

crate::error_slot::error_slot!(
	/// Like the core `check`, but for `glowcap_host_*` calls: snapshot the host
	/// family's own thread-local last-error rather than the unrelated ocapn one.
	pub(crate) fn check_host;
	/// The calling thread's last `glowcap_host_*` error message, read from the
	/// driver archive's own slot (never the ocapn family's).
	pub(crate) fn host_last_error;
	ffi::glowcap_host_last_error
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

/// The binding half of one CapTP Host: the raw `GlowcapHost`, the CapTP session
/// registry, the vow table, and the redeem posture, shared behind an `Rc` by
/// the public [`Host`] and every [`SessionShared`], and that sharing mechanically
/// enforces the header's "release the host always after its CapTP sessions" (the
/// host pointer cannot be released while any session wrapper lives).
pub(crate) struct HostShared {
	applications: application::States,
	raw: Cell<*mut ffi::GlowcapHost>,
	/// Binding-local close barrier coordination. Native Host lifecycle remains
	/// authoritative; `Failed` retains the raw handle for diagnosis and a final
	/// Drop attempt rather than pretending release succeeded.
	close_barrier: Cell<CloseBarrierState>,
	/// Exact first failure behind `CloseBarrierState::Failed`. The state remains
	/// `Copy` for cheap barrier checks while this owns the diagnostic payload.
	close_failure: RefCell<Option<Error>>,
	// Every live CapTP session shell by its GlowcapHostSession address, so a FLUSH
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
	dial_tasks: RefCell<HashMap<(u64, usize), JoinHandle<()>>>,
	close_task_started: Cell<bool>,
	// The binding-side table the drain's SETTLE/FAIL arms settle.
	vows: VowTable,
	// Finalizer-reclaimed Host reference ids. A reference may be homed on a
	// sibling session and outlive the session that delivered it.
	pub(crate) gc_pending: RefCell<VecDeque<u64>>,
	// Finalizer-reclaimed public Host-vow ids. Separate from capability ids:
	// both are opaque u64 values in distinct native namespaces.
	pub(crate) vow_gc_pending: RefCell<VecDeque<u64>>,
	// Deferred replies abandoned by their sole Rust owner. Drained off-turn.
	pub(crate) resolver_abandon_pending: RefCell<VecDeque<u64>>,
	// The first failure from a detached Host-progress task. Such a task has no
	// caller result; the next verb head takes this exact typed cause instead.
	background_failure: RefCell<Option<Error>>,
	// Session-local retirement failures belong to shutdown, not the next
	// unrelated verb. The Host retains them through its owned-task barrier.
	retirement_failure: RefCell<Option<Error>>,
	/// The 32-byte Ed25519 identity seed this host was minted with — retained
	/// so a keyed-tcp listener can derive its public designator without a
	/// second identity (ADR-0075).
	seed: [u8; 32],
	// A Host allocated in a caller Context borrows that native policy. Rc makes
	// the order structural, including teardown parked from a callback.
	context: Option<Rc<ContextInner>>,
	/// Stable identity in the retained Context's diagnostic namespace.
	diagnostic_id: u64,
	// The native loop this Host was adopted over (ADR-0112), or `None` for a
	// byte-fed Host this binding pumps itself. On a loop-adopted Host the loop
	// is the one action drain and the one release authority: kicks become loop
	// steps, no `glowcap_host_pump_drain` runs here, and teardown routes
	// through `LoopShared::close` (which releases the wrapped native Host).
	#[cfg(not(target_arch = "wasm32"))]
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
		crate::require_archive_fingerprint(
			"host",
			unsafe { ffi::glowcap_host_archive_fingerprint() },
			crate::sys::HOST_ARCHIVE_FINGERPRINT,
		)?;
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
			ffi::glowcap_host_designator_from_seed(seed.as_ptr(), seed.len(), designator.as_mut_ptr(), designator.len())
		})?;
		let context = match context {
			Some(context) => context.retain_inner(),
			None => Rc::new(ContextInner::new()?),
		};
		let mut raw: *mut ffi::GlowcapHost = core::ptr::null_mut();
		check_host(unsafe {
			ffi::glowcap_host_new_in(
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
		if let Err(error) = check_host(unsafe { ffi::glowcap_host_diagnostic_id(raw, &mut diagnostic_id) }) {
			let cleanup_rc = unsafe { ffi::glowcap_host_release(raw) };
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
			applications: Default::default(),
			raw: Cell::new(raw),
			close_barrier: Cell::new(CloseBarrierState::Idle),
			close_failure: RefCell::new(None),
			sessions: RefCell::new(HashMap::new()),
			owned_tasks: Cell::new(0),
			release_notify: Notify::new(),
			activity: Notify::new(),
			dial_tasks: RefCell::new(HashMap::new()),
			close_task_started: Cell::new(false),
			vows: VowTable::new(),
			gc_pending: RefCell::new(VecDeque::new()),
			vow_gc_pending: RefCell::new(VecDeque::new()),
			resolver_abandon_pending: RefCell::new(VecDeque::new()),
			background_failure: RefCell::new(None),
			retirement_failure: RefCell::new(None),
			seed,
			context: Some(context),
			diagnostic_id,
			#[cfg(not(target_arch = "wasm32"))]
			driver_loop: RefCell::new(None),
			connectors: RefCell::new(HashMap::new()),
		}))
	}

	/// Adopt the native Host a `DriverLoop` minted (ADR-0112): the wrapper
	/// every application verb, publish trampoline, and vow settle works on,
	/// while the loop stays the one action drain and the one release
	/// authority. `seed` is the identity half of the loop's 64-byte seed, so
	/// `Host::designator` answers the same as on a byte-fed Host.
	#[cfg(not(target_arch = "wasm32"))]
	pub(crate) fn adopt_loop(
		raw: *mut ffi::GlowcapHost,
		seed: [u8; 32],
		driver_loop: Rc<crate::driver_loop::LoopShared>,
	) -> Result<Rc<HostShared>> {
		let mut designator = [0u8; 64];
		check_host(unsafe {
			ffi::glowcap_host_designator_from_seed(seed.as_ptr(), seed.len(), designator.as_mut_ptr(), designator.len())
		})?;
		let context = driver_loop.retained_context();
		let mut diagnostic_id = 0;
		check_host(unsafe { ffi::glowcap_host_diagnostic_id(raw, &mut diagnostic_id) })?;
		if let Some(context) = context.as_ref() {
			crate::trace::attach_host(
				raw,
				String::from_utf8_lossy(&designator).into_owned(),
				Rc::clone(context),
				diagnostic_id,
			);
		}
		Ok(Rc::new(HostShared {
			applications: Default::default(),
			raw: Cell::new(raw),
			close_barrier: Cell::new(CloseBarrierState::Idle),
			close_failure: RefCell::new(None),
			sessions: RefCell::new(HashMap::new()),
			owned_tasks: Cell::new(0),
			release_notify: Notify::new(),
			activity: Notify::new(),
			dial_tasks: RefCell::new(HashMap::new()),
			close_task_started: Cell::new(false),
			vows: VowTable::new(),
			gc_pending: RefCell::new(VecDeque::new()),
			vow_gc_pending: RefCell::new(VecDeque::new()),
			resolver_abandon_pending: RefCell::new(VecDeque::new()),
			background_failure: RefCell::new(None),
			retirement_failure: RefCell::new(None),
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
	#[cfg(not(target_arch = "wasm32"))]
	pub(crate) fn driver_loop(&self) -> Option<Rc<crate::driver_loop::LoopShared>> {
		self.driver_loop.borrow().clone()
	}

	/// Establish this Host's one native runtime owner before its first network
	/// operation. Existing loop-backed Hosts reuse their loop; a byte-fed Host
	/// transfers transactionally through the C ABI.
	#[cfg(not(target_arch = "wasm32"))]
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
	/// loop's own `glowcap_driver_session_release` for a loop-minted session
	/// (which also drops queued events naming it), `glowcap_host_session_release`
	/// for a byte-fed one. A loop already released frees its sessions itself,
	/// so the loop arm is a no-op then.
	pub(crate) fn release_native_session(&self, session: *mut ffi::GlowcapHostSession) -> Result<()> {
		self.release_session_handle(session)?;
		// A released session retires its pending close work, so a driver
		// parked on host activity must re-check progress.
		self.note_close_activity();
		Ok(())
	}

	fn release_session_handle(&self, session: *mut ffi::GlowcapHostSession) -> Result<()> {
		#[cfg(not(target_arch = "wasm32"))]
		if let Some(lp) = self.driver_loop() {
			return lp.native_session_release(session);
		}
		check_host(unsafe { ffi::glowcap_host_session_release(session) })
	}

	/// The raw `GlowcapHost` handle.
	pub(crate) fn raw(&self) -> *mut ffi::GlowcapHost {
		self.raw.get()
	}

	#[cfg(not(target_arch = "wasm32"))]
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
			registration: Cell::new(core::ptr::null()),
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

	pub(crate) fn set_advertised_locator(&self, locator: &Locator) -> Result<()> {
		self.guard_handle()?;
		let owned = OwnedLocator::new(locator)?;
		check_host(unsafe { ffi::glowcap_host_set_advertised_locator(self.raw.get(), owned.borrow_view()?) })
	}

	pub(crate) fn remove_advertised_locator(&self, transport: &str) -> Result<()> {
		self.guard_handle()?;
		check_host(unsafe {
			ffi::glowcap_host_remove_advertised_locator(self.raw.get(), transport.as_ptr(), transport.len())
		})
	}

	/// Selective session-limit knobs (ADR-0124). Pass `0` to leave a field
	/// unchanged. Affects peers minted after this call.
	pub(crate) fn set_session_limits(&self, options: SessionLimitOptions) -> Result<()> {
		self.guard_handle()?;
		let raw = ffi::GlowcapSessionLimitOptions {
			abi_version: sys::SESSION_LIMIT_OPTIONS_ABI_VERSION,
			struct_size: core::mem::size_of::<ffi::GlowcapSessionLimitOptions>(),
			max_frame_bytes: options.max_frame_bytes,
			queue_cap: options.queue_cap,
			outbound_high_water_bytes: options.outbound_high_water_bytes,
			max_retained_sent_answer_bytes: usize::try_from(options.max_retained_sent_answer_bytes)
				.expect("u32 always fits usize on supported targets"),
		};
		check_host(unsafe { ffi::glowcap_host_set_session_limits(self.raw.get(), &raw) })
	}

	// ── Session registry ────────────────────────────────────────────────────

	/// Track a live CapTP session shell by its GlowcapHostSession address; the
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
	pub(crate) fn session_for_ptr(&self, ptr: *mut ffi::GlowcapHostSession) -> Option<Rc<SessionShared>> {
		self.sessions.borrow().get(&(ptr as usize)).cloned()
	}

	fn reference_exporter(&self, wire: &sys::GlowcapReference) -> Result<*mut ffi::GlowcapHostSession> {
		#[cfg(not(target_arch = "wasm32"))]
		if let Some(lp) = self.driver_loop() {
			return Ok(lp.claim_reference_exporter(wire)?.unwrap_or(core::ptr::null_mut()));
		}
		let mut out = core::ptr::null_mut();
		check_host(unsafe { ffi::glowcap_host_reference_exporter(self.raw.get(), wire, &mut out) })?;
		Ok(out)
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
		let out = self.reference_exporter(&wire)?;
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
		#[cfg(not(target_arch = "wasm32"))]
		if let Some(lp) = self.driver_loop() {
			let shared = SessionShared::new_loop(out, Rc::clone(self), lp);
			shared.retain_by_host();
			shared.spawn_serve();
			return Ok(Some(shared));
		}
		Ok(None)
	}
}

#[cfg(test)]
#[path = "host/tests.rs"]
mod tests;
