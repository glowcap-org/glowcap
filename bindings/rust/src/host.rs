//! The CapTP node — pancake's analogue of Goblins' `mycapn`, one per node —
//! over the byte-fed host archive (`libpancake_driver`, ADR-0072). The
//! `PancakeHost` owns every decision: the retained identity, the shared gift
//! registry, routing, transparent three-party redemption, and the gifter
//! half's origination. What lives here is only what the embedder contract
//! leaves to the binding: the host handle, the conn-pointer → connection
//! registry the action drain routes by, the vow table the drain's SETTLE/FAIL
//! arms settle, the action drain itself, gift-id entropy, and the iroh redeem
//! posture the dial executor reads. The pump and the dial executor live in
//! `connection.rs`, which owns the [`Connection`] they act on.
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
use std::rc::Rc;

use tokio::sync::oneshot;

use crate::connection::{dial_exporter, ConnShared, Reachability};
use crate::sys::driver as ffi;
use crate::trampoline::{
	ctx_free, inside_turn, outcome_behavior, reclaim_refused_cell, trampoline, ActorCell,
};
use crate::{arg_from_sys, sys, Argument, Behavior, Codec, Context, Error, Result};

/// Every connection's maximum admissible frame, mirroring the engine's default
/// session limit; the core's stream delimiter (`pancake_host_conn_feed_bytes`)
/// enforces it while it scans, so a hostile stream cannot grow an inbox past it.
const HOST_FRAME_CAP: usize = 1 << 20;

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
	Conn {
		conn: *mut ffi::PancakeHostConn,
		host: Rc<HostShared>,
	},
	Host(*mut ffi::PancakeHost),
}

thread_local! {
	static PENDING_RELEASES: RefCell<Vec<PendingRelease>> = const { RefCell::new(Vec::new()) };
}

