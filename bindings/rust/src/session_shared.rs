//! Per-session capability support and shared state: [`Caretaker`] and
//! [`SessionShared`]. [`Session`](crate::Session) is the application handle
//! over one `SessionShared`; pump/host/trampoline/gc borrow `SessionShared` directly.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::Notify;

use crate::host::{check_host, try_spawn_local, HostShared};
use crate::sys::host as ffi;
use crate::trampoline::{
	ctx_free, current_turn_for, inside_turn, reclaim_refused_cell, trampoline, turn_spawn, ActorCell, InternalBehavior,
	TurnOutcome,
};
use crate::{sys, Argument, Error, Ref, Result, SendArena};

pub(crate) const READ_CHUNK: usize = sys::BINDING_STREAM_READ_CHUNK_BYTES;

/// Map a transport `std::io::Error` to a pancake [`Error`], carrying the
/// original message through the detail channel so a consumer can tell
/// connection-refused from timeout from reset (the public `Error` keeps its
/// `Clone`/`PartialEq` derives, so it holds the message string, not a
/// `Box<dyn Error>` source). The flat code stays `PANCAKE_ERR_IO`.
pub(crate) fn io_err(e: std::io::Error) -> Error {
	Error::with_detail(sys::ERR_IO, e.to_string())
}

impl From<&Ref> for Argument {
	fn from(r: &Ref) -> Argument {
		Argument::Reference(r.clone())
	}
}

impl TryFrom<&Argument> for Ref {
	type Error = ();

	/// Lift a capability returned by a `send` back into a `Ref` you can send to.
	fn try_from(arg: &Argument) -> std::result::Result<Ref, ()> {
		match arg {
			Argument::Reference(reference) => Ok(reference.clone()),
			_ => Err(()),
		}
	}
}

/// A revocable caretaker over a capability (ADR-0064), returned by
/// [`Session::caretaker`]. Hand [`proxy`](Caretaker::proxy) to a partner; call
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
	pub(crate) fn new(proxy: Ref, live: Arc<AtomicBool>) -> Self {
		Self { proxy, live }
	}

	/// Sever the proxy: subsequent calls through it break with `Revoked`.
	/// Idempotent. Clears the shared flag the proxy actor reads, so it takes effect
	/// with no round trip (a closed connection has already severed every proxy).
	pub fn revoke(&self) {
		self.live.store(false, Ordering::SeqCst);
	}
}

/// The per-session state the handle, the serve task, and the host's action
/// drain share. Fields the [`crate::pump`] path reads are `pub(crate)`.
pub(crate) struct SessionShared {
	pub(crate) ptr: Cell<*mut ffi::PancakeHostSession>,
	key: usize,
	pub(crate) host: Rc<HostShared>,
	// The transport halves: the serve task takes the read half for its life;
	// FLUSH drains serialize on the write half's async lock, which keeps frames
	// in submission order. Order is all the lock gives: a write dropped
	// mid-frame still leaves a partial one on the wire, which `torn` records.
	// Both stay `None` on a loop-backed session, whose wire the native loop
	// owns (`loop_wire`).
	pub(crate) reader: RefCell<Option<Box<dyn AsyncRead + Unpin>>>,
	pub(crate) writer: Rc<tokio::sync::Mutex<Option<Box<dyn AsyncWrite + Unpin>>>>,
	// The native loop that owns this session's wire and its release (ADR-0112),
	// or `None` for a byte-fed session this binding pumps itself. A loop-backed
	// session has no byte pump: the loop reads, feeds, and flushes inside its
	// steps, and `pancake_driver_session_release` is its one release verb.
	pub(crate) loop_wire: Option<Rc<crate::driver_loop::LoopShared>>,
	// Set the moment teardown begins (an application close, or the transport
	// reporting EOF), so the serve loop can tell a read cancelled by our own
	// close from a real fault.
	pub(crate) closing: Cell<bool>,
	pub(crate) released: Cell<bool>,
	pub(crate) release_pending: Cell<bool>,
	// Terminal result projected by the core-issued CLOSE action or native
	// SESSION_CLOSED event before the session handle is released.
	pub(crate) close_result: Cell<Option<i32>>,
	// Exact non-clean wire termination projected by SESSION_CLOSED. This stays
	// distinct from close_result: transport truth and close-driver status are
	// different failure channels.
	pub(crate) wire_failure: RefCell<Option<crate::Error>>,
	// The one detached driver behind explicit close. The runtime owns a spawned
	// task after its JoinHandle is dropped, but retaining the handle here makes
	// the shared operation and its one-driver invariant explicit.
	pub(crate) close_task: RefCell<Option<tokio::task::JoinHandle<()>>>,
	pub(crate) owner_handles: Cell<usize>,
	// Set when an outbound write was dropped part-way through a frame, which a
	// caller does by cancelling: `tokio::time::timeout` around a send is
	// enough. `write_all` is not cancellation-safe, so some prefix of the frame
	// is already on the wire and the partner's framing is unrecoverable. The
	// lock serializes writers but cannot make one atomic. Once this is set the
	// session refuses further writes rather than appending to a stream the
	// partner can no longer parse.
	pub(crate) torn: Cell<bool>,
	// Wakes the serve task off its parked read when the connection closes.
	pub(crate) closed: Notify,
	// Distributed GC (ADR-0063), opt-in and off by default.
	pub(crate) gc: Cell<bool>,
	// The auto-started serve task's handle; `Session::serve` takes it.
	serving: Cell<Option<tokio::task::JoinHandle<Result<()>>>>,
}

