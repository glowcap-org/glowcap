//! The CapTP [`Host`] — multi-session CapTP product over the byte-fed host archive
//! (`libpancake_host`, ADR-0072). It owns `engine.Node` (the sans-io handoff
//! router). Goblins' `mycapn` is two roles: endpoint ≈ Host, router tables ≈
//! `engine.Node` — never a single-type equation (ADR-0079). The `PancakeHost`
//! owns every decision: the retained identity, session directory,
//! routing, transparent three-party redemption, and the gifter half's
//! origination. What lives here is only what the embedder contract leaves to
//! the binding: the host handle, the conn-pointer to session registry the
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
//! trampoline (`conn_feed_bytes`, `dialed`, `provide_gift_id`) — take, drop,
//! call.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::rc::{Rc, Weak};

use tokio::sync::oneshot;

use crate::dial::Reachability;
use crate::session_shared::SessionShared;
use crate::sys::host as ffi;
use crate::trampoline::{
	ctx_free, current_turn_for, inside_turn, outcome_behavior, reclaim_refused_cell, trampoline,
	ActorCell,
};
use crate::Ref;
use crate::{sys, Argument, Behavior, Codec, Context, Error, Result};

/// Every connection's maximum admissible frame; mirrors
/// `PANCAKE_DEFAULT_FRAME_CAP`.
const HOST_FRAME_CAP: usize = sys::DEFAULT_FRAME_CAP;

/// Cap on stored outcomes whose vow is never awaited, so the store cannot grow
/// without bound; the oldest un-awaited outcome is evicted at the cap.
const MAX_UNOBSERVED_OUTCOMES: usize = 1024;

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
pub(crate) fn try_spawn_local<F>(future: F)
where
	F: std::future::Future<Output = ()> + 'static,
{
	let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
		tokio::task::spawn_local(future);
	}));
}

// A release refused inside a behavior callback parks here — a `Drop` must
// never be a silent no-op-with-last-error — and the drain honors it once the
// enclosing verb has unwound. A parked connection release keeps its host alive
// (the `Rc`) so the release order stays conn-before-host.
enum PendingRelease {
	Session {
		conn: *mut ffi::PancakeHostSession,
		host: Rc<HostShared>,
	},
	/// Explicit terminal close. The shared owner lets the drain release any
	/// already-parked sessions before it releases the native Host.
	HostShared(Rc<HostShared>),
	/// Last-owner drop inside a callback. No Session can still retain the Host
	/// in this arm, so only the raw handle remains.
	HostRaw(*mut ffi::PancakeHost),
}

thread_local! {
	static PENDING_RELEASES: RefCell<Vec<PendingRelease>> = const { RefCell::new(Vec::new()) };
}

/// Park a connection release that a callback frame refused.
pub(crate) fn park_session_release(conn: *mut ffi::PancakeHostSession, host: Rc<HostShared>) {
	PENDING_RELEASES.with(|list| {
		list.borrow_mut()
			.push(PendingRelease::Session { conn, host })
	});
}