/// Park a connection release that a callback frame refused.
pub(crate) fn park_conn_release(conn: *mut ffi::PancakeHostConn, host: Rc<HostShared>) {
	PENDING_RELEASES.with(|list| list.borrow_mut().push(PendingRelease::Conn { conn, host }));
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
			PendingRelease::Conn { conn, host } => {
				unsafe { ffi::pancake_host_conn_release(conn) };
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
	state: Option<Result<Argument>>,
	waiter: Option<oneshot::Sender<Result<Argument>>>,
}

// One popped embedder action, every borrowed view lifted to owned Rust values
// (a SETTLE's `PancakeArgument` included) before the next
// `pancake_host_next_action` call can free them.
enum HostAction {
	Dial {
		ticket: u64,
		locator: String,
		transport: String,
		designator: String,
		direct_addresses_hint: String,
	},
	Flush {
		conn: usize,
	},
	Close {
		conn: usize,
	},
	NeedGiftId {
		ticket: u64,
	},
	Settle {
		vow: u64,
		value: Argument,
	},
	Fail {
		vow: u64,
		message: String,
	},
}

/// The binding half of one CapTP node: the raw `PancakeHost`, the connection
/// registry, the vow table, and the redeem posture, shared behind an `Rc` by
/// the public [`Node`] and every [`ConnShared`] — which is what mechanically
/// enforces the header's "release the host always after its connections" (the
/// host pointer cannot be released while any connection wrapper lives).
pub(crate) struct HostShared {
	raw: Cell<*mut ffi::PancakeHost>,
	// Every live connection by its PancakeHostConn address, so a FLUSH action
	// routes to the transport that owns the bytes and a dialed exporter stays
	// reachable for teardown. A connection unregisters at close, which is what
	// breaks the Rc cycle between host and connection state.
	connections: RefCell<HashMap<usize, Rc<ConnShared>>>,
	// The vow table the drain's SETTLE/FAIL arms settle.
	vows: RefCell<HashMap<u64, VowRow>>,
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	unobserved: RefCell<VecDeque<u64>>,
	// The iroh reachability posture this node uses to redeem a *hint-less*
	// handoff give — one whose exporter location names the exporter by node id
	// alone. Defaults to `Discovery` (n0 relays + DNS/pkarr, the maximal-reach
	// choice); a relay-policy deployment lowers it. A hinted give always dials
	// `Direct` and ignores this.
	redeem_reachability: Cell<Reachability>,
}

impl HostShared {
	fn new(seed: [u8; 32], codec: Codec, context: Option<&Context>) -> Result<Rc<HostShared>> {
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
					&mut raw,
				)
			},
		})?;
		Ok(Rc::new(HostShared {
			raw: Cell::new(raw),
			connections: RefCell::new(HashMap::new()),
			vows: RefCell::new(HashMap::new()),
			unobserved: RefCell::new(VecDeque::new()),
			redeem_reachability: Cell::new(Reachability::Discovery),
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

	/// Record the designator this node's dials sign as their own dialable
	/// address (a node that also listens); `listen`/`listen_iroh` set it to the
	/// bound address so a partner's crossed-hellos table can recognize this node.
	pub(crate) fn set_self_designator(&self, designator: &str) -> Result<()> {
		check_host(unsafe {
			ffi::pancake_host_set_self_designator(
				self.raw.get(),
				designator.as_ptr(),
				designator.len(),
			)
		})
	}

	// ── Connection registry ────────────────────────────────────────────────────

	/// Track a live connection by its conn address; the `ConnShared`
	/// constructor calls it.
	pub(crate) fn register_connection(&self, key: usize, conn: Rc<ConnShared>) {
		self.connections.borrow_mut().insert(key, conn);
	}

	/// Stop tracking a released connection.
	pub(crate) fn unregister_connection(&self, key: usize) {
		self.connections.borrow_mut().remove(&key);
	}

	/// Close every exporter connection this node dialed for redeems;
	/// `Connection::close` sweeps them.
	pub(crate) fn close_exporters(&self) {
		let dialed: Vec<Rc<ConnShared>> = self
			.connections
			.borrow()
			.values()
			.filter(|conn| conn.is_node_dialed())
			.cloned()
			.collect();
		for conn in dialed {
			conn.close_transport();
		}
	}

	// ── The vow table ──────────────────────────────────────────────────────────

	/// Record a freshly minted vow so the drain can route its completion. Must
	/// run in the same synchronous block as the minting FFI call, so no drain
	/// can pop the completion first.
	pub(crate) fn vow_minted(&self, vow: u64) {
		self.vows.borrow_mut().insert(
			vow,
			VowRow {
				state: None,
				waiter: None,
			},
		);
	}

	/// The vow's eventual outcome: the fulfilled wire value, or the typed break
	/// (`ErrorKind::Broken` carrying the reason — a disconnect's own break
	/// arrives as `Broken` with "connection closed", the classification the old
	/// surface promised, where the TS/Python siblings type it Closed). Settles
	/// immediately from the recorded state when the outcome already landed.
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
	// at the cap).
	fn settle_vow(&self, vow: u64, outcome: Result<Argument>) {
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

	/// Run the action drain to empty, honoring each action. Reentrant on
	/// purpose, the async spelling of the Racket binding's reentrant node lock:
	/// the DIAL arm's dial executor establishes a whole new connection *inside*
	/// an action, and that establish must itself drain (its start-session
	/// FLUSH) — a single-flighted drain would await its own completion there.
	/// Each action is popped exactly once (`next_action` is synchronous), so
	/// overlapping drains split the queue between them rather than double-
	/// running anything. A no-op inside a hosted turn: the host refuses the
	/// driving verbs there, and everything the turn enqueued pumps when the
	/// enclosing feed unwinds into this same drain.
	pub(crate) async fn kick_actions(self: &Rc<HostShared>) {
		if inside_turn() || self.raw.get().is_null() {
			return;
		}
		drain_pending_releases();
		loop {
			let Some(action) = self.next_action() else {
				return;
			};
			// One failing action must not strand the rest of the drain: a FLUSH
			// to a connection whose socket just died fails here while the actions
			// behind it belong to other, live connections. The failed connection
			// tears itself down through its own serve loop (a DIAL failure is
			// reported to the core inside the arm).
			let _ = self.run_action(action).await;
		}
	}

	// Pop the next embedder action, its borrowed views lifted to owned Rust
	// values — a SETTLE's PancakeArgument whole — before anything else can call
	// `pancake_host_next_action` (which frees them), and before the drain's
	// first await. None when the queue is dry.
	fn next_action(&self) -> Option<HostAction> {
		let mut raw: ffi::PancakeHostAction = unsafe { core::mem::zeroed() };
		let rc = unsafe { ffi::pancake_host_next_action(self.raw.get(), &mut raw) };
		if rc == sys::WOULD_BLOCK {
			return None;
		}
		if rc != sys::OK {
			// The only non-WOULD_BLOCK refusal the header names is the
			// callback latch, and the drain never runs inside a callback; a
			// refusal here is a binding bug, not an empty queue.
			debug_assert!(false, "pancake_host_next_action refused with rc {rc}");
			return None;
		}
		let view = |ptr: *const u8, len: usize| -> String {
			if ptr.is_null() || len == 0 {
				String::new()
			} else {
				// The bytes originate in a partner-authored give, so decode
				// leniently rather than let hostile bytes fault mid-drain.
				String::from_utf8_lossy(unsafe { core::slice::from_raw_parts(ptr, len) })
					.into_owned()
			}
		};
		match raw.kind {
			sys::HOST_ACTION_DIAL => Some(HostAction::Dial {
				ticket: raw.ticket,
				locator: view(raw.locator, raw.locator_len),
				transport: view(raw.transport, raw.transport_len),
				designator: view(raw.designator, raw.designator_len),
				direct_addresses_hint: view(
					raw.direct_addresses_hint,
					raw.direct_addresses_hint_len,
				),
			}),
			sys::HOST_ACTION_FLUSH => Some(HostAction::Flush {
				conn: raw.conn as usize,
			}),
			sys::HOST_ACTION_CLOSE => Some(HostAction::Close {
				conn: raw.conn as usize,
			}),
			sys::HOST_ACTION_NEED_GIFT_ID => Some(HostAction::NeedGiftId { ticket: raw.ticket }),
			sys::HOST_ACTION_SETTLE => Some(HostAction::Settle {
				vow: raw.ticket,
				value: unsafe { arg_from_sys(&raw.value) },
			}),
			sys::HOST_ACTION_FAIL => Some(HostAction::Fail {
				vow: raw.ticket,
				message: view(raw.message, raw.message_len),
			}),
			kind => unreachable!("unknown host action kind {kind}"),
		}
	}

	// The executor is deliberately dumb: every decision was already made in the
	// core; each arm is pure I/O or marshalling.
	async fn run_action(self: &Rc<HostShared>, action: HostAction) -> Result<()> {
		match action {
			HostAction::Dial {
				ticket,
				locator,
				transport,
				designator,
				direct_addresses_hint,
			} => {
				// Boxed to break the async recursion cycle: the dial's establish
				// runs its own reentrant drain (its start-session FLUSH), which
				// is this very function.
				let dialed = Box::pin(dial_exporter(
					&locator,
					&transport,
					&designator,
					&direct_addresses_hint,
					Rc::clone(self),
				))
				.await;
				match dialed {
					Ok(conn) => {
						conn.mark_node_dialed();
						let raw_conn = conn.raw_conn();
						// Keep the exporter connection pumped: the withdraw's
						// resolution — and any later routed traffic — rides it
						// immediately. The task owns the wrapper so the exporter
						// lives until its own transport ends.
						let serving = conn.serve();
						try_spawn_local(async move {
							serving.await;
							drop(conn);
						});
						check_host(unsafe {
							ffi::pancake_host_dialed(self.raw.get(), ticket, raw_conn)
						})
					}
					Err(error) => {
						// The host turns a failed dial into broken redeems.
						let reason = error.to_string();
						check_host(unsafe {
							ffi::pancake_host_dial_failed(
								self.raw.get(),
								ticket,
								reason.as_ptr(),
								reason.len(),
							)
						})
					}
				}
			}
			HostAction::Flush { conn } => {
				let target = self.connections.borrow().get(&conn).cloned();
				match target {
					Some(conn) => conn.flush_outbound().await,
					None => Ok(()),
				}
			}
			HostAction::Close { conn } => {
				// The host condemned the connection mid-pump (local turn
				// budget exceeded): write its queued resource_exhausted abort
				// best-effort, then close the transport and release the conn
				// shell.
				let target = self.connections.borrow().get(&conn).cloned();
				if let Some(conn) = target {
					let _ = conn.flush_outbound().await;
					conn.close_transport();
				}
				Ok(())
			}
			HostAction::NeedGiftId { ticket } => {
				// Entropy is a host effect, drawn only when a reply actually
				// becomes a gift. The OS RNG failing is not a recoverable
				// condition, the same stance the node constructor takes.
				let mut gift_id = [0u8; 32];
				getrandom::fill(&mut gift_id).expect("the OS RNG provides gift-id entropy");
				check_host(unsafe {
					ffi::pancake_host_provide_gift_id(
						self.raw.get(),
						ticket,
						gift_id.as_ptr(),
						gift_id.len(),
					)
				})
			}
			HostAction::Settle { vow, value } => {
				self.settle_vow(vow, Ok(value));
				Ok(())
			}
			HostAction::Fail { vow, message } => {
				// Every break — a partner refusal and a disconnect's own break
				// alike — surfaces as the typed Broken carrying the reason, the
				// classification the pre-host surface promised its consumers
				// (the TS/Python siblings type a closing connection's break
				// Closed instead; the divergence is deliberate, not drift).
				self.settle_vow(vow, Err(Error::broken(message)));
				Ok(())
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

/// The CapTP node: one identity, one gift registry, one routing and redeem
/// authority, shared by every connection minted against it. The cross-node
/// machinery lives in the Zig core behind `libpancake_driver` (ADR-0072); this
/// is the host-idiom residue over it — the connection registry, the vow table,
/// the action drain that performs the I/O the host asks for (dial, flush,
/// settle, entropy), and the iroh redeem posture. Cloning shares the same
/// node; the native host is released when the last clone (and last connection)
/// drops.
#[derive(Clone)]
pub struct Node {
	shared: Rc<HostShared>,
}

impl Node {
	// A fresh node with a random retained identity, minted at the I/O boundary
	// (the sans-io core never generates entropy). The OS RNG failing is not a
	// recoverable condition, the same stance the Deno/Python nodes take.
	pub(crate) fn new_node() -> Node {
		Node::with_codec(Codec::Syrup)
	}

	/// A fresh node whose connections all negotiate in `codec` — the codec is a
	/// node property, so every connection minted against a shared node speaks
	/// the same grammar (`Codec::Syrup` is what [`connect`](crate::connect) and
	/// [`listen`](crate::listen) mint by default). Pass the node to
	/// [`Connection::connect_with_node`](crate::Connection::connect_with_node)
	/// or [`listen_with_node`](crate::listen_with_node).
	pub fn with_codec(codec: Codec) -> Node {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).expect("the OS RNG provides a node identity seed");
		let shared = HostShared::new(seed, codec, None).expect("the allocator provides a node");
		Node { shared }
	}

	// A node in a caller-supplied allocation scope; the node must be dropped
	// before the context. Test-only: the allocator dogfood drives it.
	#[cfg(test)]
	pub(crate) fn new_in(context: &Context, codec: Codec) -> Result<Node> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed)
			.map_err(|_| Error::with_detail(sys::ERR_INTERNAL, "no OS entropy".to_string()))?;
		Ok(Node {
			shared: HostShared::new(seed, codec, Some(context))?,
		})
	}

	pub(crate) fn from_shared(shared: Rc<HostShared>) -> Node {
		Node { shared }
	}

	pub(crate) fn shared(&self) -> Rc<HostShared> {
		Rc::clone(&self.shared)
	}

	/// The iroh reachability posture this node uses to redeem a *hint-less*
	/// handoff give (the exporter named by node id alone, with no direct-address
	/// hints). Defaults to [`Reachability::Discovery`]; set
	/// [`Reachability::DiscoveryNoRelay`] to honor a no-relay deployment policy. A
	/// hinted give always dials [`Reachability::Direct`] and ignores this.
	pub fn set_redeem_reachability(&self, reachability: Reachability) {
		self.shared.redeem_reachability.set(reachability);
	}

	/// The reachability posture this node uses to redeem a hint-less handoff give.
	pub fn redeem_reachability(&self) -> Reachability {
		self.shared.redeem_reachability.get()
	}

	/// Publish `make`'s behavior under `name` on every connection of this node —
	/// those open now and any accepted later — so a recipient can fetch it on a
	/// connection it dialed itself (the exporter half of a three-party handoff,
	/// ADR-0009). The replay onto future connections is host-internal. `make` is
	/// a factory for signature continuity with an actor behavior being a `!Clone`
	/// `FnMut`; the host publishes the one behavior it mints node-wide.
	pub fn publish_giftable(&self, name: &str, make: impl Fn() -> Behavior + 'static) {
		// A giftable is bound to no single connection: its forwards always go
		// through the host, and a turn it runs belongs to whichever connection
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
			// A refused node-wide publish is a programming error at the one call
			// site that owns the name; fail loud rather than serve a ghost.
			panic!(
				"publish_giftable({name:?}) refused: {}",
				host_last_error().unwrap_or_else(|| rc.to_string())
			);
		}
		self.shared.schedule_kick();
	}
}
