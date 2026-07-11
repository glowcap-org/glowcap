//! The application surface over the byte-fed host (`libpancake_driver`,
//! ADR-0072): [`Connection`] and its verbs (`fetch`/`send`/`tell`/`spawn`/
//! `publish`/`enliven`/`serve`/`close`), the [`RemotePromise`] a send returns,
//! [`Server`] and the top-level [`connect`]/[`listen`] dialers, and the two
//! things the embedder contract leaves to the binding — the pump (read raw
//! bytes off the transport, hand them to the core's stream delimiter
//! `pancake_host_conn_feed_bytes`, which owns framing, drain the host's action
//! queue, write what `take_outbound` drains) and the dial executor a DIAL
//! action names (the recipient half of a three-party handoff opens its own
//! socket to the exporter; the posture decision for a hint-less iroh give
//! lives here). The host owns everything else: routing, redemption, gift
//! origination, far vows.
//!
//! Everything runs on one tokio current-thread `LocalSet`; the handles are
//! `!Send` by construction, so create and use them on one task inside it.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::future::{Future, IntoFuture};
use std::pin::Pin;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, ToSocketAddrs};
use tokio::sync::Notify;

use crate::host::{
	check_host, drain_pending_releases, host_last_error, park_conn_release, try_spawn_local,
	HostShared, Node,
};
use crate::sys::driver as ffi;
use crate::trampoline::{
	ctx_free, current_turn_for, inside_turn, outcome_behavior, reclaim_refused_cell, trampoline,
	turn_spawn, ActorCell, InternalBehavior, LocalRunGuard, TurnOutcome,
};
use crate::uri::tcp_locator;
use crate::{sys, AbortDomain, AbortInfo, Argument, Error, Reference, Result, SendArena};

const READ_CHUNK: usize = 16 * 1024;

/// Map a transport `std::io::Error` to a pancake [`Error`], carrying the
/// original message through the detail channel so a consumer can tell
/// connection-refused from timeout from reset (the public `Error` keeps its
/// `Clone`/`PartialEq` derives, so it holds the message string, not a
/// `Box<dyn Error>` source). The flat code stays `PANCAKE_ERR_IO`.
pub(crate) fn io_err(e: std::io::Error) -> Error {
	Error::with_detail(sys::ERR_IO, e.to_string())
}

/// A capability, a reference to an object you can `send` to, wherever it lives.
///
/// You get a `Ref` from [`Connection::spawn`] (a local actor you host),
/// [`Connection::fetch`] (a capability a partner published), or a capability a
/// partner handed back from a `send` (lift it with `Ref::try_from(&arg)`). Pass
/// one as a `send` argument via `Into<Argument>` (`(&cap).into()`) and it
/// marshals to the right wire reference; you never build `near`/`far` references
/// by hand.
#[derive(Debug, Clone)]
pub struct Ref {
	reference: Reference,
	// Distributed-GC death rite (ADR-0063), present only on a far capability the
	// connection lifted from a fetch while GC was opted in. `Rc` so clones of
	// this `Ref` share the one release unit; the last clone's drop parks the
	// token for the single `op:gc-exports` delta. It is `Rc`, not `Arc`, because
	// the whole handle graph is `!Send` and pinned to the connection's
	// `LocalSet` thread. `None` for near references, refs minted with GC off,
	// and the context-free `try_from` lift.
	//
	// Held only for its `Drop`: the release fires when the last clone falls, so
	// the field is never read by name.
	#[allow(dead_code)]
	guard: Option<Rc<ImportGuard>>,
}

// Drops to one parked `pancake_host_gc_release` delta of 1 for `token`
// (ADR-0063/ADR-0069). The drop only parks the token and pokes the serve task —
// it may run inside a behavior trampoline (a behavior dropping a `Ref`), where
// the host-driving verbs are refused, so the release itself always runs on the
// pumping task, never here.
#[derive(Debug)]
struct ImportGuard {
	token: u64,
	conn: std::rc::Weak<ConnShared>,
}

impl Drop for ImportGuard {
	fn drop(&mut self) {
		if let Some(conn) = self.conn.upgrade() {
			conn.gc_pending.borrow_mut().push(self.token);
			conn.gc_wakeup.notify_one();
		}
	}
}

impl Ref {
	/// The underlying wire reference (for the rare power-user path).
	pub fn reference(&self) -> Reference {
		self.reference.clone()
	}

	// A reference with no GC death rite, the default for everything but a
	// GC-tracked fetch result.
	fn bare(reference: Reference) -> Ref {
		Ref {
			reference,
			guard: None,
		}
	}
}

impl From<&Ref> for Argument {
	fn from(r: &Ref) -> Argument {
		Argument::Reference(r.reference.clone())
	}
}

impl From<Ref> for Argument {
	fn from(r: Ref) -> Argument {
		Argument::Reference(r.reference)
	}
}

impl TryFrom<&Argument> for Ref {
	type Error = ();

	/// Lift a capability returned by a `send` (an `Argument::Reference`) back into
	/// a `Ref` you can `send` to, e.g. a capability a coordinator granted you.
	fn try_from(arg: &Argument) -> std::result::Result<Ref, ()> {
		match arg {
			Argument::Reference(reference) => Ok(Ref::bare(reference.clone())),
			_ => Err(()),
		}
	}
}

/// A revocable caretaker over a capability (ADR-0064), returned by
/// [`Connection::caretaker`]. Hand [`proxy`](Caretaker::proxy) to a partner; call
/// [`revoke`](Caretaker::revoke) to sever it, after which every call through the
/// proxy breaks with `Revoked`.
pub struct Caretaker {
	/// The capability to delegate. Forwards to the wrapped target until revoked.
	pub proxy: Ref,
	/// The revoke flag the proxy actor reads on every call, cleared here, read in
	/// the trampoline, the way Zig's `RevokeCell` is shared between handle and actor.
	live: Arc<AtomicBool>,
}

impl Caretaker {
	/// Sever the proxy: subsequent calls through it break with `Revoked`.
	/// Idempotent. Clears the shared flag the proxy actor reads, so it takes effect
	/// with no round trip (a closed connection has already severed every proxy).
	pub fn revoke(&self) {
		self.live.store(false, Ordering::SeqCst);
	}
}

// Where a `send` is addressed. A `Ref` names a capability (a near export or a
// far token) as usual; a `Pipeline` names the still-pending answer of an
// earlier far send by its host vow, so the send pipelines at that answer — the
// wire form of promise pipelining. `None` inside `Pipeline` is a local send's
// promise, which has no wire answer to pipeline against and is refused.
// Public only because it appears in the [`AsSendTarget`] trait's plumbing;
// hidden from docs and not meant to be named by applications.
#[doc(hidden)]
pub enum CmdTarget {
	Ref(Reference),
	Pipeline(Option<u64>),
}

/// What a `send` accepts as its target: a capability [`Ref`], or a
/// [`RemotePromise`] from an earlier send to pipeline against. Borrowed in both
/// cases so an unawaited `RemotePromise` can still be awaited later.
pub trait AsSendTarget {
	#[doc(hidden)]
	fn as_send_target(&self) -> CmdTarget;
}

impl AsSendTarget for &Ref {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget::Ref(self.reference.clone())
	}
}

impl AsSendTarget for &RemotePromise {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget::Pipeline(self.vow())
	}
}

// How one send settles when its handle is awaited: a far vow the drain's
// SETTLE/FAIL arms route, a deferred local turn (run on first observation, so
// a `Forward` to a far target can await the wire reply), or a refusal already
// in hand (surfaced on await, the same path a partner break takes).
enum PromiseState {
	Far(u64),
	Local {
		position: u64,
		verb: String,
		args: Vec<Argument>,
	},
	Failed(Error),
}

/// The handle [`Connection::send`] returns: the eventual result of one
/// eventual-send, and — the point of promise pipelining (ADR-0007) — a target
/// you can `send` to before it resolves.
///
/// It is `IntoFuture<Output = Result<Argument>>`, so `conn.send(...).await` yields
/// the reply exactly as a plain future would (a [`Ref`] via `Ref::try_from(&arg)`
/// if the partner returned a capability; a typed `Err` on a break). Pass it
/// *unawaited* — by reference — as the `target` of a later `send` to address the
/// object the answer will resolve to: the dependent call rides a `desc:answer`
/// deliver the partner queues until the answer settles, so a `create -> use`
/// chain costs one round trip instead of one per link:
///
/// ```ignore
/// let task = conn.send(&root, "create", &["x".into()]);   // not awaited
/// conn.send(&task, "assign", &["alice".into()]);           // pipelined at the answer
/// let status = conn.send(&task, "status", &[]).await?;     // settles the chain
/// ```
///
/// A handle awaited for its value resolves once; a handle only used as a target
/// (never awaited) is a dependency anchor whose own reply is dropped — the
/// settle is drain-routed and stored, so an unawaited anchor whose far answer
/// breaks never faults anything.
///
/// The projection verbs [`index`](RemotePromise::index) /
/// [`untag`](RemotePromise::untag) (ADR-0050/ADR-0052) pipeline an element or
/// untag access *at the answer*, before it resolves: each returns a new
/// `RemotePromise` for the projected value, so `task.untag("cell").index(0)`
/// costs no extra round trip.
pub struct RemotePromise {
	state: PromiseState,
	conn: Rc<ConnShared>,
}

impl RemotePromise {
	// The host vow this send's answer settles, or None for a local send (not
	// pipelinable).
	fn vow(&self) -> Option<u64> {
		match self.state {
			PromiseState::Far(vow) => Some(vow),
			_ => None,
		}
	}

	// Issue a projection at this promise's answer and return a new pipelinable
	// promise for the projected value. By `&self`, so a handle can be projected
	// *and* still awaited later for its own value (the late-source-await case).
	fn project(&self, op: ProjectOp) -> RemotePromise {
		let PromiseState::Far(source) = self.state else {
			// A local-send promise has no wire answer to project against; the
			// refusal surfaces when the projected handle is awaited, the same
			// path an unknown pipeline target takes.
			return RemotePromise {
				state: PromiseState::Failed(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"cannot project a local-send promise; await it for a value".to_string(),
				)),
				conn: Rc::clone(&self.conn),
			};
		};
		let mut vow: u64 = 0;
		let rc = match &op {
			ProjectOp::Index(i) => unsafe {
				ffi::pancake_host_vow_index(self.conn.node.raw(), source, *i as u64, &mut vow)
			},
			ProjectOp::Untag(tag) => unsafe {
				ffi::pancake_host_vow_untag(
					self.conn.node.raw(),
					source,
					tag.as_ptr(),
					tag.len(),
					&mut vow,
				)
			},
		};
		let state = match check_host(rc) {
			Ok(()) => {
				self.conn.node.vow_minted(vow);
				PromiseState::Far(vow)
			}
			Err(error) => PromiseState::Failed(error),
		};
		RemotePromise {
			state,
			conn: Rc::clone(&self.conn),
		}
	}

	/// Pipeline an `op:index` for `i` at this answer (ADR-0050): a new
	/// [`RemotePromise`] for the List element of whatever this resolves to.
	pub fn index(&self, i: i64) -> RemotePromise {
		self.project(ProjectOp::Index(i))
	}

	/// Pipeline an `op:untag` for `tag` at this answer (ADR-0052): a new
	/// [`RemotePromise`] for the payload of whatever this resolves to, which must
	/// be a Tagged record whose tag equals `tag`.
	pub fn untag(&self, tag: &str) -> RemotePromise {
		self.project(ProjectOp::Untag(tag.to_string()))
	}
}

// Which projection a `RemotePromise` issues against its answer.
enum ProjectOp {
	Index(i64),
	Untag(String),
}

