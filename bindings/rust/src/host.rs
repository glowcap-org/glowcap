//! The CapTP [`Host`] — multi-session CapTP product over the byte-fed host archive
//! (`libpancake_driver`, ADR-0072). It owns `engine.Node` (the sans-io handoff
//! router). Goblins' `mycapn` is two roles: endpoint ≈ Host, router tables ≈
//! `engine.Node` — never a single-type equation (ADR-0079). The `PancakeHost`
//! owns every decision: the retained identity, the shared gift registry,
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
use crate::sys::driver as ffi;
use crate::trampoline::{
	ctx_free, inside_turn, outcome_behavior, reclaim_refused_cell, trampoline, ActorCell,
};
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
	Host(*mut ffi::PancakeHost),
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
				unsafe { ffi::pancake_host_session_release(conn) };
				drop(host);
			}
			PendingRelease::Host(host) => unsafe { ffi::pancake_host_release(host) },
		}
	}
}

// A host vow's row: registered the instant the vow is minted (the mint IS the
// registration), settled by the drain's SETTLE/FAIL arms. An outcome that
// lands before anyone awaits is stored, so a late observation settles from the
// recorded state instead of hanging — and no waiter exists until one is
// registered, so an unobserved broken answer never strands a channel.
struct VowRow {
	/// Home CapTP session at mint (weak so the vow table cannot pin a session).
	/// FAIL uses it to classify disconnect breaks as CLOSED.
	session: Option<Weak<SessionShared>>,
	state: Option<Result<Argument>>,
	waiter: Option<oneshot::Sender<Result<Argument>>>,
}

/// The binding half of one CapTP Host: the raw `PancakeHost`, the CapTP session
/// registry, the vow table, and the redeem posture, shared behind an `Rc` by
/// the public [`Host`] and every [`SessionShared`] — which is what mechanically
/// enforces the header's "release the host always after its CapTP sessions" (the
/// host pointer cannot be released while any session wrapper lives).
pub(crate) struct HostShared {
	raw: Cell<*mut ffi::PancakeHost>,
	// Every live CapTP session shell by its PancakeHostSession address, so a FLUSH
	// action routes to the transport that owns the bytes and a dialed exporter
	// stays reachable for teardown. A session unregisters at close, which is
	// what breaks the Rc cycle between host and session state. `action::run`
	// reads it for FLUSH / CLOSE.
	pub(crate) sessions: RefCell<HashMap<usize, Rc<SessionShared>>>,
	// The vow table the drain's SETTLE/FAIL arms settle.
	vows: RefCell<HashMap<u64, VowRow>>,
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	unobserved: RefCell<VecDeque<u64>>,
	// The iroh reachability posture this host uses to redeem a *hint-less*
	// handoff give — one whose exporter location names the exporter by node id
	// alone. Defaults to `Discovery` (n0 relays + DNS/pkarr, the maximal-reach
	// choice); a relay-policy deployment lowers it. A hinted give always dials
	// `Direct` and ignores this.
	redeem_reachability: Cell<Reachability>,
	/// The 32-byte Ed25519 identity seed this host was minted with — retained
	/// so a keyed-tcp listener can derive its public designator without a
	/// second identity (ADR-0075).
	seed: [u8; 32],
}

impl HostShared {
	fn new(
		seed: [u8; 32],
		codec: Codec,
		local_turn_budget: u32,
		context: Option<&Context>,
	) -> Result<Rc<HostShared>> {
		let mut raw: *mut ffi::PancakeHost = core::ptr::null_mut();
		check_host(match context {
			Some(context) => unsafe {
				ffi::pancake_host_new_in(
					context.raw,
					seed.as_ptr(),
					seed.len(),
					HOST_FRAME_CAP,
					1,
					codec.to_c(),
					local_turn_budget,
					&mut raw,
				)
			},
			None => unsafe {
				ffi::pancake_host_new(
					seed.as_ptr(),
					seed.len(),
					HOST_FRAME_CAP,
					1,
					codec.to_c(),
					local_turn_budget,
					&mut raw,
				)
			},
		})?;
		Ok(Rc::new(HostShared {
			raw: Cell::new(raw),
			sessions: RefCell::new(HashMap::new()),
			vows: RefCell::new(HashMap::new()),
			unobserved: RefCell::new(VecDeque::new()),
			redeem_reachability: Cell::new(Reachability::Discovery),
			seed,
		}))
	}