impl SessionShared {
	#[cfg(any(test, feature = "iroh"))]
	pub(crate) fn new<S>(ptr: *mut ffi::PancakeHostSession, host: Rc<HostShared>, stream: S) -> Rc<SessionShared>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		let (reader, writer) = tokio::io::split(stream);
		let shared = Rc::new(SessionShared {
			ptr: Cell::new(ptr),
			key: ptr as usize,
			host: Rc::clone(&host),
			reader: RefCell::new(Some(Box::new(reader))),
			writer: Rc::new(tokio::sync::Mutex::new(Some(Box::new(writer)))),
			loop_wire: None,
			closing: Cell::new(false),
			released: Cell::new(false),
			release_pending: Cell::new(false),
			close_result: Cell::new(None),
			wire_failure: RefCell::new(None),
			close_task: RefCell::new(None),
			owner_handles: Cell::new(0),
			torn: Cell::new(false),
			closed: Notify::new(),
			gc: Cell::new(false),
			serving: Cell::new(None),
		});
		// Join the host's registry so a FLUSH action can find the transport and
		// a dialed exporter stays reachable for teardown.
		host.register_session(shared.key, Rc::clone(&shared));
		shared
	}

	/// The loop-backed shell (ADR-0112): a real `PancakeHostSession` the native
	/// loop minted (dial, accept, or an internal redeem), with no byte halves —
	/// the loop owns the wire, the pumping, and the release. Registered in the
	/// host's session directory like any other shell, so the loop's
	/// SESSION_CLOSED dispatch and `exporter_for` both find it.
	pub(crate) fn new_loop(
		ptr: *mut ffi::PancakeHostSession,
		host: Rc<HostShared>,
		loop_wire: Rc<crate::driver_loop::LoopShared>,
	) -> Rc<SessionShared> {
		let shared = Rc::new(SessionShared {
			ptr: Cell::new(ptr),
			key: ptr as usize,
			host: Rc::clone(&host),
			reader: RefCell::new(None),
			writer: Rc::new(tokio::sync::Mutex::new(None)),
			loop_wire: Some(loop_wire),
			closing: Cell::new(false),
			released: Cell::new(false),
			release_pending: Cell::new(false),
			close_result: Cell::new(None),
			wire_failure: RefCell::new(None),
			close_task: RefCell::new(None),
			owner_handles: Cell::new(0),
			torn: Cell::new(false),
			closed: Notify::new(),
			gc: Cell::new(false),
			serving: Cell::new(None),
		});
		host.register_session(shared.key, Rc::clone(&shared));
		shared
	}

	pub(crate) fn raw_session(&self) -> *mut ffi::PancakeHostSession {
		self.ptr.get()
	}

	pub(crate) fn host_key(&self) -> usize {
		Rc::as_ptr(&self.host) as usize
	}

	/// The hosted cell behind a Host-scoped local capability, for in-process
	/// `Forward` composition and the local send arm.
	pub(crate) fn hosted_cell(&self, ref_id: u64) -> Option<*const ActorCell> {
		self.host.hosted_cell(ref_id)
	}

	pub(crate) fn closing(&self) -> bool {
		self.host.closing() || self.closing.get() || self.released.get()
	}

	pub(crate) fn guard_open(&self) -> Result<()> {
		self.host.guard_handle()?;
		if self.released.get() {
			Err(Error::with_detail(sys::ERR_CLOSED, "connection closed".to_string()))
		} else {
			Ok(())
		}
	}

	/// Resume loop-owned inbound once application setup is complete. A dialed
	/// session reaches this from its first wire verb; an accepted session may
	/// instead call `Session::serve` after publishing. Byte-fed sessions already
	/// own their reader task, so this is a no-op for them.
	pub(crate) fn attend_inbound(self: &Rc<Self>) -> Result<()> {
		if let Some(loop_) = self.loop_wire.as_ref() {
			loop_.serve_session(self.raw_session())?;
		}
		Ok(())
	}

	#[cfg(any(test, feature = "iroh"))]
	pub(crate) fn session_open(&self) -> bool {
		!self.host.closing()
			&& !self.released.get()
			&& unsafe { ffi::pancake_host_session_is_open(self.ptr.get()) } == 1
	}

	// ── The pump ────────────────────────────────────────────────────────────────

	// Spawn the inbound serve loop as its own task. Runs from establish, so a
	// connection pumps from birth: an accepted partner's traffic and a dialed
	// exporter's withdraw both arrive without an explicit `serve()` call.
	// A loop-backed session has no byte pump of its own — the native loop
	// reads, feeds, and drains — so its serve task only awaits the session's
	// closure, keeping the completes-on-close contract.
	pub(crate) fn spawn_serve(self: &Rc<SessionShared>) {
		let shared = Rc::clone(self);
		let handle = if self.loop_wire.is_some() {
			tokio::task::spawn_local(async move {
				let notified = shared.closed.notified();
				tokio::pin!(notified);
				// Register before checking, so a close between the check and
				// the await cannot strand this task.
				notified.as_mut().enable();
				if shared.released.get() {
					return shared.terminal_result();
				}
				notified.await;
				shared.terminal_result()
			})
		} else {
			tokio::task::spawn_local(async move { crate::pump::serve_loop(shared).await })
		};
		self.serving.set(Some(handle));
	}

	// ── Teardown ────────────────────────────────────────────────────────────────

	/// Close just this session, without touching the host's other sessions:
	/// stop the transport, then retire the host's entry and free the host
	/// handle (its still-parked far vows break inside the release), so no
	/// foreign call touches a freed session. A release refused inside a
	/// behavior callback is parked for the next drain, never dropped.
	pub(crate) fn close_transport(self: &Rc<SessionShared>) {
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
		if inside_turn() {
			if !self.release_pending.replace(true) {
				crate::finalizer::park_session(Rc::clone(self));
			}
			return;
		}
		if self.finish_native_release().is_err() && !self.release_pending.replace(true) {
			crate::finalizer::park_session(Rc::clone(self));
			self.host.schedule_kick_or_record();
		}
		// The release queued FAIL completions (and sibling withdraws may have
		// failed closed): route them now.
		self.host.schedule_kick_or_record();
	}

	pub(crate) fn finish_native_release(self: &Rc<SessionShared>) -> Result<()> {
		if self.released.get() {
			self.release_pending.set(false);
			return Ok(());
		}
		let ptr = self.ptr.get();
		if !ptr.is_null() {
			self.host.release_native_session(ptr)?;
		}
		self.commit_native_release();
		Ok(())
	}

	/// Commit wrapper retirement after its native owner has released either this
	/// handle or the whole loop. No native call may follow this transition.
	pub(crate) fn commit_native_release(&self) {
		if self.released.replace(true) {
			self.release_pending.set(false);
			return;
		}
		self.release_pending.set(false);
		self.host.unregister_session(self.key);
		self.ptr.set(core::ptr::null_mut());
		self.closed.notify_waiters();
	}

	pub(crate) fn record_close_result(&self, result: i32) {
		self.close_result.set(Some(result));
	}

	pub(crate) fn record_wire_failure(&self, failure: crate::Error) {
		let mut retained = self.wire_failure.borrow_mut();
		if retained.is_none() {
			*retained = Some(failure);
		}
	}

	pub(crate) fn terminal_result(&self) -> crate::Result<()> {
		if let Some(failure) = self.wire_failure.borrow().clone() {
			return Err(failure);
		}
		crate::session::session_close_result(self.close_result.get().unwrap_or(sys::OK))
	}

	/// Take the serve task's handle (the `Session::serve` future awaits it).
	pub(crate) fn take_serving(&self) -> Option<tokio::task::JoinHandle<Result<()>>> {
		self.serving.take()
	}

	// ── Hosting ─────────────────────────────────────────────────────────────────

	// Register `behavior` as a hosted object of this Host: inside any turn on
	// the same Host through the turn-time spawn (the captured Session may already
	// be closed), else through this Session's top-level spawn.
	pub(crate) fn spawn_actor(self: &Rc<SessionShared>, behavior: InternalBehavior) -> Result<Ref> {
		let turn = current_turn_for(self.host_key());
		if turn.is_none() {
			self.guard_open()?;
			self.drain_gc()?;
		}
		let cell = self.host.actor_cell(behavior)?;
		let id = match turn {
			Some(turn) => turn_spawn(turn, cell)?,
			None => {
				let mut reference = sys::PancakeReference { id: 0 };
				let rc = unsafe {
					ffi::pancake_host_session_spawn(
						self.ptr.get(),
						trampoline,
						cell as *mut core::ffi::c_void,
						ctx_free,
						&mut reference,
					)
				};
				if rc != sys::OK {
					let primary = check_host(rc).unwrap_err();
					let cleanup = unsafe { reclaim_refused_cell(rc, cell) };
					return Err(crate::retain_cleanup_failure(primary, cleanup));
				}
				reference.id
			}
		};
		self.host.hosted.borrow_mut().insert(id, cell as *const ActorCell);
		Ok(Ref::bare_id(id))
	}

	/// Record the host giftable published under `name` against the opaque Host
	/// identity this session surfaced, so local sends from any sibling Session
	/// run in process. The C tier frees the cell with the Host.
	pub(crate) fn bind_host_giftable(self: &Rc<SessionShared>, name: &str, ref_id: u64) {
		if self.host.hosted.borrow().contains_key(&ref_id) {
			return;
		}
		let cell = self.host.giftables.borrow().get(name).copied();
		if let Some(cell) = cell {
			self.host.hosted.borrow_mut().insert(ref_id, cell);
		}
	}

	pub(crate) fn publish_actor(self: &Rc<SessionShared>, name: &str, behavior: InternalBehavior) -> Result<Ref> {
		self.guard_open()?;
		self.drain_gc()?;
		let cell = self.host.actor_cell(behavior)?;
		let mut reference = sys::PancakeReference { id: 0 };
		let rc = unsafe {
			ffi::pancake_host_session_publish(
				self.ptr.get(),
				name.as_ptr(),
				name.len(),
				trampoline,
				cell as *mut core::ffi::c_void,
				ctx_free,
				&mut reference,
			)
		};
		if rc != sys::OK {
			let primary = check_host(rc).unwrap_err();
			let cleanup = unsafe { reclaim_refused_cell(rc, cell) };
			return Err(crate::retain_cleanup_failure(primary, cleanup));
		}
		self.host
			.hosted
			.borrow_mut()
			.insert(reference.id, cell as *const ActorCell);
		Ok(Ref::bare_id(reference.id))
	}

	// ── The verbs' shared plumbing ─────────────────────────────────────────────

	// The local arm of `tell`: deferred to its own task so a behavior telling a
	// self-hosted object never re-enters the running cell's borrow. Admission is
	// synchronous and fallible; after admission, behavior/forward failures have
	// no answer channel by the definition of tell.
	pub(crate) fn tell_local(self: &Rc<SessionShared>, ref_id: u64, verb: String, args: Vec<Argument>) -> Result<()> {
		let shared = Rc::clone(self);
		if !try_spawn_local(async move {
			if let Some(TurnOutcome::Forward { target, verb, args }) =
				crate::trampoline::run_hosted(&shared, ref_id, &verb, &args)
			{
				if let Err(error) = shared.tell_wire(&target, &verb, &args) {
					shared.host.record_background_failure(error);
				}
			}
		}) {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"local tell requires a running LocalSet".to_string(),
			));
		}
		Ok(())
	}

	pub(crate) fn tell_wire(self: &Rc<SessionShared>, target: &Ref, verb: &str, args: &[Argument]) -> Result<()> {
		self.attend_inbound()?;
		let wire = target.to_sys()?;
		let mut arena = SendArena::default();
		let (args_ptr, args_len) = arena.build(args)?;
		check_host(unsafe {
			ffi::pancake_host_session_tell(self.ptr.get(), &wire, verb.as_ptr(), verb.len(), args_ptr, args_len)
		})?;
		self.host.schedule_kick()
	}

	/// A self-hosted capability runs `tell_local`; everything else lowers through
	/// the Host. Session keeps the CapTP verb.
	pub(crate) fn tell(self: &Rc<SessionShared>, target: &Ref, verb: &str, args: &[Argument]) -> Result<()> {
		self.guard_open()?;
		self.drain_gc()?;
		if self.hosted_cell(target.id()).is_some() {
			return self.tell_local(target.id(), verb.to_string(), args.to_vec());
		}
		self.tell_wire(target, verb, args)
	}

	// ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

	// Drain the parked GC releases — see [`crate::gc::drain`].
	pub(crate) fn drain_gc(&self) -> Result<()> {
		crate::gc::drain(&self.host)
	}
}