impl IntoFuture for RemotePromise {
	type Output = Result<Argument>;
	type IntoFuture = Pin<Box<dyn Future<Output = Result<Argument>>>>;

	fn into_future(self) -> Self::IntoFuture {
		Box::pin(async move {
			match self.state {
				PromiseState::Failed(error) => Err(error),
				PromiseState::Far(vow) => {
					// Await the drain-routed completion. The waiter registers
					// synchronously (the row already exists — the mint was the
					// registration), then the kick puts the queued batch on the
					// wire and routes any already-arrived outcome.
					let settled = self.conn.node.await_vow(vow);
					self.conn.node.kick_actions().await;
					settled.await
				}
				PromiseState::Local {
					position,
					verb,
					args,
				} => self.conn.run_local_send(position, verb, args).await,
			}
		})
	}
}

/// A live connection to one OCapN partner — the one object an application holds,
/// over one byte-fed `PancakeHostConn` the shared [`Node`] minted. `!Send` by
/// construction; use it on a single task inside a `LocalSet`. Dropping the
/// handle closes the connection.
pub struct Connection {
	shared: Rc<ConnShared>,
}

/// The per-connection state the handle, the serve task, and the node's action
/// drain share.
pub(crate) struct ConnShared {
	ptr: Cell<*mut ffi::PancakeHostConn>,
	key: usize,
	pub(crate) node: Rc<HostShared>,
	// Inbound bytes read from the wire but not yet consumed by the core's
	// stream delimiter (the unconsumed tail of the last feed).
	inbox: RefCell<Vec<u8>>,
	// The transport halves: the serve task takes the read half for its life;
	// FLUSH drains serialize on the write half's async lock so frames stay
	// whole and in submission order.
	reader: RefCell<Option<Box<dyn AsyncRead + Unpin>>>,
	writer: Rc<tokio::sync::Mutex<Option<Box<dyn AsyncWrite + Unpin>>>>,
	// Set the moment teardown begins (an application close, or the transport
	// reporting EOF), so the serve loop can tell a read cancelled by our own
	// close from a real fault.
	closing: Cell<bool>,
	released: Cell<bool>,
	// Wakes the serve task off its parked read when the connection closes.
	closed: Notify,
	// Wakes the serve task to drain parked GC tokens (a finalizer may fire
	// inside a behavior trampoline, where the release verbs are refused).
	gc_wakeup: Notify,
	// Export position -> hosted cell for the objects this connection hosts, so
	// a `Forward` whose target this side hosts composes in process (and a send
	// to a self-spawned `Ref` runs in process). The cells are host-owned
	// (freed by ctx_free at teardown); this table is cleared before the
	// release that frees them.
	hosted: RefCell<HashMap<u64, *const ActorCell>>,
	// True for an exporter connection the node's action drain dialed to redeem
	// a handoff, so `close()` can sweep it.
	node_dialed: Cell<bool>,
	// Distributed GC (ADR-0063), opt-in and off by default.
	gc: Cell<bool>,
	gc_pending: RefCell<Vec<u64>>,
	// The auto-started serve task's handle; `Connection::serve` takes it.
	serving: Cell<Option<tokio::task::JoinHandle<()>>>,
}