/// Test observability: how many releases are parked on this thread, so a test
/// can assert a mid-turn close's parked release actually ran after the turn.
#[cfg(test)]
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
		let Some(pending) = PENDING_RELEASES.with(|list| list.borrow_mut().pop()) else {
			return;
		};
		match pending {
			PendingRelease::Session { conn, host } => {
				let _ = unsafe { ffi::pancake_host_session_release(conn) };
				drop(host);
			}
			// Deferred HostShared release records a failure in its terminal
			// state and retains the raw handle; a later verb reports that code.
			// HostRaw has no surviving owner to hold such state.
			PendingRelease::HostShared(host) => host.release_native(),
			PendingRelease::HostRaw(host) => {
				crate::trace::detach_host(host);
				let _ = unsafe { ffi::pancake_host_release(host) };
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

// A host vow's row: its home session plus its pending state.
struct VowRow {
	/// Home CapTP session at mint (weak so the vow table cannot pin a session).
	/// FAIL uses it to classify disconnect breaks as CLOSED.
	session: Option<Weak<SessionShared>>,
	state: VowState,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HostState {
	Open,
	Closing,
	Closed,
	Failed(i32),
}

/// The binding half of one CapTP Host: the raw `PancakeHost`, the CapTP session
/// registry, the vow table, and the redeem posture, shared behind an `Rc` by
/// the public [`Host`] and every [`SessionShared`] — which is what mechanically
/// enforces the header's "release the host always after its CapTP sessions" (the
/// host pointer cannot be released while any session wrapper lives).
pub(crate) struct HostShared {
	raw: Cell<*mut ffi::PancakeHost>,
	/// Terminal lifecycle. `Closing` begins at close intent, before a callback
	/// can defer native teardown; `Failed` retains the raw handle for diagnosis
	/// and a final Drop attempt rather than pretending release succeeded.
	state: Cell<HostState>,
	// Every live CapTP session shell by its PancakeHostSession address, so a FLUSH
	// action routes to the transport that owns the bytes and a dialed exporter
	// stays reachable for teardown. A session unregisters at close, which is
	// what breaks the Rc cycle between host and session state. `action::run`
	// reads it for FLUSH / CLOSE.
	pub(crate) sessions: RefCell<HashMap<usize, Rc<SessionShared>>>,
	// The vow table the drain's SETTLE/FAIL arms settle.
	vows: RefCell<HashMap<u64, VowRow>>,
	// Finalizer-reclaimed Host reference ids. A reference may be homed on a
	// sibling session and outlive the session that delivered it.
	pub(crate) gc_pending: RefCell<Vec<u64>>,
	// Opaque Host capability id -> hosted cell. Actors outlive the Port that
	// first projected them, so every sibling Session resolves through this one
	// Host-owned index. The core owns each cell and runs ctx_free at Host release.
	pub(crate) hosted: RefCell<HashMap<u64, *const ActorCell>>,
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	unobserved: RefCell<VecDeque<u64>>,
	// The iroh reachability posture this host uses to redeem a *hint-less*
	// handoff give — one whose exporter location names the exporter by node id
	// alone. Defaults to `Discovery` (n0 relays + DNS/pkarr, the maximal-reach
	// choice); a relay-policy deployment lowers it. A hinted give always dials
	// `Direct` and ignores this.
	redeem_reachability: Cell<Reachability>,
	// The keyed-relay rendezvous mapping (ADR-0088): the peer's key designator
	// to the relay rendezvous WebSocket URL that bridges onto its held inbound
	// socket — the keyed-relay sibling of `redeem_reachability`. None until
	// configured; a keyed-relay dial refuses without it.
	rendezvous_url: RefCell<Option<Rc<dyn Fn(&str) -> String>>>,
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
		getrandom::fill(&mut seed_with_root[32..]).expect("the OS RNG provides a session-key root");

		let mut raw: *mut ffi::PancakeHost = core::ptr::null_mut();
		check_host(match context {
			Some(context) => unsafe {
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
			},
			None => unsafe {
				ffi::pancake_host_new(
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
			},
		})?;
		// The host's own key designator, which is what a partner names it by:
		// the live trace reports it as this host's endpoint so one peer stays
		// one node in a feed several producers share.
		let mut designator = [0u8; 64];
		check_host(unsafe {
			ffi::pancake_host_designator_from_seed(
				seed.as_ptr(),
				seed.len(),
				designator.as_mut_ptr(),
				designator.len(),
			)
		})?;
		crate::trace::attach_host(raw, String::from_utf8_lossy(&designator).into_owned());
		Ok(Rc::new(HostShared {
			raw: Cell::new(raw),
			state: Cell::new(HostState::Open),
			sessions: RefCell::new(HashMap::new()),
			vows: RefCell::new(HashMap::new()),
			gc_pending: RefCell::new(Vec::new()),
			hosted: RefCell::new(HashMap::new()),
			unobserved: RefCell::new(VecDeque::new()),
			redeem_reachability: Cell::new(Reachability::REDEEM_DEFAULT),
			rendezvous_url: RefCell::new(None),
			giftables: RefCell::new(HashMap::new()),
			seed,
		}))
	}

	/// The raw `PancakeHost` handle.
	pub(crate) fn raw(&self) -> *mut ffi::PancakeHost {
		self.raw.get()
	}

	pub(crate) fn guard_open(&self) -> Result<()> {
		match self.state.get() {
			HostState::Open => Ok(()),
			HostState::Closing | HostState::Closed => Err(Error::with_detail(
				sys::ERR_CLOSED,
				"host closed".to_string(),
			)),
			HostState::Failed(code) => Err(Error::with_detail(
				code,
				"native host release failed".to_string(),
			)),
		}
	}

	pub(crate) fn closing(&self) -> bool {
		self.state.get() != HostState::Open
	}

	// Read by the iroh dial executor alone: a hint-less iroh give resolves
	// under this posture, and no other transport consults it.
	#[cfg(feature = "iroh")]
	pub(crate) fn redeem_reachability(&self) -> Reachability {
		self.redeem_reachability.get()
	}

	// Read by the rendezvous dial executor alone: the URL a keyed-relay dial
	// opens for `designator`, or None when the host was never configured.
	#[cfg(feature = "rendezvous")]
	pub(crate) fn rendezvous_url_of(&self, designator: &str) -> Option<String> {
		self.rendezvous_url.borrow().as_ref().map(|f| f(designator))
	}

	/// Record the designator this host's dials sign as their own dialable
	/// address (a host that also listens); `listen`/`listen_iroh` set it to the
	/// bound address so a partner's crossed-hellos table can recognize this host.
	pub(crate) fn set_self_designator(&self, designator: &str) -> Result<()> {
		self.guard_open()?;
		check_host(unsafe {
			ffi::pancake_host_set_self_designator(
				self.raw.get(),
				designator.as_ptr(),
				designator.len(),
			)
		})
	}

	pub(crate) fn set_advertised_locator_record(&self, locator: &[u8]) -> Result<()> {
		self.guard_open()?;
		check_host(unsafe {
			ffi::pancake_host_set_advertised_locator(
				self.raw.get(),
				locator.as_ptr(),
				locator.len(),
			)
		})
	}

	pub(crate) fn set_advertised_locator(
		&self,
		transport: &str,
		designator: &str,
		direct_addresses: &str,
	) -> Result<()> {
		let locator = crate::uri::encode_peer_locator_bytes(
			transport.as_bytes(),
			designator.as_bytes(),
			direct_addresses.as_bytes(),
		)?;
		self.set_advertised_locator_record(&locator)
	}

	pub(crate) fn remove_advertised_locator(&self, transport: &str) -> Result<()> {
		self.guard_open()?;
		check_host(unsafe {
			ffi::pancake_host_remove_advertised_locator(
				self.raw.get(),
				transport.as_ptr(),
				transport.len(),
			)
		})
	}

	/// Selective session-limit knobs (ADR-0082). Pass `0` to leave a field
	/// unchanged. Affects peers minted after this call.
	pub(crate) fn set_session_limits(
		&self,
		max_frame_bytes: usize,
		queue_cap: usize,
	) -> Result<()> {
		self.guard_open()?;
		check_host(unsafe {
			ffi::pancake_host_set_session_limits(self.raw.get(), max_frame_bytes, queue_cap)
		})
	}

	// ── Session registry ────────────────────────────────────────────────────

	/// Track a live CapTP session shell by its PancakeHostSession address; the
	/// `SessionShared` constructor calls it.
	pub(crate) fn register_session(&self, key: usize, conn: Rc<SessionShared>) {
		debug_assert_eq!(self.state.get(), HostState::Open);
		self.sessions.borrow_mut().insert(key, conn);
	}

	/// Stop tracking a released CapTP session shell.
	pub(crate) fn unregister_session(&self, key: usize) {
		self.sessions.borrow_mut().remove(&key);
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
	/// itself: the token carries which exporter connection hosts it, so this
	/// never watches for a dial to complete. It is therefore right with several
	/// redeems in flight at once, and it still names the exporter when the
	/// redeem reused a connection an earlier one already dialed, where no fresh
	/// dial happened at all. `Session::send_redeeming` calls it on the reply it
	/// just awaited.
	pub(crate) fn exporter_for(&self, capability: &Ref) -> Result<Option<Rc<SessionShared>>> {
		self.guard_open()?;
		let wire = capability.to_sys()?;
		let mut out: *mut ffi::PancakeHostSession = core::ptr::null_mut();
		// The handle comes back host-owned and borrowed: it lives with the
		// exporter session, and this side never releases it.
		check_host(unsafe {
			ffi::pancake_host_reference_exporter(self.raw.get(), &wire, &mut out)
		})?;
		if out.is_null() {
			return Ok(None);
		}
		Ok(self.sessions.borrow().get(&(out as usize)).cloned())
	}

	/// Close every session this host holds — the ones an application opened
	/// and the ones the host dialed for redeems alike. Each close releases
	/// that session's handle and unregisters it, which is also what lets the
	/// host go: the map holds an `Rc` to each session and each session holds
	/// one back, so an emptied map is what breaks that cycle and lets
	/// `HostShared::drop` run.
	pub(crate) fn close_sessions(&self) {
		loop {
			let next = self.sessions.borrow().values().next().cloned();
			let Some(conn) = next else { return };
			conn.close_transport();
		}
	}

	/// Terminally release this Host. A callback cannot free the native Host
	/// whose actor cell is on its stack, so it parks one Host-owned transaction;
	/// the outer feed or local-run drain performs the same ordered teardown.
	pub(crate) fn close_host(self: &Rc<HostShared>) {
		if self.state.get() != HostState::Open {
			return;
		}
		self.state.set(HostState::Closing);
		if inside_turn() {
			PENDING_RELEASES.with(|list| {
				list.borrow_mut()
					.push(PendingRelease::HostShared(Rc::clone(self)))
			});
		} else {
			self.release_native();
		}
	}

	/// Release Session shells that unregistered while their callbacks were
	/// still on the stack. They are absent from `sessions`, but the native Host
	/// still owns them and must not be freed first.
	fn drain_parked_sessions(self: &Rc<HostShared>) {
		loop {
			let parked = PENDING_RELEASES.with(|list| {
				let mut list = list.borrow_mut();
				let index = list.iter().position(
					|item| matches!(item, PendingRelease::Session { host, .. } if Rc::ptr_eq(host, self)),
				);
				index.map(|index| list.swap_remove(index))
			});
			let Some(PendingRelease::Session { conn, host }) = parked else {
				return;
			};
			let _ = unsafe { ffi::pancake_host_session_release(conn) };
			drop(host);
		}
	}

	fn release_native(self: &Rc<HostShared>) {
		let raw = self.raw.get();
		if raw.is_null() {
			self.state.set(HostState::Closed);
			return;
		}
		self.drain_parked_sessions();
		self.close_sessions();
		crate::trace::detach_host(raw);
		let rc = unsafe { ffi::pancake_host_release(raw) };
		if rc != sys::OK {
			self.state.set(HostState::Failed(rc));
			return;
		}
		self.raw.set(core::ptr::null_mut());
		self.state.set(HostState::Closed);
		// Native release ran every ctx-free callback. These maps contain only
		// non-owning pointers and cannot retain stale lookup results afterward.
		self.hosted.borrow_mut().clear();
		self.giftables.borrow_mut().clear();
	}

	// ── The vow table ──────────────────────────────────────────────────────────

	/// Record a freshly minted vow so the drain can route its completion. Must
	/// run in the same synchronous block as the minting FFI call, so no drain
	/// can pop the completion first. `session` is the home CapTP session (FAIL
	/// classifies disconnect breaks as CLOSED when that session is closing).
	pub(crate) fn vow_minted(&self, vow: u64, session: Option<&Rc<SessionShared>>) {
		self.vows.borrow_mut().insert(
			vow,
			VowRow {
				session: session.map(Rc::downgrade),
				state: VowState::Minted,
			},
		);
	}

	/// Whether the vow's home session is closing — FAIL arms classify those
	/// breaks as `ERR_CLOSED`.
	pub(crate) fn vow_session_closing(&self, vow: u64) -> bool {
		self.vows
			.borrow()
			.get(&vow)
			.and_then(|row| row.session.as_ref())
			.and_then(Weak::upgrade)
			.is_some_and(|s| s.closing())
	}

	/// The vow's eventual outcome: the fulfilled wire value, or a typed
	/// rejection — `ErrorKind::Broken` for a partner break, `ErrorKind::Closed`
	/// when the settle was the disconnect's own break. Settles immediately
	/// from the recorded state when the outcome already landed.
	pub(crate) fn await_vow(
		self: &Rc<HostShared>,
		vow: u64,
	) -> impl std::future::Future<Output = Result<Argument>> {
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
	pub(crate) fn settle_vow(&self, vow: u64, outcome: Result<Argument>) {
		{
			let mut vows = self.vows.borrow_mut();
			let Some(row) = vows.get_mut(&vow) else {
				return; // an outcome nobody registered for
			};
			match std::mem::replace(&mut row.state, VowState::Minted) {
				VowState::Awaited(waiter) => {
					vows.remove(&vow);
					drop(vows);
					let _ = waiter.send(outcome);
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

	// ── The action drain (the one loop rule) ──────────────────────────────────

	/// Kick the action drain from a synchronous verb: schedule it as its own
	/// task on the `LocalSet`.
	pub(crate) fn schedule_kick(self: &Rc<HostShared>) {
		if inside_turn() || self.closing() || self.raw.get().is_null() {
			return;
		}
		let host = Rc::clone(self);
		try_spawn_local(async move {
			host.kick_actions().await;
		});
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
	pub(crate) async fn kick_actions(self: &Rc<HostShared>) {
		if inside_turn() || self.closing() || self.raw.get().is_null() {
			return;
		}
		drain_pending_releases();
		crate::gc::drain(self);
		loop {
			let parked = crate::action::park(self);
			if parked.is_empty() {
				return;
			}
			for action in parked {
				// One failing action must not strand the rest of the drain: a
				// FLUSH to a session whose socket just died fails here while
				// the actions behind it belong to other, live sessions. The
				// failed session tears itself down through its own serve loop
				// (a DIAL failure is reported to the core inside the arm).
				let _ = crate::action::run(self, action).await;
			}
		}
	}
}

impl Drop for HostShared {
	fn drop(&mut self) {
		let raw = self.raw.get();
		if raw.is_null() {
			return;
		}
		// The release is refused inside a callback; park it for the next drain
		// rather than dropping it on the floor.
		if inside_turn() {
			self.raw.set(core::ptr::null_mut());
			PENDING_RELEASES.with(|list| list.borrow_mut().push(PendingRelease::HostRaw(raw)));
		} else {
			crate::trace::detach_host(raw);
			let rc = unsafe { ffi::pancake_host_release(raw) };
			if rc == sys::OK {
				self.raw.set(core::ptr::null_mut());
			}
		}
	}
}

/// The CapTP Host: one identity, one actor graph, one routing and redeem
/// authority, shared by every session minted against it. Owns `engine.Node`
/// (router half of Goblins mycapn; the Host is the endpoint half — ADR-0079).
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
	/// several sessions tears the whole thing down. A session that made its own
	/// host (the ordinary [`connect`](crate::connect) with no host passed)
	/// calls this for you when it closes.
	pub fn close(&self) {
		self.shared.close_host();
	}

	// A fresh Host with a random retained identity, minted at the I/O boundary
	// (the sans-io core never generates entropy). The OS RNG failing is not a
	// recoverable condition, the same stance the Deno/Python nodes take.
	pub(crate) fn new_host() -> Host {
		Host::with_codec(Codec::Syrup)
	}

	/// A fresh Host whose sessions all negotiate in `codec` — the codec is a
	/// Host property, so every session minted against a shared Host speaks
	/// the same grammar (`Codec::Syrup` is what [`connect`](crate::connect) and
	/// [`listen`](crate::listen) mint by default). Pass the Host to
	/// [`connect`](crate::connect) as `Some(host)` or
	/// [`listen_with_host`](crate::listen_with_host).
	pub fn with_codec(codec: Codec) -> Host {
		Host::with_options(HostOptions::with_codec(codec))
	}

	/// A fresh Host from [`HostOptions`] (codec + local-turn budget).
	pub fn with_options(options: HostOptions) -> Host {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).expect("the OS RNG provides a Host identity seed");
		Host::from_seed_with_options(seed, options).expect("the allocator provides a Host")
	}

	/// A Host whose retained Ed25519 identity is reconstructed from `seed`.
	/// This keeps a keyed-TCP designator stable across a rebind while each
	/// connection still receives a fresh session key (ADR-0075, ADR-0097).
	/// `Codec::Syrup` is the default wire grammar.
	pub fn from_seed(seed: [u8; 32]) -> Result<Host> {
		Host::from_seed_with_codec(seed, Codec::Syrup)
	}

	/// [`from_seed`] with an explicit wire grammar.
	pub fn from_seed_with_codec(seed: [u8; 32], codec: Codec) -> Result<Host> {
		Host::from_seed_with_options(seed, HostOptions::with_codec(codec))
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
	pub fn set_session_limits(&self, max_frame_bytes: usize, queue_cap: usize) -> Result<()> {
		self.shared.set_session_limits(max_frame_bytes, queue_cap)
	}

	/// Retain and select this Host's complete acceptable location. Later
	/// sessions advertise it regardless of their transport; existing sessions
	/// retain the locator their hello signed.
	pub fn set_advertised_locator(
		&self,
		transport: &str,
		designator: &str,
		direct_addresses: &str,
	) -> Result<()> {
		self.shared
			.set_advertised_locator(transport, designator, direct_addresses)
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
	#[cfg(test)]
	pub(crate) fn new_in(context: &Context, codec: Codec) -> Result<Host> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed)
			.map_err(|_| Error::with_detail(sys::ERR_INTERNAL, "no OS entropy".to_string()))?;
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

	/// The iroh reachability posture this host uses to redeem a *hint-less*
	/// handoff give (the exporter named by node id alone, with no direct-address
	/// hints). Defaults to [`Reachability::Discovery`]; set
	/// [`Reachability::DiscoveryNoRelay`] to honor a no-relay deployment policy. A
	/// hinted give always dials [`Reachability::Direct`] and ignores this.
	pub fn set_redeem_reachability(&self, reachability: Reachability) -> Result<()> {
		self.shared.guard_open()?;
		self.shared.redeem_reachability.set(reachability);
		Ok(())
	}

	/// The reachability posture this host uses to redeem a hint-less handoff give.
	pub fn redeem_reachability(&self) -> Reachability {
		self.shared.redeem_reachability.get()
	}

	/// Configure how this host reaches a `keyed-relay` peer: map the peer's
	/// key designator to the WebSocket URL of the relay rendezvous leg that
	/// bridges onto its held inbound socket, e.g.
	/// `|id| format!("wss://example/relay?rendezvous={id}")` (ADR-0088). The
	/// keyed-relay sibling of [`Host::set_redeem_reachability`]: deployment
	/// configuration for reaching an exporter that opens no listener. Without
	/// it, a `keyed-relay` dial refuses; the dial itself needs the
	/// `rendezvous` feature.
	pub fn set_rendezvous_url(&self, url: impl Fn(&str) -> String + 'static) -> Result<()> {
		self.shared.guard_open()?;
		*self.shared.rendezvous_url.borrow_mut() = Some(Rc::new(url));
		Ok(())
	}

	/// Enliven a complete sturdyref without naming a session (ADR-0098): the
	/// host enlivens it over a live session it already dialed to that peer, or
	/// dials one itself through this host's own DIAL action and finishes when
	/// the dial reports. [`Session::enliven`] is the narrower verb — it never
	/// dials, and refuses a sturdyref for another peer.
	pub async fn enliven(&self, sturdyref: &str) -> Result<Ref> {
		self.shared.guard_open()?;
		let mut vow: u64 = 0;
		check_host(unsafe {
			ffi::pancake_host_enliven(
				self.shared.raw(),
				sturdyref.as_ptr(),
				sturdyref.len(),
				&mut vow,
			)
		})?;
		// The vow may be parked on a dial with no session of its own, which is
		// exactly the `None` session row the vow table already admits.
		self.shared.vow_minted(vow, None);
		let settled = self.shared.await_vow(vow);
		self.shared.kick_actions().await;
		match settled.await? {
			Argument::Reference(reference) => Ok(reference),
			_ => Err(Error::broken(format!(
				"{sturdyref:?} did not resolve to a capability"
			))),
		}
	}

	/// Mint a resolver pair (off-turn settlement, ADR-0102): the returned
	/// [`Resolver`] is the settle authority, and its vow is the read side a
	/// behavior defers its answer onto with [`Resolver::forward_turn`]. Legal
	/// inside a behavior, which is the primary use: the behavior mints,
	/// forwards, parks the resolver for whatever completes the work, and
	/// returns; the completion settles it later from the host's thread as its
	/// own top-level event.
	pub fn spawn_resolver(&self) -> Result<Resolver> {
		let mut vow_id: u64 = 0;
		let mut resolver_id: u64 = 0;
		check_host(unsafe {
			ffi::pancake_host_spawn_resolver(self.shared.raw.get(), &mut vow_id, &mut resolver_id)
		})?;
		Ok(Resolver {
			shared: Rc::clone(&self.shared),
			vow_id,
			id: resolver_id,
		})
	}

	/// Host `make`'s behavior once and bind `name` as a Host-wide alias. Fetch
	/// lazily projects the actor onto a session, and a deposited gift keeps that
	/// exact actor when a recipient withdraws over its own exporter session
	/// (ADR-0009). `make` preserves the factory-shaped API for a `!Clone` `FnMut`;
	/// the Host invokes it once.
	pub fn publish_giftable(&self, name: &str, make: impl Fn() -> Behavior + 'static) {
		if let Err(error) = self.shared.guard_open() {
			panic!("publish_giftable({name:?}) refused: {error}");
		}
		// A giftable is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		let mut behavior = make();
		let cell = Box::into_raw(Box::new(ActorCell {
			behavior: RefCell::new(outcome_behavior(move |verb, args| behavior(verb, args))),
		}));
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
			unsafe { reclaim_refused_cell(rc, cell) };
			// A refused host-wide publish is a programming error at the one call
			// site that owns the name; fail loud rather than serve a ghost.
			panic!(
				"publish_giftable({name:?}) refused: {}",
				host_last_error().unwrap_or_else(|| rc.to_string())
			);
		}
		self.shared
			.giftables
			.borrow_mut()
			.insert(name.to_string(), cell);
		self.shared.schedule_kick();
	}

	/// Publish `make`'s behavior under a freshly minted durable swiss name and
	/// return that name — the swiss to place in a sturdyref beside this host's
	/// own locator (ADR-0098). Unpredictable, never reassigned, structurally
	/// disjoint from every mutable alias, and removable only through
	/// [`Host::remove_durable`]. Entropy is drawn here, from the OS RNG.
	pub fn publish_durable(&self, make: impl Fn() -> Behavior + 'static) -> String {
		if let Err(error) = self.shared.guard_open() {
			panic!("publish_durable refused: {error}");
		}
		let mut behavior = make();
		let cell = Box::into_raw(Box::new(ActorCell {
			behavior: RefCell::new(outcome_behavior(move |verb, args| behavior(verb, args))),
		}));
		let mut entropy = [0u8; 16];
		getrandom::fill(&mut entropy).expect("the OS RNG provides durable swiss entropy");
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
			unsafe { reclaim_refused_cell(rc, cell) };
			panic!(
				"publish_durable refused: {}",
				host_last_error().unwrap_or_else(|| rc.to_string())
			);
		}
		let name = String::from_utf8_lossy(&swiss[..rc as usize]).into_owned();
		self.shared
			.giftables
			.borrow_mut()
			.insert(name.clone(), cell);
		self.shared.schedule_kick();
		name
	}

	/// Remove a minted durable publication (ADR-0098): the old sturdyref
	/// misses from now on, while capabilities already issued and deposited
	/// gifts keep the exact actor. Returns `false` when no such durable name
	/// exists.
	pub fn remove_durable(&self, swiss: &str) -> bool {
		if let Err(error) = self.shared.guard_open() {
			panic!("remove_durable({swiss:?}) refused: {error}");
		}
		let rc = unsafe {
			ffi::pancake_host_remove_durable(self.shared.raw.get(), swiss.as_ptr(), swiss.len())
		};
		if rc == sys::ERR_NOT_FOUND {
			return false;
		}
		if rc != sys::OK {
			panic!(
				"remove_durable({swiss:?}) refused: {}",
				host_last_error().unwrap_or_else(|| rc.to_string())
			);
		}
		self.shared.giftables.borrow_mut().remove(swiss);
		true
	}

	/// Remove the Host-wide alias `name` (alias-only, ADR-0096): a later fetch
	/// misses on every session, while capabilities already issued and deposited
	/// gifts keep the exact actor, whose behavior stays hosted for the Host's
	/// life. Returns `false` when no such alias exists; any other refusal is a
	/// programming error and panics like `publish_giftable`.
	pub fn unpublish_giftable(&self, name: &str) -> bool {
		if let Err(error) = self.shared.guard_open() {
			panic!("unpublish_giftable({name:?}) refused: {error}");
		}
		let rc = unsafe {
			ffi::pancake_host_unpublish(self.shared.raw.get(), name.as_ptr(), name.len())
		};
		if rc == sys::ERR_NOT_FOUND {
			return false;
		}
		if rc != sys::OK {
			panic!(
				"unpublish_giftable({name:?}) refused: {}",
				host_last_error().unwrap_or_else(|| rc.to_string())
			);
		}
		// The alias is gone but the actor is not: the C row still owns the
		// behavior cell (freed at release), so only the name bookkeeping drops.
		self.shared.giftables.borrow_mut().remove(name);
		true
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::dial::Reachability;
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
		});

		host.close();
		assert!(host.shared.raw.get().is_null());
		assert!(
			dropped.get(),
			"native Host release drops the captured behavior"
		);
	}

	// A fresh host redeems a hint-less iroh give under `Discovery` by default —
	// the behavior-preserving, maximal-reach choice every existing handoff gate
	// relies on — and the recipient can lower it to a no-relay policy. The setter
	// is shared across host clones, so a knob set on one handle reaches the
	// connections that share the host's identity.
	#[test]
	fn redeem_reachability_defaults_to_discovery_and_is_settable() {
		let host = Host::new_host();
		assert_eq!(host.redeem_reachability(), Reachability::Discovery);
		host.set_redeem_reachability(Reachability::DiscoveryNoRelay)
			.unwrap();
		assert_eq!(host.redeem_reachability(), Reachability::DiscoveryNoRelay);
		assert_eq!(
			host.clone().redeem_reachability(),
			Reachability::DiscoveryNoRelay
		);
	}

	// Public Host surfaces the ADR-0082 selective knobs (not only HostShared).
	#[test]
	fn set_session_limits_is_callable_on_host() {
		let host = Host::new_host();
		host.set_session_limits(0, 0)
			.expect("0 leaves both fields unchanged");
		host.set_session_limits(64 * 1024, 0)
			.expect("max_frame_bytes alone is accepted");
	}

	#[test]
	fn advertised_locator_lifecycle_is_callable_on_host() {
		let host = Host::new_host();
		host.set_advertised_locator("tcp", "127.0.0.1:7441", "")
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
		});
		host.set_session_limits(0, 0)
			.expect("minted host answers limits");
	}
}

/// The settle authority of a resolver pair (off-turn settlement, ADR-0102),
/// minted by [`Host::spawn_resolver`]. A behavior defers its answer onto the
/// pair's vow with [`Resolver::forward_turn`], hands the resolver to whatever
/// completes the work, and the completion settles it from the host's thread.
/// The settle verbs consume the resolver, so the one-shot contract is a type
/// fact: a second settle does not compile. A deferred settle carries plain
/// data only — a value that names a capability is refused, and an answer that
/// carries authority forwards to a send instead.
pub struct Resolver {
	shared: Rc<HostShared>,
	vow_id: u64,
	id: u64,
}

impl Resolver {
	/// Defer the current turn's answer onto this resolver's vow: the answer
	/// settles when the resolver does, as its own top-level event. Legal only
	/// inside a behavior hosted by this resolver's host.
	pub fn forward_turn(&self) -> Result<()> {
		let turn = current_turn_for(Rc::as_ptr(&self.shared) as usize).ok_or_else(|| {
			Error::with_transport_detail(
				sys::ERR_INVALID_ARGUMENT,
				Some("forward_turn is a turn verb: call it inside a behavior of this host".into()),
			)
		})?;
		check_host(unsafe { ffi::pancake_host_turn_forward_vow(turn, self.vow_id) })
	}

	/// Settle the deferred answer fulfilled with a capability-free `value`.
	/// Top-level: refused inside a behavior callback; the settle pumps the
	/// sessions the deferred answers dirtied.
	pub fn fulfill(self, value: &Argument) -> Result<()> {
		let mut arena = crate::SendArena::default();
		let c_value = arena.one(value)?;
		check_host(unsafe {
			ffi::pancake_host_resolver_fulfill(self.shared.raw.get(), self.id, &c_value)
		})?;
		self.shared.schedule_kick();
		Ok(())
	}

	/// Settle the deferred answer broken with the worker's own words. The
	/// same top-level, one-shot contract as [`Resolver::fulfill`].
	pub fn break_with(self, reason: &str) -> Result<()> {
		check_host(unsafe {
			ffi::pancake_host_resolver_break(
				self.shared.raw.get(),
				self.id,
				reason.as_ptr(),
				reason.len(),
			)
		})?;
		self.shared.schedule_kick();
		Ok(())
	}
}