	/// The raw `PancakeHost` handle.
	pub(crate) fn raw(&self) -> *mut ffi::PancakeHost {
		self.raw.get()
	}

	// Read by the iroh dial executor alone: a hint-less iroh give resolves
	// under this posture, and no other transport consults it.
	#[cfg(feature = "iroh")]
	pub(crate) fn redeem_reachability(&self) -> Reachability {
		self.redeem_reachability.get()
	}

	/// Record the designator this host's dials sign as their own dialable
	/// address (a host that also listens); `listen`/`listen_iroh` set it to the
	/// bound address so a partner's crossed-hellos table can recognize this host.
	pub(crate) fn set_self_designator(&self, designator: &str) -> Result<()> {
		check_host(unsafe {
			ffi::pancake_host_set_self_designator(
				self.raw.get(),
				designator.as_ptr(),
				designator.len(),
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
		check_host(unsafe {
			ffi::pancake_host_set_session_limits(self.raw.get(), max_frame_bytes, queue_cap)
		})
	}

	// ── Session registry ────────────────────────────────────────────────────

	/// Track a live CapTP session shell by its PancakeHostSession address; the
	/// `SessionShared` constructor calls it.
	pub(crate) fn register_session(&self, key: usize, conn: Rc<SessionShared>) {
		self.sessions.borrow_mut().insert(key, conn);
	}

	/// Stop tracking a released CapTP session shell.
	pub(crate) fn unregister_session(&self, key: usize) {
		self.sessions.borrow_mut().remove(&key);
	}

	/// Close every exporter connection this host dialed for redeems;
	/// `Session::close` sweeps them.
	pub(crate) fn close_exporters(&self) {
		let dialed: Vec<Rc<SessionShared>> = self
			.sessions
			.borrow()
			.values()
			.filter(|conn| conn.is_host_dialed())
			.cloned()
			.collect();
		for conn in dialed {
			conn.close_transport();
		}
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
				state: None,
				waiter: None,
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
				Some(row) => match row.state.take() {
					Some(outcome) => {
						vows.remove(&vow);
						Waiting::Now(outcome)
					}
					None => {
						let (tx, rx) = oneshot::channel();
						row.waiter = Some(tx);
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
			if let Some(waiter) = row.waiter.take() {
				vows.remove(&vow);
				drop(vows);
				let _ = waiter.send(outcome);
				return;
			}
			row.state = Some(outcome);
		}
		let mut unobserved = self.unobserved.borrow_mut();
		unobserved.push_back(vow);
		while unobserved.len() > MAX_UNOBSERVED_OUTCOMES {
			let Some(oldest) = unobserved.pop_front() else {
				break;
			};
			let mut vows = self.vows.borrow_mut();
			// Only evict a row still parked unobserved; an observed one is gone.
			let evict = vows
				.get(&oldest)
				.is_some_and(|stale| stale.state.is_some() && stale.waiter.is_none());
			if evict {
				vows.remove(&oldest);
			}
		}
	}

	// ── The action drain (the one loop rule) ──────────────────────────────────

	/// Kick the action drain from a synchronous verb: schedule it as its own
	/// task on the `LocalSet`.
	pub(crate) fn schedule_kick(self: &Rc<HostShared>) {
		if inside_turn() || self.raw.get().is_null() {
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
		if inside_turn() || self.raw.get().is_null() {
			return;
		}
		drain_pending_releases();
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
		let raw = self.raw.replace(core::ptr::null_mut());
		if raw.is_null() {
			return;
		}
		// The release is refused inside a callback; park it for the next drain
		// rather than dropping it on the floor.
		if inside_turn() {
			PENDING_RELEASES.with(|list| list.borrow_mut().push(PendingRelease::Host(raw)));
		} else {
			unsafe { ffi::pancake_host_release(raw) };
		}
	}
}

/// The CapTP Host: one identity, one gift registry, one routing and redeem
/// authority, shared by every session minted against it. Owns `engine.Node`
/// (router half of Goblins mycapn; the Host is the endpoint half — ADR-0079).
/// The cross-session machinery lives in the Zig core behind `libpancake_driver`
/// (ADR-0072); this is the host-idiom residue over it — the session registry,
/// the vow table, the action drain that performs the I/O the host asks for
/// (dial, flush, settle, entropy), and the iroh redeem posture. Cloning shares
/// the same Host; the native host is released when the last clone (and last
/// session) drops.
#[derive(Clone)]
pub struct Host {
	shared: Rc<HostShared>,
}

/// Construction knobs for [`Host`]. Codec and local-turn budget are mint-time;
/// selective session limits stay on [`Host::set_session_limits`] (ADR-0082).
#[derive(Debug, Clone, Copy)]
pub struct HostOptions {
	pub codec: Codec,
	/// `0` = unbounded (default); nonzero caps local-turn amplification per drive
	/// (ADR-0076).
	pub local_turn_budget: u32,
}

impl Default for HostOptions {
	fn default() -> Self {
		Self {
			codec: Codec::Syrup,
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

	/// A Host whose retained Ed25519 identity is reconstructed from `seed` —
	/// the restart-stable posture a keyed-tcp listener needs so designator,
	/// session key, and Host identity stay one value across a rebind
	/// (ADR-0075). `Codec::Syrup` is the default wire grammar.
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
			shared: HostShared::new(seed, options.codec, options.local_turn_budget, None)?,
		})
	}

	/// Selective session-limit knobs (ADR-0082). Pass `0` to leave a field
	/// unchanged. Affects peers minted after this call.
	pub fn set_session_limits(&self, max_frame_bytes: usize, queue_cap: usize) -> Result<()> {
		self.shared.set_session_limits(max_frame_bytes, queue_cap)
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
			shared: HostShared::new(seed, codec, 0, Some(context))?,
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
	pub fn set_redeem_reachability(&self, reachability: Reachability) {
		self.shared.redeem_reachability.set(reachability);
	}

	/// The reachability posture this host uses to redeem a hint-less handoff give.
	pub fn redeem_reachability(&self) -> Reachability {
		self.shared.redeem_reachability.get()
	}

	/// Publish `make`'s behavior under `name` on every session of this Host —
	/// those open now and any accepted later — so a recipient can fetch it on a
	/// session it dialed itself (the exporter half of a three-party handoff,
	/// ADR-0009). The replay onto future sessions is host-internal. `make` is
	/// a factory for signature continuity with an actor behavior being a `!Clone`
	/// `FnMut`; the host publishes the one behavior it mints Host-wide.
	pub fn publish_giftable(&self, name: &str, make: impl Fn() -> Behavior + 'static) {
		// A giftable is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		let mut behavior = make();
		let cell = Box::into_raw(Box::new(ActorCell {
			behavior: RefCell::new(outcome_behavior(move |verb, args| behavior(verb, args))),
			conn: None,
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
		self.shared.schedule_kick();
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::dial::Reachability;

	// A fresh host redeems a hint-less iroh give under `Discovery` by default —
	// the behavior-preserving, maximal-reach choice every existing handoff gate
	// relies on — and the recipient can lower it to a no-relay policy. The setter
	// is shared across host clones, so a knob set on one handle reaches the
	// connections that share the host's identity.
	#[test]
	fn redeem_reachability_defaults_to_discovery_and_is_settable() {
		let host = Host::new_host();
		assert_eq!(host.redeem_reachability(), Reachability::Discovery);
		host.set_redeem_reachability(Reachability::DiscoveryNoRelay);
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
	fn host_options_carry_local_turn_budget() {
		let host = Host::with_options(HostOptions {
			codec: Codec::Syrup,
			local_turn_budget: 64,
		});
		host.set_session_limits(0, 0)
			.expect("minted host answers limits");
	}
}