impl ConnShared {
	fn new<S>(ptr: *mut ffi::PancakeHostConn, node: Rc<HostShared>, stream: S) -> Rc<ConnShared>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		let (reader, writer) = tokio::io::split(stream);
		let shared = Rc::new(ConnShared {
			ptr: Cell::new(ptr),
			key: ptr as usize,
			node: Rc::clone(&node),
			inbox: RefCell::new(Vec::new()),
			reader: RefCell::new(Some(Box::new(reader))),
			writer: Rc::new(tokio::sync::Mutex::new(Some(Box::new(writer)))),
			closing: Cell::new(false),
			released: Cell::new(false),
			closed: Notify::new(),
			gc_wakeup: Notify::new(),
			hosted: RefCell::new(HashMap::new()),
			node_dialed: Cell::new(false),
			gc: Cell::new(false),
			gc_pending: RefCell::new(Vec::new()),
			serving: Cell::new(None),
		});
		// Join the node's registry so a FLUSH action can find the transport and
		// a dialed exporter stays reachable for teardown.
		node.register_connection(shared.key, Rc::clone(&shared));
		shared
	}

	pub(crate) fn raw_conn(&self) -> *mut ffi::PancakeHostConn {
		self.ptr.get()
	}

	pub(crate) fn is_node_dialed(&self) -> bool {
		self.node_dialed.get()
	}

	/// The hosted cell behind a near export this connection binds, for
	/// in-process `Forward` composition and the local send arm.
	pub(crate) fn hosted_cell(&self, position: u64) -> Option<*const ActorCell> {
		self.hosted.borrow().get(&position).copied()
	}

	/// Chase a behavior outcome through the locally hosted `Forward` prefix:
	/// while it forwards to a near target this connection hosts, run that
	/// behavior in the same turn (a caretaker over an attenuator composes
	/// exactly as it does over the wire). Returns the terminal — a `Value`, a
	/// `Break`, or the first `Forward` whose target is not hosted here, which
	/// each caller defers its own way: the trampoline through the host's
	/// turn-forward, `send` onto the forwarded send's wire reply, `tell` as a
	/// far tell.
	pub(crate) fn chase_local_forwards(&self, mut outcome: TurnOutcome) -> TurnOutcome {
		// The wire path defers each hop onto a fresh turn, so a forward cycle
		// there loops asynchronously; the local chase runs hops synchronously
		// and must bound them, or a caretaker forwarding to itself spins this
		// loop forever. Legitimate proxy chains are a handful deep.
		const MAX_LOCAL_FORWARD_HOPS: usize = 256;
		let mut hops = 0usize;
		loop {
			let TurnOutcome::Forward { target, verb, args } = outcome else {
				return outcome;
			};
			hops += 1;
			if hops > MAX_LOCAL_FORWARD_HOPS {
				return TurnOutcome::Break(
					"forward cycle: the local forward chain never terminates".to_string(),
				);
			}
			let hosted = match &target {
				Reference::Near { id, .. } => self.hosted_cell(*id),
				_ => None,
			};
			let Some(cell) = hosted else {
				return TurnOutcome::Forward { target, verb, args };
			};
			// The cell is host-owned and alive while its connection is
			// unreleased; the hosted table is cleared before the release that
			// frees it.
			let cell = unsafe { &*cell };
			outcome = (cell.behavior.borrow_mut())(&verb, &args);
		}
	}

	// Run the hosted behavior at `position` and chase its Forward prefix, or
	// None when this side does not host it — the one lookup/run/chase prefix
	// under the local send and tell arms.
	fn run_hosted(&self, position: u64, verb: &str, args: &[Argument]) -> Option<TurnOutcome> {
		let cell = self.hosted_cell(position)?;
		let outcome = {
			// The local-turn marker: a behavior that closes (or drops) its own
			// captured `Connection` mid-run would otherwise take
			// `close_transport`'s immediate-release arm and free this very
			// cell's `Box<ActorCell>` while its `behavior.borrow_mut()` frame
			// is still on the stack. With the marker, `inside_turn()` is true
			// and the release parks, exactly as on the wire path's `TurnGuard`.
			let _guard = LocalRunGuard::enter();
			let first = {
				// Host-owned and alive while the connection is unreleased, as above.
				let cell = unsafe { &*cell };
				(cell.behavior.borrow_mut())(verb, args)
			};
			self.chase_local_forwards(first)
		};
		// The marker dropped before anything can await (the callers' own
		// Forward-to-far send comes after this returns): run the parked
		// releases and kick the drain, mirroring the feed path.
		drain_pending_releases();
		self.node.schedule_kick();
		Some(outcome)
	}

	fn closing(&self) -> bool {
		self.closing.get() || self.released.get()
	}

	fn guard_open(&self) -> Result<()> {
		if self.released.get() {
			Err(Error::with_detail(
				sys::ERR_CLOSED,
				"connection closed".to_string(),
			))
		} else {
			Ok(())
		}
	}

	fn session_open(&self) -> bool {
		!self.released.get() && unsafe { ffi::pancake_host_conn_session_open(self.ptr.get()) } == 1
	}

	// ── Construction: the handshake pump ───────────────────────────────────────

	// Drive the freshly opened connection's keyed handshake to an open session.
	// The signed op:start-session was encoded by the open; its FLUSH is on the
	// action queue, so the drain puts it on the wire first.
	async fn run_handshake(self: &Rc<ConnShared>) -> Result<()> {
		self.node.kick_actions().await;
		let Some(mut reader) = self.reader.borrow_mut().take() else {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"the connection's read half is already taken".to_string(),
			));
		};
		let result = async {
			let mut chunk = vec![0u8; READ_CHUNK];
			while !self.session_open() {
				let n = reader.read(&mut chunk).await.map_err(io_err)?;
				if n == 0 {
					return Err(Error::with_detail(
						sys::ERR_CLOSED,
						"connection closed during the OCapN handshake".to_string(),
					));
				}
				self.feed(&chunk[..n]).await?;
			}
			Ok(())
		}
		.await;
		*self.reader.borrow_mut() = Some(reader);
		result
	}

	// ── The pump ────────────────────────────────────────────────────────────────

	// Spawn the inbound serve loop as its own task. Runs from establish, so a
	// connection pumps from birth: an accepted partner's traffic and a dialed
	// exporter's withdraw both arrive without an explicit `serve()` call.
	fn spawn_serve(self: &Rc<ConnShared>) {
		let shared = Rc::clone(self);
		let handle = tokio::task::spawn_local(async move {
			shared.serve_loop().await;
		});
		self.serving.set(Some(handle));
	}

	async fn serve_loop(self: Rc<ConnShared>) {
		let Some(mut reader) = self.reader.borrow_mut().take() else {
			return;
		};
		let mut chunk = vec![0u8; READ_CHUNK];
		let result: Result<()> = async {
			// Frames that arrived behind the handshake's tail are still
			// buffered; dispatch them before parking on the wire.
			if !self.inbox.borrow().is_empty() {
				self.feed(&[]).await?;
			}
			loop {
				if self.released.get() {
					return Ok(());
				}
				tokio::select! {
					biased;
					_ = self.closed.notified() => return Ok(()),
					_ = self.gc_wakeup.notified() => {
						// A finalizer parked tokens; release them on this, the
						// pumping task.
						self.drain_gc();
						self.node.kick_actions().await;
					}
					read = reader.read(&mut chunk) => {
						match read {
							Ok(0) => return Ok(()), // clean EOF
							Ok(n) => self.feed(&chunk[..n]).await?,
							// A read cancelled by our own close is a clean
							// shutdown; any other failure ends the loop and the
							// teardown below breaks the vows.
							Err(error) => {
								if self.closing() {
									return Ok(());
								}
								return Err(io_err(error));
							}
						}
					}
				}
			}
		}
		.await;
		// A feed refusal already wrote the typed op:abort for the partner and
		// the teardown below carries the local consequence; the error itself
		// has no caller on a background task.
		let _ = result;
		// The wire is gone: pending far vows can never settle, so break them
		// and release the conn, freeing the fd. Idempotent with an application
		// `close()`.
		if !self.closing() {
			self.closing.set(true);
			let message = b"connection closed";
			let _ = unsafe {
				ffi::pancake_host_conn_break_far_vows(
					self.ptr.get(),
					message.as_ptr(),
					message.len(),
				)
			};
			// Route the break's FAIL completions before the release retires the
			// connection.
			self.node.kick_actions().await;
			self.close_transport();
		}
	}

	fn feed_raw(&self, bytes: &[u8]) -> (i32, usize) {
		let mut consumed: usize = 0;
		let rc = unsafe {
			ffi::pancake_host_conn_feed_bytes(
				self.ptr.get(),
				bytes.as_ptr(),
				bytes.len(),
				&mut consumed,
			)
		};
		(rc, consumed)
	}

	// Append freshly read bytes onto the inbox and feed the core's stream
	// delimiter: the session's codec splits each complete frame off the front —
	// both codecs, both frame shapes, the frame cap enforced during the scan —
	// and dispatches it (behavior trampolines fire and completions queue
	// inside), then the actions the dispatch queued drain. Only the unconsumed
	// tail stays in the inbox. The inbox is taken out for the synchronous feed
	// so no `RefCell` borrow is held across an FFI call that can fire the
	// trampoline.
	async fn feed(self: &Rc<ConnShared>, chunk: &[u8]) -> Result<()> {
		{
			let mut inbox = self.inbox.borrow_mut();
			inbox.extend_from_slice(chunk);
		}
		let mut refusal: Option<i32> = None;
		{
			// One call: the core delimits and dispatches every complete frame in
			// the buffer itself, stops at a partial tail, and during the
			// handshake stops at the frame that opens the session — so this one
			// body serves establish and steady state alike.
			let mut buf = std::mem::take(&mut *self.inbox.borrow_mut());
			if !self.released.get() {
				let (rc, consumed) = self.feed_raw(&buf);
				if rc != sys::OK {
					refusal = Some(rc);
				} else {
					buf.drain(..consumed);
				}
			}
			// Put the unconsumed tail back before anything can await.
			let mut inbox = self.inbox.borrow_mut();
			buf.extend_from_slice(&inbox);
			*inbox = buf;
		}
		crate::host::drain_pending_releases();
		if let Some(rc) = refusal {
			return Err(self.feed_refusal(rc).await);
		}
		self.node.kick_actions().await;
		Ok(())
	}

	// The feed refusal choreography: capture the host's last error BEFORE the
	// abort reader can clobber it, read the typed cause, write the typed
	// op:abort the core already projected so the partner hears why, then
	// surface the typed error.
	async fn feed_refusal(self: &Rc<ConnShared>, rc: i32) -> Error {
		let message = host_last_error();
		let abort = self.last_abort();
		// The transport may already be gone; the local typed error stands.
		let _ = self.flush_outbound().await;
		Error::with_transport_detail(rc, message).with_abort(abort)
	}

	/// The typed cause of this connection's most recent local dispatch failure,
	/// or `None` when none has been recorded. The flat per-feed error code
	/// names the failure family; this names the member.
	fn last_abort(&self) -> Option<AbortInfo> {
		if self.released.get() {
			return None;
		}
		let mut raw: sys::PancakeLastAbort = unsafe { core::mem::zeroed() };
		let rc = unsafe { ffi::pancake_host_conn_last_abort(self.ptr.get(), &mut raw) };
		if rc != sys::OK {
			return None;
		}
		// The C views are process-static; copy them into owned strings so the
		// info outlives any later host call.
		let text = |ptr: *const u8, len: usize| -> String {
			if ptr.is_null() || len == 0 {
				String::new()
			} else {
				String::from_utf8_lossy(unsafe { core::slice::from_raw_parts(ptr, len) })
					.into_owned()
			}
		};
		Some(AbortInfo {
			domain: AbortDomain::from_abi(raw.domain),
			kind: (raw.has_kind != 0).then(|| text(raw.kind_name, raw.kind_name_len)),
			message: text(raw.message, raw.message_len),
			error_name: text(raw.error_name, raw.error_name_len),
		})
	}

	/// Drain every encoded outbound frame on this connection and write it to
	/// the transport — how a FLUSH action lands. Writes serialize on the write
	/// half's lock, so frames stay whole and in submission order. The managed
	/// frame is held across the awaited write and released after it — zero
	/// frame copy.
	pub(crate) async fn flush_outbound(self: &Rc<ConnShared>) -> Result<()> {
		let writer = Rc::clone(&self.writer);
		let mut guard = writer.lock().await;
		loop {
			if self.released.get() {
				return Ok(());
			}
			let mut raw: sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
			let rc = unsafe { ffi::pancake_host_conn_take_outbound(self.ptr.get(), &mut raw) };
			if rc == sys::WOULD_BLOCK {
				break;
			}
			check_host(rc)?;
			let frame = FrameGuard(raw);
			let Some(sink) = guard.as_mut() else {
				return Ok(()); // the transport is gone; the frame is released
			};
			sink.write_all(frame.bytes()).await.map_err(io_err)?;
		}
		if let Some(sink) = guard.as_mut() {
			sink.flush().await.map_err(io_err)?;
		}
		Ok(())
	}

	// ── Teardown ────────────────────────────────────────────────────────────────

	/// Close just this connection, without touching the node's other
	/// connections: stop the transport, then retire the node's entry and free
	/// the host handle (its still-parked far vows break inside the release), so
	/// no foreign call touches a freed connection. A release refused inside a
	/// behavior callback is parked for the next drain, never dropped.
	pub(crate) fn close_transport(self: &Rc<ConnShared>) {
		self.closing.set(true);
		self.closed.notify_waiters();
		// Drop the halves this handle still holds so the fd closes promptly;
		// the serve task's read half drops as its loop exits.
		*self.reader.borrow_mut() = None;
		if let Ok(mut writer) = self.writer.try_lock() {
			*writer = None;
		}
		if self.released.get() {
			return;
		}
		self.released.set(true);
		self.node.unregister_connection(self.key);
		// The cells behind these pointers are freed by the release below;
		// nothing may resolve through them afterwards.
		self.hosted.borrow_mut().clear();
		let ptr = self.ptr.replace(core::ptr::null_mut());
		if !ptr.is_null() {
			if inside_turn() {
				park_conn_release(ptr, Rc::clone(&self.node));
			} else {
				unsafe { ffi::pancake_host_conn_release(ptr) };
			}
		}
		// The release queued FAIL completions (and sibling withdraws may have
		// failed closed): route them now.
		self.node.schedule_kick();
	}

	pub(crate) fn mark_node_dialed(&self) {
		self.node_dialed.set(true);
	}

	/// Take the serve task's handle (the `Connection::serve` future awaits it).
	fn take_serving(&self) -> Option<tokio::task::JoinHandle<()>> {
		self.serving.take()
	}

	// ── Hosting ─────────────────────────────────────────────────────────────────

	// Register `behavior` as a hosted object of this connection: inside a
	// served turn through the turn-time spawn (the host refuses the top-level
	// one there), else through the connection spawn.
	fn spawn_actor(self: &Rc<ConnShared>, behavior: InternalBehavior) -> Result<Ref> {
		self.guard_open()?;
		self.drain_gc();
		let cell = Box::into_raw(Box::new(ActorCell {
			behavior: RefCell::new(behavior),
			conn: Some(Rc::downgrade(self)),
		}));
		let position = match current_turn_for(self.key) {
			Some(turn) => turn_spawn(turn, cell)?,
			None => {
				let mut position: u64 = 0;
				let rc = unsafe {
					ffi::pancake_host_conn_spawn(
						self.ptr.get(),
						trampoline,
						cell as *mut core::ffi::c_void,
						ctx_free,
						&mut position,
					)
				};
				if rc != sys::OK {
					unsafe { reclaim_refused_cell(rc, cell) };
					return Err(check_host(rc).unwrap_err());
				}
				position
			}
		};
		self.hosted
			.borrow_mut()
			.insert(position, cell as *const ActorCell);
		Ok(Ref::bare(Reference::Near {
			id: position,
			promise: false,
		}))
	}

	fn publish_actor(self: &Rc<ConnShared>, name: &str, behavior: InternalBehavior) -> Result<Ref> {
		self.guard_open()?;
		self.drain_gc();
		let cell = Box::into_raw(Box::new(ActorCell {
			behavior: RefCell::new(behavior),
			conn: Some(Rc::downgrade(self)),
		}));
		let mut position: u64 = 0;
		let rc = unsafe {
			ffi::pancake_host_conn_publish(
				self.ptr.get(),
				name.as_ptr(),
				name.len(),
				trampoline,
				cell as *mut core::ffi::c_void,
				ctx_free,
				&mut position,
			)
		};
		if rc != sys::OK {
			unsafe { reclaim_refused_cell(rc, cell) };
			return Err(check_host(rc).unwrap_err());
		}
		self.hosted
			.borrow_mut()
			.insert(position, cell as *const ActorCell);
		Ok(Ref::bare(Reference::Near {
			id: position,
			promise: false,
		}))
	}

	// ── The verbs' shared plumbing ─────────────────────────────────────────────

	// The shared fetch/enliven wait: the mint already registered the vow; kick
	// the drain so the deliver leaves now, and await the drain-routed outcome.
	async fn await_minted(self: &Rc<ConnShared>, vow: u64) -> Result<Argument> {
		self.node.vow_minted(vow);
		let settled = self.node.await_vow(vow);
		self.node.kick_actions().await;
		settled.await
	}

	// The send spine both `Connection::send` and a local `Forward`'s far arm
	// ride: mint the vow (which IS the registration) under the same synchronous
	// call stack, then hand back the promise.
	fn send_promise(
		self: &Rc<ConnShared>,
		target: CmdTarget,
		verb: &str,
		args: &[Argument],
	) -> RemotePromise {
		let failed = |error: Error, conn: &Rc<ConnShared>| RemotePromise {
			state: PromiseState::Failed(error),
			conn: Rc::clone(conn),
		};
		if let Err(error) = self.guard_open() {
			return failed(error, self);
		}
		self.drain_gc();
		// A send to an object this side hosts runs its behavior in process — a
		// proxy over a *far* target then defers onto the wire reply, the same
		// forward semantics a partner's delivery gets (ADR-0064).
		if let CmdTarget::Ref(Reference::Near { id, .. }) = &target {
			if self.hosted_cell(*id).is_some() {
				return RemotePromise {
					state: PromiseState::Local {
						position: *id,
						verb: verb.to_string(),
						args: args.to_vec(),
					},
					conn: Rc::clone(self),
				};
			}
		}
		let mut arena = SendArena::default();
		let (args_ptr, args_len) = match arena.build(args) {
			Ok(built) => built,
			Err(error) => return failed(error, self),
		};
		let mut vow: u64 = 0;
		let rc = match &target {
			CmdTarget::Ref(reference) => {
				let wire = match reference.to_sys() {
					Ok(wire) => wire,
					Err(error) => return failed(error, self),
				};
				unsafe {
					ffi::pancake_host_conn_send(
						self.ptr.get(),
						&wire,
						verb.as_ptr(),
						verb.len(),
						args_ptr,
						args_len,
						&mut vow,
					)
				}
			}
			// Promise pipelining: eventual-send to the unresolved answer. A
			// local send's promise has no wire answer to pipeline against.
			CmdTarget::Pipeline(None) => {
				return failed(
					Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						"cannot pipeline against a local-send promise; await it for a Ref"
							.to_string(),
					),
					self,
				)
			}
			CmdTarget::Pipeline(Some(source)) => unsafe {
				ffi::pancake_host_vow_send(
					self.node.raw(),
					*source,
					verb.as_ptr(),
					verb.len(),
					args_ptr,
					args_len,
					&mut vow,
				)
			},
		};
		if let Err(error) = check_host(rc) {
			return failed(error, self);
		}
		self.node.vow_minted(vow);
		// The deliver is queued; the kick (scheduled, so a synchronous batch of
		// pipelined sends travels together) flushes it whether or not the
		// handle is ever awaited.
		self.node.schedule_kick();
		RemotePromise {
			state: PromiseState::Far(vow),
			conn: Rc::clone(self),
		}
	}

	// The local arm of `send`, run on first observation: a `Forward` to another
	// object this side hosts composes in process; a `Forward` to a far target
	// defers the answer onto the forwarded send's reply (ADR-0064); a behavior
	// error breaks with its own words, as over the wire.
	async fn run_local_send(
		self: Rc<ConnShared>,
		position: u64,
		verb: String,
		args: Vec<Argument>,
	) -> Result<Argument> {
		let Some(outcome) = self.run_hosted(position, &verb, &args) else {
			return Err(Error::broken("no such hosted object".to_string()));
		};
		match outcome {
			TurnOutcome::Value(value) => Ok(value),
			TurnOutcome::Break(message) => Err(Error::broken(message)),
			TurnOutcome::Forward { target, verb, args } => {
				// A far (or promise) target: the local answer settles on the
				// forwarded send's wire reply.
				self.send_promise(CmdTarget::Ref(target), &verb, &args)
					.await
			}
		}
	}

	// The local arm of `tell`: deferred to its own task so a behavior telling a
	// self-hosted object never re-enters the running cell's borrow; the result
	// is discarded (no answer), a far forward continues as a far tell, and a
	// behavior error breaks nothing — there is no answer to break.
	// Called with no `LocalSet` running (practically unreachable: every path to
	// a live `Connection` already required one), `try_spawn_local` swallows the
	// spawn and the tell is lost, a tolerated loss for a fire-and-forget verb
	// with no answer to strand.
	fn tell_local(self: &Rc<ConnShared>, position: u64, verb: String, args: Vec<Argument>) {
		let shared = Rc::clone(self);
		try_spawn_local(async move {
			if let Some(TurnOutcome::Forward { target, verb, args }) =
				shared.run_hosted(position, &verb, &args)
			{
				let _ = shared.tell_wire(&target, &verb, &args);
			}
		});
	}

	fn tell_wire(
		self: &Rc<ConnShared>,
		target: &Reference,
		verb: &str,
		args: &[Argument],
	) -> Result<()> {
		let wire = target.to_sys()?;
		let mut arena = SendArena::default();
		let (args_ptr, args_len) = arena.build(args)?;
		check_host(unsafe {
			ffi::pancake_host_conn_tell(
				self.ptr.get(),
				&wire,
				verb.as_ptr(),
				verb.len(),
				args_ptr,
				args_len,
			)
		})?;
		self.node.schedule_kick();
		Ok(())
	}

	// ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

	// Drain the parked GC releases: one release delta per reclaimed token, then
	// a kick so the op:gc-exports flushes. Best-effort — a refused release
	// strands a partner export reclaimed at teardown, never a fault. Called at
	// the head of the connection's own verbs and by the serve task when a
	// finalizer pokes it.
	fn drain_gc(&self) {
		if self.released.get() {
			return;
		}
		let pending: Vec<u64> = std::mem::take(&mut *self.gc_pending.borrow_mut());
		if pending.is_empty() {
			return;
		}
		for token in pending {
			let _ = unsafe { ffi::pancake_host_gc_release(self.node.raw(), token, 1) };
		}
		self.node.schedule_kick();
	}
}

// Holds one drained managed frame across the awaited transport write and
// releases it after — the zero-copy outbound path.
struct FrameGuard(sys::PancakeManagedFrame);

impl FrameGuard {
	fn bytes(&self) -> &[u8] {
		if self.0.bytes.is_null() || self.0.len == 0 {
			&[]
		} else {
			unsafe { core::slice::from_raw_parts(self.0.bytes, self.0.len) }
		}
	}
}

impl Drop for FrameGuard {
	fn drop(&mut self) {
		unsafe { sys::pancake_managed_frame_release(&mut self.0) };
	}
}

impl Connection {
	/// Mint the dialing half of a connection to the peer `locator_uri` names
	/// over `stream` (already connected) and drive the keyed handshake open.
	/// The transport seam the iroh module builds on. Binding-internal.
	pub(crate) async fn establish_dialed<S>(
		node: Rc<HostShared>,
		locator_uri: &str,
		stream: S,
	) -> Result<Connection>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		let mut ptr: *mut ffi::PancakeHostConn = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_conn_open_dialed(
				node.raw(),
				locator_uri.as_ptr(),
				locator_uri.len(),
				&mut ptr,
			)
		})?;
		Connection {
			shared: ConnShared::new(ptr, node, stream),
		}
		.establish()
		.await
	}

	/// Mint the accepting half over a connection the caller's own listener
	/// produced: the keyed op:start-session signs the listener's own
	/// `transport_name`/`designator` — the address a partner can actually dial,
	/// and the locator a give made on this node names as the exporter location.
	/// Every node-wide giftable is published on the new connection before the
	/// open returns, so a dialer's pipelined fetch finds it. Binding-internal.
	pub(crate) async fn establish_accepted<S>(
		node: Rc<HostShared>,
		transport_name: &str,
		designator: &str,
		stream: S,
	) -> Result<Connection>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		let mut ptr: *mut ffi::PancakeHostConn = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_conn_open_accepted(
				node.raw(),
				transport_name.as_ptr(),
				transport_name.len(),
				designator.as_ptr(),
				designator.len(),
				&mut ptr,
			)
		})?;
		Connection {
			shared: ConnShared::new(ptr, node, stream),
		}
		.establish()
		.await
	}

	// Drive the keyed handshake to an open session and start the serve loop,
	// abandoning the connection on any failure (release + transport close) so a
	// rude partner costs one accept, never the listener.
	async fn establish(self) -> Result<Connection> {
		match self.shared.run_handshake().await {
			Ok(()) => {
				self.shared.spawn_serve();
				Ok(self)
			}
			Err(error) => {
				self.shared.close_transport();
				// Skip the Drop teardown; close_transport already ran.
				Err(error)
			}
		}
	}

	/// Dial `addr` and return a ready connection (the keyed `op:start-session`
	/// exchange has completed before this resolves, so a `fetch`/`send` rides
	/// an established session). Must be called inside a `LocalSet` (the handle
	/// graph is `!Send`). The connection is its own node, with a fresh retained
	/// identity; use [`connect_with_node`](Connection::connect_with_node) to
	/// share one node identity across several connections (the gifter half of a
	/// three-party handoff).
	pub async fn connect<A: ToSocketAddrs>(addr: A) -> Result<Connection> {
		Connection::connect_with_node(addr, Node::new_node()).await
	}

	/// Dial `addr` sharing `node` — one node identity and gift registry across
	/// several connections (the gifter half of a three-party handoff, ADR-0009).
	/// A capability fetched on one connection of the node and returned on another
	/// is recognized as foreign and re-gifted rather than mis-encoded. Must be
	/// called inside a `LocalSet`.
	pub async fn connect_with_node<A: ToSocketAddrs>(addr: A, node: Node) -> Result<Connection> {
		let stream = TcpStream::connect(addr).await.map_err(io_err)?;
		let peer = stream.peer_addr().map_err(io_err)?;
		let locator = tcp_locator(&peer.ip().to_string(), peer.port());
		Connection::establish_dialed(node.shared(), &locator, stream).await
	}

	/// The connection's shared node, its retained identity and gift registry.
	/// Shared by every connection of one node, so the gifter half of a handoff
	/// can reach a sibling connection's session keys. An application reads it to
	/// publish node-giftables ([`Node::publish_giftable`]), share one identity
	/// across dials, or set the redeem posture.
	pub fn node(&self) -> Node {
		Node::from_shared(Rc::clone(&self.shared.node))
	}

	/// Record the verbatim exporter-location bytes (from
	/// [`encode_peer_locator`](crate::encode_peer_locator))
	/// the gifter embeds when *this* connection is the exporter side of a handoff
	/// this node originates (ADR-0009). Needed when the partner's signed location
	/// is not dialable on its own — an iroh partner signs only its node id, so a
	/// gifter that learned the exporter's `direct-addresses` out of band sets the
	/// full locator here. Unset, origination falls back to the partner's signed
	/// location.
	pub fn set_exporter_locator(&self, raw: Vec<u8>) {
		if self.shared.guard_open().is_err() {
			return;
		}
		let _ = check_host(unsafe {
			ffi::pancake_host_conn_set_exporter_location(
				self.shared.ptr.get(),
				raw.as_ptr(),
				raw.len(),
			)
		});
	}

	/// Opt this connection into distributed GC (ADR-0063), off by default. Once
	/// on, a far capability returned by [`fetch`](Connection::fetch) releases its
	/// import to the partner — a single `op:gc-exports` delta, routed through the
	/// host to the import's home connection — when the last `Ref` to it is
	/// dropped, so the partner can release the matching export. Capabilities
	/// lifted elsewhere (a `send` reply, a delivered argument via `Ref::try_from`,
	/// an `enliven` result the dedup cache owns) are outside this seam. Returns
	/// `self` for chaining after `connect`.
	pub fn with_gc(self) -> Connection {
		self.shared.gc.set(true);
		self
	}

	// Wrap a fetched capability into a `Ref`. The `Ref` holds a node-unique
	// token (ADR-0069) — only ids in the token range are tracked, the INVERSE
	// of the old wire-position guard — and the host resolves the token to its
	// home connection and real wire import when the release fires. The guard
	// captures only the bare token, never the `Ref`, so it cannot resurrect the
	// handle whose death it waits on.
	fn track_import(&self, reference: Reference) -> Ref {
		if self.shared.gc.get() {
			if let Reference::Far { id, .. } = reference {
				if id >= sys::REDEEMED_TOKEN_BASE {
					return Ref {
						reference,
						guard: Some(Rc::new(ImportGuard {
							token: id,
							conn: Rc::downgrade(&self.shared),
						})),
					};
				}
			}
		}
		Ref::bare(reference)
	}

	/// Spawn a local actor and return a capability to it. Pass the returned `Ref`
	/// as a `send` argument to hand a partner a callback. The position comes from
	/// the session's one export allocator, so it can never alias a bootstrap or
	/// resolver export. Callable from inside a served turn (a factory's `create`
	/// minting the task it replies with).
	pub async fn spawn(
		&self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		self.shared.spawn_actor(outcome_behavior(behavior))
	}

	/// Publish an actor so a partner can [`fetch`](Connection::fetch) it by `name`
	/// (a swiss-number). Returns a capability to it.
	pub async fn publish(
		&self,
		name: &str,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		self.shared.publish_actor(name, outcome_behavior(behavior))
	}

	/// Wrap `target` (local or far) in a revocable caretaker (ADR-0064). Returns a
	/// [`Caretaker`] whose `proxy` is an ordinary capability you hand a partner;
	/// every call through it forwards to `target` until you
	/// [`revoke`](Caretaker::revoke) it, after which each call breaks with
	/// `Revoked`. `target` may be a capability you imported over the wire — the
	/// proxy forwards transparently — so this hands out a revocable view of
	/// authority you do not own locally.
	pub async fn caretaker(&self, target: &Ref) -> Result<Caretaker> {
		let live = Arc::new(AtomicBool::new(true));
		let flag = Arc::clone(&live);
		let target = target.reference();
		let behavior: InternalBehavior = Box::new(move |verb, args| {
			if !flag.load(Ordering::SeqCst) {
				TurnOutcome::Break("Revoked".to_string())
			} else {
				TurnOutcome::Forward {
					target: target.clone(),
					verb: verb.to_string(),
					args: args.to_vec(),
				}
			}
		});
		Ok(Caretaker {
			proxy: self.shared.spawn_actor(behavior)?,
			live,
		})
	}

	/// Wrap `target` (local or far) in an attenuator (ADR-0064): a proxy that
	/// forwards only the calls whose verb is in `verbs` and breaks every other
	/// with `Attenuated`. Returns the proxy capability to hand a partner. `target`
	/// may be a wire-imported capability, so this narrows authority you hold.
	pub async fn attenuate(&self, target: &Ref, verbs: &[&str]) -> Result<Ref> {
		let allowed: std::collections::HashSet<String> =
			verbs.iter().map(|verb| verb.to_string()).collect();
		let target = target.reference();
		let behavior: InternalBehavior = Box::new(move |verb, args| {
			if !allowed.contains(verb) {
				TurnOutcome::Break("Attenuated".to_string())
			} else {
				TurnOutcome::Forward {
					target: target.clone(),
					verb: verb.to_string(),
					args: args.to_vec(),
				}
			}
		});
		self.shared.spawn_actor(behavior)
	}

	/// Fetch a partner's published capability by `name`. Returns a `Ref` you can
	/// `send` to. The canonical fetch lives in the library: one call registers
	/// the bootstrap import, allocates the answer, and queues the deliver; the
	/// host enrolls the fulfilled capability under a node-unique token (ADR-0069)
	/// before the completion is queued, so a return re-gifts the right home.
	/// Rejects with the typed break when the partner refuses the fetch, and with
	/// a broken error when it fulfills with something that is not a live
	/// capability.
	pub async fn fetch(&self, name: &str) -> Result<Ref> {
		self.fetch_like(name.as_bytes(), name, ffi::pancake_host_conn_fetch, true)
			.await
	}

	// The one mint/await/classify body under `fetch` and `enliven`: mint the
	// host vow with `mint`, await its drain-routed completion, and classify —
	// only a live near/far reference is a capability this surface can hand
	// out; anything else would leak a half-supported kind. `track` marks the
	// Far arm for distributed GC: a fetch's import is finalizer-tracked, an
	// enliven's is owned by the ADR-0012 dedup cache instead (ADR-0063).
	async fn fetch_like(
		&self,
		swiss: &[u8],
		label: &str,
		mint: unsafe extern "C" fn(*mut ffi::PancakeHostConn, *const u8, usize, *mut u64) -> i32,
		track: bool,
	) -> Result<Ref> {
		self.shared.guard_open()?;
		self.shared.drain_gc();
		let mut vow: u64 = 0;
		check_host(unsafe { mint(self.shared.ptr.get(), swiss.as_ptr(), swiss.len(), &mut vow) })?;
		let value = self.shared.await_minted(vow).await?;
		match value {
			Argument::Reference(reference @ Reference::Near { .. }) => Ok(Ref::bare(reference)),
			Argument::Reference(reference @ Reference::Far { .. }) if track => {
				Ok(self.track_import(reference))
			}
			Argument::Reference(reference @ Reference::Far { .. }) => Ok(Ref::bare(reference)),
			_ => Err(Error::broken(format!(
				"{label:?} did not resolve to a capability"
			))),
		}
	}

	/// Enliven a sturdyref against this connection (ADR-0012): bring the durable
	/// `(peer, swissnum)` to life as a live [`Ref`]. Parses `sturdyref` for its
	/// swissnum, then fetches it through the host's dedup cache — a repeat
	/// enliven of the same swissnum on this session short-circuits with no wire
	/// traffic (its completion is queued before the minting call returns). The
	/// connection must already be open to the sturdyref's peer; the sans-io core
	/// tracks no remote locator and never dials. Rejects with the typed break
	/// when the partner refuses, and with a broken error on a non-capability
	/// fulfillment.
	pub async fn enliven(&self, sturdyref: &str) -> Result<Ref> {
		let swissnum = crate::uri::parse_sturdyref(sturdyref)?
			.swissnum
			.into_bytes();
		self.fetch_like(&swissnum, "enliven", ffi::pancake_host_conn_enliven, false)
			.await
	}

	/// Eventual-send `verb(args)` to `target` and return a [`RemotePromise`] for
	/// the reply. `await` it for the value (a capability via `Ref::try_from`; a
	/// typed `Err` on a partner break).
	///
	/// `target` is a capability `&Ref` *or* a `&RemotePromise` from an earlier
	/// send: passing the latter pipelines (ADR-0007) — the call is addressed at
	/// the answer that send will resolve, so a dependent chain costs one round
	/// trip instead of one per link. `args` may contain capabilities via
	/// `Into<Argument>`. A `Ref` this connection spawned runs in process; a
	/// partner's rides the wire, and a redeemed or fetched token routes to the
	/// exporter connection that hosts it, transparently.
	pub fn send<T: AsSendTarget>(&self, target: T, verb: &str, args: &[Argument]) -> RemotePromise {
		self.shared
			.send_promise(target.as_send_target(), verb, args)
	}

	/// Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and
	/// no reply comes back, so a notification or broadcast costs one deliver
	/// rather than a deliver plus a reply. Returns once the deliver is queued on
	/// the host; the scheduled drain flushes it, in order with the sends around
	/// it.
	pub fn tell(&self, target: &Ref, verb: &str, args: &[Argument]) -> Result<()> {
		self.shared.guard_open()?;
		self.shared.drain_gc();
		// A tell to an object this side hosts runs its behavior in process; the
		// result is discarded (no answer), a far forward continues as a far
		// tell, and a behavior error breaks nothing — there is no answer to
		// break.
		if let Reference::Near { id, .. } = &target.reference {
			if self.shared.hosted_cell(*id).is_some() {
				self.shared.tell_local(*id, verb.to_string(), args.to_vec());
				return Ok(());
			}
		}
		self.shared.tell_wire(&target.reference, verb, args)
	}

	/// Run the inbound event loop in the background (it already runs from
	/// `connect`); the returned future completes when the connection closes.
	/// Calling it without awaiting is fine, the loop runs regardless. The
	/// `Connection` handle should stay alive while the loop serves: dropping it
	/// closes the connection under the partner.
	pub fn serve(&self) -> impl std::future::Future<Output = ()> {
		let handle = self.shared.take_serving();
		async move {
			if let Some(handle) = handle {
				let _ = handle.await;
			}
		}
	}

	// The DIAL arm marks the exporter connection it dialed so `close()` can
	// sweep it, and reads the raw conn for `pancake_host_dialed`.
	// Binding-internal.
	pub(crate) fn mark_node_dialed(&self) {
		self.shared.mark_node_dialed();
	}

	pub(crate) fn raw_conn(&self) -> *mut ffi::PancakeHostConn {
		self.shared.raw_conn()
	}

	/// Close the connection and every exporter connection its node dialed for
	/// handoffs. A running [`serve`](Connection::serve) completes; pending vows
	/// settle broken.
	pub fn close(&self) {
		self.shared.closing.set(true);
		self.shared.node.close_exporters();
		self.shared.close_transport();
	}
}

impl Drop for Connection {
	fn drop(&mut self) {
		// Close just this connection (never the node's other exporters — a
		// dialed exporter's own teardown must not sweep its siblings).
		self.shared.close_transport();
	}
}

/// Dial an exporter a DIAL action names, keyed with the node's retained
/// identity, and bind the result to that same node so the redeemed capability
/// and any further handoff it triggers share one identity and connection
/// table. The action carries the locator's parsed pieces, so nothing re-parses
/// the URI grammar here beyond the tcp host:port split. An `iroh` give with
/// direct-address hints dials them with no discovery service (`Direct`); a
/// bare node id resolves by id under the node's configured redeem posture
/// (default `Discovery`; a relay-policy node lowers it), so one give shape
/// covers an offline direct dial and an internet dial-by-id alike.
/// Binding-internal: the node's action drain calls this to redeem a give.
#[cfg_attr(not(feature = "iroh"), allow(unused_variables))]
pub(crate) async fn dial_exporter(
	uri: &str,
	transport: &str,
	designator: &str,
	direct_addresses_hint: &str,
	node: Rc<HostShared>,
) -> Result<Connection> {
	match transport {
		"tcp" => {
			// The host:port split is the core grammar's verdict, read off the
			// full locator rather than a re-derived string scan.
			let loc = crate::uri::parse_locator(uri)?;
			let (host, port) = loc.host_port.clone().ok_or_else(|| {
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					format!("tcp locator designator is not host:port: {}", loc.designator),
				)
			})?;
			let stream = TcpStream::connect((host.as_str(), port))
				.await
				.map_err(io_err)?;
			Connection::establish_dialed(node, uri, stream).await
		}
		#[cfg(feature = "iroh")]
		"iroh" => {
			let reachability = if direct_addresses_hint.is_empty() {
				node.redeem_reachability()
			} else {
				Reachability::Direct
			};
			Connection::connect_iroh_with_node(
				designator,
				direct_addresses_hint,
				reachability,
				Node::from_shared(node),
			)
			.await
		}
		#[cfg(not(feature = "iroh"))]
		"iroh" => Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("handoff redeem: this build has no iroh transport; rebuild with the iroh feature to dial {uri}"),
		)),
		other => Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("handoff redeem: unsupported exporter transport \"{other}\" in {uri}"),
		)),
	}
}

/// A listening server, the host-side counterpart of [`connect`]. Call
/// [`Server::accept`] for each partner; every accepted [`Connection`] shares the
/// server's one node [`Node`] (its retained identity and gift registry), so
/// the server is one node serving many partners. Dropping the server stops
/// accepting; live connections are unaffected.
pub struct Server {
	listener: TcpListener,
	node: Node,
}

impl Server {
	/// Accept the next partner as a ready [`Connection`], sharing this server's
	/// node [`Node`]. The keyed handshake completes before this resolves; a
	/// partner that fails it — a rude probe that connects and hangs up, or a
	/// stray port scan — is that connection's failure, never the listener's, so
	/// the accept skips it and keeps serving. Must be called inside a `LocalSet`
	/// (the handle graph is `!Send`).
	pub async fn accept(&self) -> Result<Connection> {
		loop {
			let (stream, _) = self.listener.accept().await.map_err(io_err)?;
			let designator = stream
				.local_addr()
				.map(|addr| addr.to_string())
				.unwrap_or_else(|_| "127.0.0.1:0".to_string());
			match Connection::establish_accepted(self.node.shared(), "tcp", &designator, stream)
				.await
			{
				Ok(conn) => return Ok(conn),
				Err(_) => continue,
			}
		}
	}

	/// The bound local address, read the port off it when you bound port 0.
	pub fn local_addr(&self) -> Result<std::net::SocketAddr> {
		self.listener.local_addr().map_err(io_err)
	}

	/// This server's node [`Node`], one retained identity and gift registry
	/// across every accepted connection. Pass it to
	/// [`Connection::connect_with_node`] so a capability fetched on a dialed
	/// connection and returned to an accepted one shares one node (the gifter
	/// half of a three-party handoff), and publish a node-giftable on it with
	/// [`Node::publish_giftable`].
	pub fn node(&self) -> Node {
		self.node.clone()
	}
}

/// Bind `addr` and return a [`Server`] to [`accept`](Server::accept) partners
/// on, the host-side counterpart of [`connect`]. The server is one node with a
/// fresh retained identity shared across every accepted connection.
pub async fn listen<A: ToSocketAddrs>(addr: A) -> Result<Server> {
	listen_with_node(addr, Node::new_node()).await
}

/// [`listen`] on a caller-supplied node — how a server shares one identity and
/// gift registry with connections it dials (the gifter half of a three-party
/// handoff), or speaks a non-default codec ([`Node::with_codec`]).
pub async fn listen_with_node<A: ToSocketAddrs>(addr: A, node: Node) -> Result<Server> {
	let listener = TcpListener::bind(addr).await.map_err(io_err)?;
	// This node also dials (the gifter side of a handoff), and its dials sign
	// the listener's own address so a partner's crossed-hellos table can
	// recognize it.
	if let Ok(local) = listener.local_addr() {
		let _ = node.shared().set_self_designator(&local.to_string());
	}
	Ok(Server { listener, node })
}

/// How an iroh endpoint becomes reachable — the mandatory posture an iroh dial or
/// listen chooses, in the open. There is no default: a pancake peer never turns on
/// relays or a discovery service as a hidden implementation detail, so the caller
/// always names one. A `tcp` dial ignores it (pass `None` to [`connect`]).
///
/// - `Direct`: relay-less, lookup-less — dial by id plus explicit address hints
///   (loopback/LAN). The rooms demo's posture: its URIs carry direct-addresses.
/// - `Discovery`: number-0 relays + DNS/pkarr discovery — dialable by id alone
///   over the internet, with hole-punching and NAT traversal.
/// - `DiscoveryNoRelay`: DNS/pkarr discovery without relays.
/// - `LocalDiscovery`: in-process shared address book — resolves by id alone
///   with no relay, DNS, or hints. For tests and same-process embeddings.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Reachability {
	Direct = 0,
	Discovery = 1,
	DiscoveryNoRelay = 2,
	LocalDiscovery = 3,
}

/// Dial a partner from its `ocapn://` locator — the one dialer, transport-neutral.
/// A `tcp` locator (including one built with [`tcp_locator`]) ignores
/// `reachability`, so pass `None`; an `iroh` locator requires it (the posture is
/// never guessed). The signature is the same whether or not the iroh transport is
/// compiled in, so a call site never changes when the feature is turned on —
/// without it, an `iroh` locator fails with a rebuild hint rather than dialing,
/// and a tcp-only build links no iroh companion library.
#[cfg_attr(not(feature = "iroh"), allow(unused_variables))]
pub async fn connect(uri: &str, reachability: Option<Reachability>) -> Result<Connection> {
	let loc = crate::uri::parse_locator(uri)?;
	match loc.transport.as_str() {
		"tcp" => {
			// The host:port split (and its validation) is the core grammar's,
			// read off the parsed locator — not a re-derived string split.
			let (host, port) = loc.host_port.clone().ok_or_else(|| {
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					format!("tcp locator designator is not host:port: {}", loc.designator),
				)
			})?;
			let stream = TcpStream::connect((host.as_str(), port))
				.await
				.map_err(io_err)?;
			Connection::establish_dialed(Node::new_node().shared(), uri, stream).await
		}
		#[cfg(feature = "iroh")]
		"iroh" => {
			let reachability = reachability.ok_or_else(|| {
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					format!("connect: an iroh locator requires a reachability posture: {uri}"),
				)
			})?;
			let addrs = loc
				.hints
				.get("direct-addresses")
				.map(String::as_str)
				.unwrap_or("");
			Connection::connect_iroh(&loc.designator, addrs, reachability).await
		}
		#[cfg(not(feature = "iroh"))]
		"iroh" => Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("connect: this build has no iroh transport; rebuild with the iroh feature to dial {uri}"),
		)),
		other => Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("connect: unsupported transport \"{other}\""),
		)),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::cell::Cell;
	use std::sync::atomic::AtomicUsize;
	use tokio::sync::oneshot;
	use tokio::task::LocalSet;

	use crate::Codec;

	// A fresh node redeems a hint-less iroh give under `Discovery` by default —
	// the behavior-preserving, maximal-reach choice every existing handoff gate
	// relies on — and the recipient can lower it to a no-relay policy. The setter
	// is shared across node clones, so a knob set on one handle reaches the
	// connections that share the node's identity.
	#[test]
	fn redeem_reachability_defaults_to_discovery_and_is_settable() {
		let node = Node::new_node();
		assert_eq!(node.redeem_reachability(), Reachability::Discovery);
		node.set_redeem_reachability(Reachability::DiscoveryNoRelay);
		assert_eq!(node.redeem_reachability(), Reachability::DiscoveryNoRelay);
		assert_eq!(
			node.clone().redeem_reachability(),
			Reachability::DiscoveryNoRelay
		);
	}

	// `listen` hosts the same surface `connect` dials: a server accepts a
	// pancake dialer, publishes a capability on the accepted connection, and the
	// dialer fetches and calls it, both ends riding the high-level Connection,
	// nothing stitched by hand on either side.
	#[tokio::test]
	async fn listen_accepts_a_pancake_dialer_end_to_end() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				// The client must not fetch before the service is published, so
				// the host signals readiness over a oneshot.
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |verb, args| {
						if verb != "greet" {
							return Err(format!("no such method: {verb}"));
						}
						let who = match args.first() {
							Some(Argument::String(s)) => s.as_str(),
							_ => "?",
						};
						Ok(Argument::String(format!("hello {who}")))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let reply = conn
					.send(&cap, "greet", &[Argument::String("pancake".into())])
					.await
					.unwrap();
				assert_eq!(reply, Argument::String("hello pancake".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// The callback latch crosses the binding: the public surface keeps a sync
	// behavior away from every driving verb (they are all async), so this test
	// reaches through the crate's own FFI mirror to prove the C tier refuses a
	// mid-turn driving verb, the refusal surfaces as the behavior's own break,
	// and the connection survives the refused turn.
	#[tokio::test]
	async fn a_mid_turn_driving_verb_breaks_its_own_answer() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					let raw = conn.shared.ptr.get();
					conn.publish("svc", move |verb, _args| {
						if verb == "reenter" {
							// A driving verb inside the turn: the latch refuses
							// it, and the error's words become the broken answer.
							let mut vow: u64 = 0;
							let rc = unsafe {
								ffi::pancake_host_conn_fetch(raw, "nested".as_ptr(), 6, &mut vow)
							};
							if rc == sys::OK {
								return Err("a mid-turn fetch was NOT refused".to_string());
							}
							return Err(format!("mid-turn driving verb refused with rc {rc}"));
						}
						Ok(Argument::String("pong".into()))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let broke = conn.send(&cap, "reenter", &[]).await.unwrap_err();
				assert!(
					broke.message().unwrap_or("").contains("refused"),
					"the refusal reaches the answer: {broke:?}"
				);
				// The turn unwound cleanly: the same connection still answers.
				let pong = conn.send(&cap, "ping", &[]).await.unwrap();
				assert_eq!(pong, Argument::String("pong".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// Sturdyref enliven (ADR-0012): the client brings a durable `(peer, swissnum)`
	// to life as a live `Ref` through the dedup cache, calls it, then enlivens the
	// same swissnum again and gets the cached capability with no new wire fetch.
	// The swissnum keys the bootstrap fetch, so a host publish under that name
	// answers it.
	#[tokio::test]
	async fn enliven_round_trips_then_caches() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("greeter", |verb, _args| {
						if verb != "hello" {
							return Err(format!("no such method: {verb}"));
						}
						Ok(Argument::Symbol("alive".into()))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();

				// The connection is already open; enliven keys on the sturdyref's
				// swissnum, carried by the URI as `/s/greeter`.
				let sturdyref = "ocapn://greeter-host.tcp/s/greeter";
				let cap = conn.enliven(sturdyref).await.unwrap();
				let reply = conn.send(&cap, "hello", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("alive".into()));

				// A repeat enliven hits the dedup cache: the same live capability.
				let again = conn.enliven(sturdyref).await.unwrap();
				assert_eq!(again.reference(), cap.reference());
				let reply2 = conn.send(&again, "hello", &[]).await.unwrap();
				assert_eq!(reply2, Argument::Symbol("alive".into()));

				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A broken `send` carries the partner's reason, not just a code: the partner
	// publishes a behavior that refuses `do` with its own words, and the client
	// must read them back off the error. The refusal crosses the C boundary as a
	// turn break, so the words survive the trampoline.
	#[tokio::test]
	async fn send_surfaces_the_partner_break_reason() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |verb, _args| {
						Err(match verb {
							"do" => "nope: revoked".to_string(),
							other => format!("no such method: {other}"),
						})
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let err = conn.send(&cap, "do", &[]).await.unwrap_err();
				assert_eq!(err.message(), Some("nope: revoked"));
				// A break is PANCAKE_ERR_BROKEN, not a transport or value error.
				assert_eq!(err.code(), crate::sys::ERR_BROKEN);
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A panicking behavior must never unwind across the extern "C" frame: the
	// trampoline catches it, the answer breaks with the panic's own words, and
	// the connection survives to serve the next call.
	#[tokio::test]
	async fn a_panicking_behavior_breaks_its_answer_and_the_process_survives() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |verb, _args| {
						if verb == "explode" {
							panic!("Revoked by panic");
						}
						Ok(Argument::Symbol("calm".into()))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let err = conn.send(&cap, "explode", &[]).await.unwrap_err();
				assert_eq!(err.code(), crate::sys::ERR_BROKEN);
				assert!(
					err.message()
						.is_some_and(|m| m.contains("Revoked by panic")),
					"the panic's words must survive the boundary: {err:?}"
				);
				// The process — and the connection — survived the panic.
				let reply = conn.send(&cap, "still-there", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("calm".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A rude TCP probe — connect, say nothing, hang up — is that connection's
	// failure, not the listener's: `accept` skips it internally and serves the
	// next, real client. Without that isolation one port scan takes a
	// long-lived server down.
	#[tokio::test]
	async fn a_rude_probe_cannot_close_the_listener() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				// The probe: open a socket and immediately hang up, before the
				// host even accepts.
				let probe = tokio::net::TcpStream::connect(addr).await.unwrap();
				drop(probe);

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					// accept() consumes the probe internally (its handshake dies)
					// and returns the real client.
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
						.await
						.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let reply = conn.send(&cap, "ping", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("alive".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// `tell` is the fire-and-forget eventual-send (Goblins `<-np`): no answer is
	// allocated and nothing settles, but the deliver still flushes to the wire
	// in order, so a `send` issued after two tells observes their effect. This
	// pins the queued-flush semantics: a tell returns once queued on the host,
	// and its bytes leave before the ordered send's own deliver.
	#[tokio::test]
	async fn tell_flushes_in_order_before_a_following_send() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					let mut count: i64 = 0;
					conn.publish("counter", move |verb, _args| match verb {
						"bump" => {
							count += 1;
							Ok(Argument::Void)
						}
						"get" => Ok(Argument::Integer(count)),
						other => Err(format!("no such method: {other}")),
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("counter").await.unwrap();
				conn.tell(&cap, "bump", &[]).unwrap();
				conn.tell(&cap, "bump", &[]).unwrap();
				let got = conn.send(&cap, "get", &[]).await.unwrap();
				assert_eq!(got, Argument::Integer(2));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A partner that disconnects mid-question must reject the outstanding send
	// with a typed break, never hang it: the serve loop breaks every far vow
	// when the stream ends. The partner is a real host whose behavior kills its
	// own socket (a dup'd fd shut down inside the turn), so the reply can never
	// leave and the client sees only the FIN.
	#[tokio::test]
	async fn an_outstanding_send_rejects_on_disconnect() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
				let addr = listener.local_addr().unwrap();

				let host = tokio::task::spawn_local(async move {
					let (stream, _) = listener.accept().await.unwrap();
					// Dup the fd so the behavior can kill the transport out from
					// under its own host mid-turn.
					let std_stream = stream.into_std().unwrap();
					let dup = std_stream.try_clone().unwrap();
					let stream = tokio::net::TcpStream::from_std(std_stream).unwrap();
					let designator = stream
						.local_addr()
						.map(|a| a.to_string())
						.unwrap_or_else(|_| "127.0.0.1:0".to_string());
					let node = Node::new_node();
					let conn =
						Connection::establish_accepted(node.shared(), "tcp", &designator, stream)
							.await
							.unwrap();
					conn.publish("svc", move |verb, _args| {
						if verb == "hang" {
							// The socket dies before the reply can flush: the
							// client observes a disconnect, not an answer.
							let _ = dup.shutdown(std::net::Shutdown::Both);
						}
						Ok(Argument::Void)
					})
					.await
					.unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let err = conn.send(&cap, "hang", &[]).await.unwrap_err();
				assert_eq!(err.code(), crate::sys::ERR_BROKEN);
				assert_eq!(err.message(), Some("connection closed"));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A fetch that cannot yield a capability rejects typed — a broken failure,
	// never a hang and never a transport error. The engine breaks an unknown
	// swissnum's fetch itself, so the failed fetch is observable without a
	// doctored partner.
	#[tokio::test]
	async fn a_failed_fetch_rejects_typed() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |_verb, _args| Ok(Argument::Void))
						.await
						.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let err = conn.fetch("not-a-capability").await.unwrap_err();
				assert_eq!(err.code(), crate::sys::ERR_BROKEN);
				assert_eq!(err.message(), Some("unknown swissnum"));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A failed verb replies its typed refusal and leaves the connection alive: a
	// send to a never-granted far import is refused with its session code (not
	// laundered into IO, not a dead connection), and the same connection then
	// fetches and calls the published capability, proving the pump survived to
	// serve the next verb.
	#[tokio::test]
	async fn a_failed_command_replies_typed_and_the_connection_survives() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |verb, _args| {
						if verb != "ping" {
							return Err(format!("no such method: {verb}"));
						}
						Ok(Argument::String("pong".into()))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();

				// An inadmissible target: import 999 was never granted by the
				// partner, so the session refuses the deliver locally.
				let bogus = Ref::try_from(&Argument::Reference(Reference::far(999))).unwrap();
				let err = conn.send(&bogus, "ping", &[]).await.unwrap_err();
				assert_eq!(err.code(), crate::sys::ERR_SESSION);

				// The connection survived the refusal: the next verbs still work.
				let cap = conn.fetch("svc").await.unwrap();
				let reply = conn.send(&cap, "ping", &[]).await.unwrap();
				assert_eq!(reply, Argument::String("pong".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A `send` to a `Ref` this same connection spawned resolves in-process, not
	// over the wire: the server hosts no such export, so a wire route would never
	// reply. The local turn runs on first observation and the reply comes
	// straight back.
	#[tokio::test]
	async fn send_to_a_self_spawned_actor_resolves_in_process() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.serve().await; // ends when the client closes
				});

				let conn = Connection::connect(addr).await.unwrap();
				let me = conn
					.spawn(|verb, args| {
						if verb != "greet" {
							return Err(format!("no such method: {verb}"));
						}
						let who = match args.first() {
							Some(Argument::String(s)) => s.as_str(),
							_ => "?",
						};
						Ok(Argument::String(format!("hi {who}")))
					})
					.await
					.unwrap();
				let reply = conn
					.send(&me, "greet", &[Argument::String("self".into())])
					.await
					.unwrap();
				assert_eq!(reply, Argument::String("hi self".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// Promise pipelining (ADR-0007), the questioner's half: `send` returns a
	// `RemotePromise` that is itself a `send` target, so a create -> assign ->
	// complete -> status chain is issued against the *unresolved* create answer,
	// none of the four waits for create's reply. The board returns a freshly
	// spawned task; the partner's engine queues the pipelined calls on the create
	// answer and drains them onto the task once create resolves. A status of
	// `done` proves the chain crossed the wire without round-tripping per link.
	#[tokio::test]
	async fn promise_pipelining_drives_a_dependent_chain() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					// The task the board hands out: `complete` flips done and
					// `status` reports it. Pre-spawned because a behavior runs
					// synchronously and cannot itself await a spawn.
					let done = Cell::new(false);
					let task = conn
						.spawn(move |verb: &str, _args: &[Argument]| match verb {
							"assign" => Ok(Argument::String("assigned".into())),
							"complete" => {
								done.set(true);
								Ok(Argument::String("done".into()))
							}
							"status" => Ok(Argument::String(
								if done.get() { "done" } else { "open" }.into(),
							)),
							other => Err(format!("no such method: {other}")),
						})
						.await
						.unwrap();
					conn.publish("root", move |verb, _args| {
						if verb != "create" {
							return Err(format!("no such method: {verb}"));
						}
						Ok((&task).into())
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let root = conn.fetch("root").await.unwrap();
				// The four verbs leave together: none awaits create's reply, and
				// assign / complete / status target the create answer directly.
				let task = conn.send(&root, "create", &[Argument::String("benchmark".into())]);
				conn.send(&task, "assign", &[Argument::String("alice".into())]);
				conn.send(&task, "complete", &[]);
				let status = conn.send(&task, "status", &[]).await.unwrap();
				assert_eq!(status, Argument::String("done".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// The local-turn latch (the wire path's `TurnGuard`, mirrored for locally-run
	// behaviors): a behavior that drops its own captured `Connection` mid-turn
	// takes `Drop`'s `close_transport`, whose immediate-release arm would free
	// the `Box<ActorCell>` whose behavior frame is still on the stack — a
	// use-after-free. `run_hosted`'s marker parks the release instead and drains
	// it once the turn unwinds, so the send settles, the parked release runs,
	// and the connection is released after the turn.
	#[tokio::test]
	async fn a_behavior_closing_its_own_connection_mid_local_send_parks_the_release() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.serve().await; // ends when the client closes
				});

				let conn = Connection::connect(addr).await.unwrap();
				// A second handle over the same connection, moved into the
				// behavior so its `Drop` (which closes the shared transport)
				// fires inside the behavior's own turn.
				let captured = Cell::new(Some(Connection {
					shared: Rc::clone(&conn.shared),
				}));
				let me = conn
					.spawn(move |verb, _args| {
						if verb == "die" {
							drop(captured.take());
							return Ok(Argument::Symbol("closing".into()));
						}
						Ok(Argument::Void)
					})
					.await
					.unwrap();
				let reply = conn.send(&me, "die", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("closing".into()));
				// The turn unwound: the parked release ran (nothing left parked)
				// and the connection is released, so the next verb is refused
				// closed rather than crashing.
				assert_eq!(crate::host::pending_release_count(), 0);
				assert!(conn.shared.released.get());
				let err = conn.send(&me, "die", &[]).await.unwrap_err();
				assert_eq!(err.kind(), crate::ErrorKind::Closed);
				host.await.unwrap();
			})
			.await;
	}

	// Pipelined projections (ADR-0050/ADR-0052): `RemotePromise::untag` / `index`
	// reach into the value an answer will resolve to *before* it resolves, each
	// returning a new pipelinable promise. The board's `make` returns a Tagged
	// "task" wrapping one row `["assigned", label, 7]`; untag unwraps to that
	// row, index 1 takes the label, a two-hop chain riding the unresolved make
	// answer, no extra round trip. The source handle is awaited afterward to
	// prove a far reply observed *late* (after a sibling projection already
	// pumped the loop) still settles.
	#[tokio::test]
	async fn pipelined_projections_reach_a_field() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("root", |verb, args| {
						if verb != "make" {
							return Err(format!("no such method: {verb}"));
						}
						let label = match args.first() {
							Some(Argument::String(s)) => s.clone(),
							_ => "anon".to_string(),
						};
						// A Tagged wrapping a single row: untag unwraps to it.
						Ok(Argument::Tagged {
							tag: "task".into(),
							value: vec![Argument::List(vec![
								Argument::String("assigned".into()),
								Argument::String(label),
								Argument::Integer(7),
							])],
						})
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let root = conn.fetch("root").await.unwrap();
				// Neither projection awaits a prior reply: they ride the
				// unresolved make answer and the whole chain leaves on one flush.
				let made = conn.send(&root, "make", &[Argument::String("alice".into())]);
				let label = made.untag("task").index(1).await.unwrap();
				assert_eq!(label, Argument::String("alice".into()));
				// The source answer settled while the projection pumped the loop;
				// awaiting it now must still resolve.
				let full = made.await.unwrap();
				assert!(matches!(full, Argument::Tagged { ref tag, .. } if tag == "task"));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// Object-capability forwarding proxies over the wire (ADR-0064). The host fetches the
	// client's published tool — a *far* reference on the host side — wraps it in a
	// caretaker, and hands the proxy back to the client. A call through the proxy
	// forwards across the host to the client's tool (the far deferred-answer path)
	// and resolves the caller's answer; an attenuator passes only its allow-listed
	// verb; and a revoke breaks every later call. The forward target being far is
	// the point: it exercises the turn-forward path across the host's routing.
	#[tokio::test]
	async fn forwarding_proxies_forward_revoke_and_attenuate_over_the_wire() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (tool_ready_tx, tool_ready_rx) = oneshot::channel::<()>();
				let (proxy_ready_tx, proxy_ready_rx) = oneshot::channel::<()>();

				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					// Wait for the client to publish its tool, then fetch it: a far
					// reference this host wraps.
					tool_ready_rx.await.unwrap();
					let tool = conn.fetch("tool").await.unwrap();

					let care = conn.caretaker(&tool).await.unwrap();
					let proxy = care.proxy.clone();
					let readonly = conn.attenuate(&tool, &["get"]).await.unwrap();

					conn.publish("root", move |verb, _args| match verb {
						"proxy" => Ok((&proxy).into()),
						"readonly" => Ok((&readonly).into()),
						"revoke" => {
							care.revoke();
							Ok(Argument::Void)
						}
						other => Err(format!("no such method: {other}")),
					})
					.await
					.unwrap();
					proxy_ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				// The tool the host will wrap: `add` increments, `get` reads.
				conn.publish("tool", |verb, args| match verb {
					"add" => {
						let n = args.first().and_then(|a| a.as_i64()).unwrap_or(0);
						Ok(Argument::Integer(n + 1))
					}
					"get" => Ok(Argument::Integer(7)),
					other => Err(format!("no such method: {other}")),
				})
				.await
				.unwrap();
				tool_ready_tx.send(()).unwrap();
				proxy_ready_rx.await.unwrap();

				let root = conn.fetch("root").await.unwrap();

				// Live caretaker: a call forwards across the host to the far tool.
				let proxy = Ref::try_from(&conn.send(&root, "proxy", &[]).await.unwrap()).unwrap();
				let reply = conn
					.send(&proxy, "add", &[Argument::Integer(41)])
					.await
					.unwrap();
				assert_eq!(reply, Argument::Integer(42));

				// Attenuator: the allow-listed verb forwards; any other breaks.
				let readonly =
					Ref::try_from(&conn.send(&root, "readonly", &[]).await.unwrap()).unwrap();
				let got = conn.send(&readonly, "get", &[]).await.unwrap();
				assert_eq!(got, Argument::Integer(7));
				let denied = conn
					.send(&readonly, "add", &[Argument::Integer(1)])
					.await
					.unwrap_err();
				assert!(denied.to_string().contains("Attenuated"), "{denied}");

				// Revoke: every later call through the proxy breaks.
				conn.send(&root, "revoke", &[]).await.unwrap();
				let severed = conn
					.send(&proxy, "add", &[Argument::Integer(1)])
					.await
					.unwrap_err();
				assert!(severed.to_string().contains("Revoked"), "{severed}");

				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// The wart ADR-0064 closes: a caretaker/attenuator proxy is an ordinary
	// spawned actor, so its own host calls it locally exactly as a partner calls
	// it over the wire. A caretaker over a *local* tool answers a local send; a
	// caretaker over a *far* tool forwards across the wire and the local send still
	// settles; and a revoke breaks the local call too.
	#[tokio::test]
	async fn a_forwarding_proxy_answers_its_hosts_own_local_call() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("tool", |verb, _args| match verb {
						"ping" => Ok(Argument::Integer(99)),
						other => Err(format!("no such method: {other}")),
					})
					.await
					.unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();

				// A caretaker over a local tool, called locally by its own host.
				let local_tool = conn
					.spawn(|verb, args| match verb {
						"double" => {
							let n = args.first().and_then(|a| a.as_i64()).unwrap_or(0);
							Ok(Argument::Integer(n * 2))
						}
						other => Err(format!("no such method: {other}")),
					})
					.await
					.unwrap();
				let care_local = conn.caretaker(&local_tool).await.unwrap();
				let doubled = conn
					.send(&care_local.proxy, "double", &[Argument::Integer(21)])
					.await
					.unwrap();
				assert_eq!(doubled, Argument::Integer(42));

				// A caretaker over a far tool, called locally: the proxy forwards
				// across the wire and the local send still settles on the reply.
				let far = conn.fetch("tool").await.unwrap();
				let care_far = conn.caretaker(&far).await.unwrap();
				let pong = conn.send(&care_far.proxy, "ping", &[]).await.unwrap();
				assert_eq!(pong, Argument::Integer(99));

				// Revoke severs the local call exactly as it severs a partner's.
				care_local.revoke();
				let severed = conn
					.send(&care_local.proxy, "double", &[Argument::Integer(1)])
					.await
					.unwrap_err();
				assert!(severed.to_string().contains("Revoked"), "{severed}");

				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// The codec selector end-to-end on the connection tier: two Cap'n Proto
	// nodes complete the keyed handshake and carry a deliver whose arguments
	// round-trip through the capnp codec — a big integer past int64 and a
	// Keyword included, so the two rare marshal arms are witnessed alongside
	// the codec.
	#[tokio::test]
	async fn capnp_nodes_handshake_and_round_trip_big_integer_and_keyword() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen_with_node("127.0.0.1:0", Node::with_codec(Codec::Capnp))
					.await
					.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("echo", |_verb, args| Ok(Argument::List(args.to_vec())))
						.await
						.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect_with_node(addr, Node::with_codec(Codec::Capnp))
					.await
					.unwrap();
				ready_rx.await.unwrap();
				let echo = conn.fetch("echo").await.unwrap();
				// 2^80: past int64, so it must ride the ARG_BIG_INTEGER arm.
				let big = Argument::BigInteger {
					negative: false,
					digits: "1208925819614629174706176".to_string(),
				};
				let args = vec![
					big.clone(),
					Argument::Keyword("prio".into()),
					Argument::Bytes(b"hi".to_vec()),
				];
				let reply = conn.send(&echo, "roundtrip", &args).await.unwrap();
				assert_eq!(reply, Argument::List(args));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A byte stream wrapper that watches inbound bytes for a needle — the
	// observer half of the wire-observing scenarios, standing where the old raw
	// peer partner scripts stood.
	struct Scanning<S> {
		inner: S,
		needle: &'static [u8],
		seen: Rc<Cell<bool>>,
		tail: Vec<u8>,
	}

	impl<S> Scanning<S> {
		fn new(inner: S, needle: &'static [u8], seen: Rc<Cell<bool>>) -> Scanning<S> {
			Scanning {
				inner,
				needle,
				seen,
				tail: Vec::new(),
			}
		}

		fn scan(&mut self, fresh: &[u8]) {
			self.tail.extend_from_slice(fresh);
			if self
				.tail
				.windows(self.needle.len())
				.any(|window| window == self.needle)
			{
				self.seen.set(true);
			}
			// Keep only enough tail to catch a needle across chunk boundaries.
			let keep = self.needle.len().saturating_sub(1);
			if self.tail.len() > keep {
				self.tail.drain(..self.tail.len() - keep);
			}
		}
	}

	impl<S: AsyncRead + Unpin> AsyncRead for Scanning<S> {
		fn poll_read(
			mut self: std::pin::Pin<&mut Self>,
			cx: &mut std::task::Context<'_>,
			buf: &mut tokio::io::ReadBuf<'_>,
		) -> std::task::Poll<std::io::Result<()>> {
			let before = buf.filled().len();
			let poll = std::pin::Pin::new(&mut self.inner).poll_read(cx, buf);
			if let std::task::Poll::Ready(Ok(())) = &poll {
				let fresh = buf.filled()[before..].to_vec();
				self.scan(&fresh);
			}
			poll
		}
	}

	impl<S: AsyncWrite + Unpin> AsyncWrite for Scanning<S> {
		fn poll_write(
			mut self: std::pin::Pin<&mut Self>,
			cx: &mut std::task::Context<'_>,
			src: &[u8],
		) -> std::task::Poll<std::io::Result<usize>> {
			std::pin::Pin::new(&mut self.inner).poll_write(cx, src)
		}

		fn poll_flush(
			mut self: std::pin::Pin<&mut Self>,
			cx: &mut std::task::Context<'_>,
		) -> std::task::Poll<std::io::Result<()>> {
			std::pin::Pin::new(&mut self.inner).poll_flush(cx)
		}

		fn poll_shutdown(
			mut self: std::pin::Pin<&mut Self>,
			cx: &mut std::task::Context<'_>,
		) -> std::task::Poll<std::io::Result<()>> {
			std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
		}
	}

	async fn wait_for(flag: &Rc<Cell<bool>>, what: &str) {
		for _ in 0..2000 {
			if flag.get() {
				return;
			}
			tokio::time::sleep(std::time::Duration::from_millis(5)).await;
		}
		panic!("timed out waiting for {what}");
	}

	// Distributed GC (ADR-0063), opt-in: a client that enables GC and fetches a
	// capability releases its import — a single `op:gc-exports`, routed through
	// the host by its node-unique token — when the last `Ref` to it drops, so
	// the partner can release the matching export. The partner observes the
	// release frame on its own wire through a scanning transport.
	#[tokio::test]
	async fn dropping_a_fetched_cap_releases_its_import_when_gc_is_on() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
				let addr = listener.local_addr().unwrap();
				let seen = Rc::new(Cell::new(false));

				let seen_by_host = Rc::clone(&seen);
				let host = tokio::task::spawn_local(async move {
					let (stream, _) = listener.accept().await.unwrap();
					let designator = stream
						.local_addr()
						.map(|a| a.to_string())
						.unwrap_or_else(|_| "127.0.0.1:0".to_string());
					let stream = Scanning::new(stream, b"op:gc-export", seen_by_host);
					let node = Node::new_node();
					let conn =
						Connection::establish_accepted(node.shared(), "tcp", &designator, stream)
							.await
							.unwrap();
					conn.publish("svc", |_verb, _args| Ok(Argument::Void))
						.await
						.unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap().with_gc();
				let cap = conn.fetch("svc").await.unwrap();
				// Dropping the only handle parks the token; the serve task drains
				// it into one `pancake_host_gc_release`, which rides the wire as
				// op:gc-exports.
				drop(cap);
				wait_for(&seen, "the partner to observe op:gc-exports").await;
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// The feed-failure choreography (the embedder contract): a garbage frame
	// makes the partner's feed refuse, and the partner still drains its
	// outbound so the typed `op:abort` the core projected reaches this side —
	// observed here on the client's own wire through a scanning transport.
	#[tokio::test]
	async fn a_refused_feed_writes_the_typed_abort_for_the_partner() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |_verb, _args| Ok(Argument::Void))
						.await
						.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				// Dial by hand so the inbound bytes pass through the scanner and
				// a dup'd fd can inject garbage after the session opens.
				let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
				let peer = stream.peer_addr().unwrap();
				let std_stream = stream.into_std().unwrap();
				let dup = std_stream.try_clone().unwrap();
				let stream = tokio::net::TcpStream::from_std(std_stream).unwrap();
				let seen = Rc::new(Cell::new(false));
				let stream = Scanning::new(stream, b"op:abort", Rc::clone(&seen));
				let node = Node::new_node();
				let conn = Connection::establish_dialed(
					node.shared(),
					&tcp_locator(&peer.ip().to_string(), peer.port()),
					stream,
				)
				.await
				.unwrap();
				ready_rx.await.unwrap();
				let _cap = conn.fetch("svc").await.unwrap();

				// Inject bytes no codec accepts, straight onto the socket.
				use std::io::Write;
				(&dup).write_all(b"this is not a syrup frame").unwrap();

				// The server's refused feed leaves a typed op:abort on its
				// outbound queue and writes it before releasing; it lands here.
				wait_for(&seen, "the typed op:abort from the partner").await;
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// The local half of the same choreography: the side whose OWN feed refuses
	// surfaces the typed cause on the error — `Error::abort()` populated with
	// the refusing layer and the projected kind — not just the flat code the
	// wire-observing sibling above watches from the partner's side. Split from
	// that test because the refusal must reach a caller: the serve loop's feed
	// error has none, so this feeds the garbage through the pump directly.
	#[tokio::test]
	async fn a_refused_feed_surfaces_the_typed_abort_locally() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.serve().await; // ends when the client tears down
				});

				let conn = Connection::connect(addr).await.unwrap();
				// Bytes no codec accepts, fed straight into this side's pump: the
				// core refuses the frame and projects a typed op:abort.
				let err = conn
					.shared
					.feed(b"this is not a syrup frame")
					.await
					.unwrap_err();
				let abort = err.abort().expect("the refusal carries its typed cause");
				assert_eq!(abort.domain, AbortDomain::Codec);
				assert!(
					abort.kind.as_deref().is_some_and(|kind| !kind.is_empty()),
					"the projected abort kind is populated: {abort:?}"
				);
				conn.close();
				host.await.unwrap();
			})
			.await;
	}

	// A node whose host allocates through a caller-supplied context routes its
	// bytes through that allocator, and releasing the node (and its
	// connections) before the context keeps the drop order honest.
	#[tokio::test]
	async fn drives_a_node_in_a_context_with_a_custom_allocator() {
		use std::sync::Arc;

		struct Counting {
			allocs: Arc<AtomicUsize>,
		}
		impl crate::HostAllocator for Counting {
			fn alloc(&self, size: usize, alignment: usize) -> *mut u8 {
				self.allocs.fetch_add(1, Ordering::Relaxed);
				let layout = std::alloc::Layout::from_size_align(size, alignment).unwrap();
				unsafe { std::alloc::alloc(layout) }
			}
			unsafe fn free(&self, ptr: *mut u8, size: usize, alignment: usize) {
				let layout = std::alloc::Layout::from_size_align(size, alignment).unwrap();
				std::alloc::dealloc(ptr, layout);
			}
		}

		let allocs = Arc::new(AtomicUsize::new(0));
		// Declared before the LocalSet so it drops last: every host byte is
		// freed through the allocator before the context goes away.
		let ctx = crate::Context::with_allocator(Box::new(Counting {
			allocs: allocs.clone(),
		}))
		.unwrap();
		let local = LocalSet::new();
		local
			.run_until(async {
				let node = Node::new_in(&ctx, Codec::Syrup).unwrap();
				let server = listen_with_node("127.0.0.1:0", node).await.unwrap();
				let addr = server.local_addr().unwrap();
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
						.await
						.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = Connection::connect(addr).await.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let reply = conn.send(&cap, "ping", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("alive".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
		// The context-backed host actually serviced the conversation.
		assert!(allocs.load(Ordering::Relaxed) > 0);
		drop(local); // every task (and its node Rc) unwinds before the context
	}
}
