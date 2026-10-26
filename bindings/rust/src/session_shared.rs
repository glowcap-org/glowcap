//! Per-session capability support and shared state: [`Caretaker`] and
//! [`SessionShared`]. [`Session`](crate::Session) is the application handle
//! over one `SessionShared`. The pump, host, trampoline, and gc modules borrow `SessionShared` directly.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(all(test, feature = "tcp"))]
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::Notify;

use crate::host::{HostShared, check_host};
use crate::sys::host as ffi;
use crate::trampoline::{
	DeliverGuard, InternalBehavior, ctx_free, current_turn_for, inside_turn, register_actor_cell, trampoline,
	turn_spawn,
};
use crate::{Argument, Error, Ref, Result, SendArena, sys};

mod retirement;

pub(crate) const READ_CHUNK: usize = sys::BINDING_STREAM_READ_CHUNK_BYTES;

/// Preserve a transport deadline as `TimedOut`. Other transport failures use
/// `Io`. Keep the original diagnostic for display without making consumers
/// parse it to distinguish an unanswered close from another I/O failure.
pub(crate) fn io_err(e: std::io::Error) -> Error {
	let code = match e.kind() {
		std::io::ErrorKind::TimedOut => sys::ERR_TIMEOUT,
		_ => sys::ERR_IO,
	};
	Error::with_detail(code, e.to_string())
}

#[cfg(test)]
#[test]
fn transport_timeouts_keep_their_class_without_reading_the_message() {
	let timeout = io_err(std::io::Error::new(std::io::ErrorKind::TimedOut, "arbitrary detail"));
	assert_eq!(timeout.kind(), crate::ErrorKind::TimedOut);
	assert_eq!(timeout.message(), Some("arbitrary detail"));
	let other = io_err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "timed out"));
	assert_eq!(other.kind(), crate::ErrorKind::Io);
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

/// A revocable caretaker over a capability (ADR-0016), returned by
/// [`crate::Session::caretaker`]. Hand [`proxy`](Caretaker::proxy) to a partner. Call
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
	pub(crate) ptr: Cell<*mut ffi::GlowcapHostSession>,
	key: usize,
	pub(crate) host: Rc<HostShared>,
	// The transport halves: the serve task takes the read half for its life;
	// FLUSH drains serialize on the write half's async lock, which keeps frames
	// in submission order. Order is all the lock gives: a write dropped
	// mid-frame still leaves a partial one on the wire, which `torn` records.
	// Both stay `None` on a loop-backed session, whose wire the driver loop
	// owns (`loop_wire`).
	pub(crate) reader: RefCell<Option<crate::channel::Reader>>,
	pub(crate) writer: Rc<tokio::sync::Mutex<Option<crate::channel::Writer>>>,
	pub(super) channel_close: RefCell<Option<Box<dyn crate::ChannelClose>>>,
	pub(super) channel_close_started: Cell<bool>,
	pub(super) channel_retiring: Cell<bool>,
	// The driver loop that owns this session's wire and its release (ADR-0024),
	// or `None` for a byte-fed session this binding pumps itself. A loop-backed
	// session has no byte pump: the loop reads, feeds, and flushes inside its
	// steps, and `glowcap_driver_session_release` is its one release verb.
	#[cfg(not(target_arch = "wasm32"))]
	pub(crate) loop_wire: Option<Rc<crate::driver_loop::LoopShared>>,
	// Set the moment teardown begins (an application close, or the transport
	// reporting EOF), so the serve loop can tell a read cancelled by our own
	// close from a real fault.
	pub(crate) closing: Cell<bool>,
	pub(crate) released: Cell<bool>,
	// Whether the loop has been told to serve this session. Serving is
	// idempotent in the driver, so the first success settles it here and later
	// verbs skip re-crossing the FFI.
	pub(crate) served: Cell<bool>,
	pub(crate) release_pending: Cell<bool>,
	// Terminal result projected by the core-issued CLOSE action or FFI
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
	/// The Host adopted this dial independently of application handles. An
	/// implicit final-handle drop must not condemn it. Explicit close still can.
	pub(crate) host_retained: Cell<bool>,
	// Set when an outbound write was dropped part-way through a frame, which a
	// caller does by cancelling: `tokio::time::timeout` around a send is
	// enough. `write_all` is not cancellation-safe, so some prefix of the frame
	// is already on the wire and the partner's framing is unrecoverable. The
	// lock serializes writers but cannot make one atomic. Once this is set the
	// session refuses further writes rather than appending to a stream the
	// partner can no longer parse. status-allow: lifecycle transition
	pub(crate) torn: Cell<bool>,
	// Wakes the serve task off its parked read when the connection closes.
	pub(crate) closed: Notify,
	// The auto-started serve task's handle; `Session::serve` takes it.
	serving: Cell<Option<tokio::task::JoinHandle<Result<()>>>>,
}

impl SessionShared {
	// The stream shorthand exists for `session_tests`, so it carries that
	// module's own gate. Gated on `test` alone it was dead under any feature set
	// that compiles the tests without `tcp`, `--features iroh` is one the build
	// checks, and `dead_code = "deny"` turned that into a compile error rather
	// than a warning nobody read.
	#[cfg(all(test, feature = "tcp"))]
	pub(crate) fn new<S>(ptr: *mut ffi::GlowcapHostSession, host: Rc<HostShared>, stream: S) -> Rc<SessionShared>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		Self::new_channel(ptr, host, crate::Channel::stream(stream))
	}

	pub(crate) fn new_channel(
		ptr: *mut ffi::GlowcapHostSession,
		host: Rc<HostShared>,
		channel: crate::Channel,
	) -> Rc<SessionShared> {
		let crate::Channel { reader, writer, close } = channel;
		let shared = Rc::new(SessionShared {
			ptr: Cell::new(ptr),
			key: ptr as usize,
			host: Rc::clone(&host),
			reader: RefCell::new(Some(reader)),
			writer: Rc::new(tokio::sync::Mutex::new(Some(writer))),
			#[cfg(not(target_arch = "wasm32"))]
			loop_wire: None,
			channel_close: RefCell::new(close),
			channel_close_started: Cell::new(false),
			channel_retiring: Cell::new(false),
			closing: Cell::new(false),
			released: Cell::new(false),
			served: Cell::new(false),
			release_pending: Cell::new(false),
			close_result: Cell::new(None),
			wire_failure: RefCell::new(None),
			close_task: RefCell::new(None),
			owner_handles: Cell::new(0),
			host_retained: Cell::new(false),
			torn: Cell::new(false),
			closed: Notify::new(),
			serving: Cell::new(None),
		});
		// Join the host's registry so a FLUSH action can find the transport and
		// a dialed exporter stays reachable for teardown.
		host.register_session(shared.key, Rc::clone(&shared));
		shared
	}

	/// The loop-backed shell (ADR-0024): a real `GlowcapHostSession` the FFI
	/// loop minted (dial, accept, or an internal redeem), with no byte halves:
	/// the loop owns the wire, the pumping, and the release. Registered in the
	/// host's session directory like any other shell, so the loop's
	/// SESSION_CLOSED dispatch and `exporter_for` both find it.
	#[cfg(not(target_arch = "wasm32"))]
	pub(crate) fn new_loop(
		ptr: *mut ffi::GlowcapHostSession,
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
			channel_close: RefCell::new(None),
			channel_close_started: Cell::new(false),
			channel_retiring: Cell::new(false),
			closing: Cell::new(false),
			released: Cell::new(false),
			served: Cell::new(false),
			release_pending: Cell::new(false),
			close_result: Cell::new(None),
			wire_failure: RefCell::new(None),
			close_task: RefCell::new(None),
			owner_handles: Cell::new(0),
			host_retained: Cell::new(false),
			torn: Cell::new(false),
			closed: Notify::new(),
			serving: Cell::new(None),
		});
		host.register_session(shared.key, Rc::clone(&shared));
		shared
	}

	pub(crate) fn raw_session(&self) -> *mut ffi::GlowcapHostSession {
		self.ptr.get()
	}

	/// Record custody held by the Host independently of application handles.
	/// Both byte-fed DIAL actions and loop-internal redeems cross this boundary.
	pub(crate) fn retain_by_host(&self) {
		self.host_retained.set(true);
	}

	pub(crate) fn host_key(&self) -> usize {
		Rc::as_ptr(&self.host) as usize
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
	/// session reaches this from its first wire verb. An accepted session may
	/// instead call `Session::serve` after publishing. Byte-fed sessions already
	/// own their reader task, so this is a no-op for them.
	pub(crate) fn attend_inbound(self: &Rc<Self>) -> Result<()> {
		if self.served.get() {
			return Ok(());
		}
		#[cfg(not(target_arch = "wasm32"))]
		if let Some(loop_) = self.loop_wire.as_ref() {
			loop_.serve_session(self.raw_session())?;
		}
		self.served.set(true);
		Ok(())
	}

	pub(crate) fn session_open(&self) -> bool {
		!self.host.closing()
			&& !self.released.get()
			// SAFETY: `self.ptr` is this `SessionShared`'s `GlowcapHostSession` handle, owned by the Host and nulled
			// only by `commit_ffi_release`; the short-circuit on `released` above means a released session never
			// reaches the call, and the callee only reads the handle and returns a status.
			&& unsafe { ffi::glowcap_host_session_is_open(self.ptr.get()) } == 1
	}

	// ── The pump ────────────────────────────────────────────────────────────────

	// Spawn the inbound serve loop as its own task. Runs from establish, so a
	// connection pumps from birth: an accepted partner's traffic and a dialed
	// exporter's withdraw both arrive without an explicit `serve()` call.
	// A loop-backed session has no byte pump of its own, the driver loop
	// reads, feeds, and drains, so its serve task only awaits the session's
	// closure, keeping the completes-on-close contract.
	pub(crate) fn spawn_serve(self: &Rc<SessionShared>) {
		let shared = Rc::clone(self);
		#[cfg(not(target_arch = "wasm32"))]
		if self.loop_wire.is_some() {
			let handle = tokio::task::spawn_local(async move {
				let notified = shared.closed.notified();
				tokio::pin!(notified);
				notified.as_mut().enable();
				if !shared.released.get() {
					notified.await;
				}
				shared.terminal_result()
			});
			self.serving.set(Some(handle));
			return;
		}
		let handle = tokio::task::spawn_local(async move { crate::pump::serve_loop(shared).await });
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
		self.channel_retiring.set(true);
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
		if self.finish_ffi_release().is_err() && !self.release_pending.replace(true) {
			crate::finalizer::park_session(Rc::clone(self));
			self.host.schedule_kick_or_record();
		}
		// The release queued FAIL completions (and sibling withdraws may have
		// failed closed): route them now.
		self.host.schedule_kick_or_record();
	}

	pub(crate) fn finish_ffi_release(self: &Rc<SessionShared>) -> Result<()> {
		if self.released.get() {
			self.release_pending.set(false);
			return Ok(());
		}
		if !self.retire_channel()? {
			return Ok(()); // the owned retirement task resumes this release
		}
		let ptr = self.ptr.get();
		if !ptr.is_null() {
			self.host.release_ffi_session(ptr)?;
		}
		self.commit_ffi_release();
		Ok(())
	}

	/// Commit wrapper retirement after its FFI owner has released either this
	/// handle or the whole loop. No FFI call may follow this transition.
	pub(crate) fn commit_ffi_release(&self) {
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
				let mut reference = sys::GlowcapReference { id: 0 };
				// SAFETY: `cell` is the fresh unregistered `ActorCell` that `HostShared::actor_cell` boxed, so nothing
				// else holds it; the closure makes the one `glowcap_host_session_spawn` call on `self.ptr`, the live
				// session handle owned by this `SessionShared` (guarded open above), and the host's single thread runs
				// no other access to the cell during it. `trampoline` and `ctx_free` are the binding's callbacks for an
				// `ActorCell`, and `reference` is a local out-parameter the callee writes.
				unsafe {
					register_actor_cell(
						cell,
						|| {
							ffi::glowcap_host_session_spawn(
								self.ptr.get(),
								trampoline,
								cell as *mut core::ffi::c_void,
								ctx_free,
								&mut reference,
							)
						},
						|code| code == sys::OK,
					)?;
				}
				reference.id
			}
		};
		Ok(Ref::bare_id(id))
	}

	pub(crate) fn publish_actor(self: &Rc<SessionShared>, name: &str, behavior: InternalBehavior) -> Result<Ref> {
		self.guard_open()?;
		self.drain_gc()?;
		let cell = self.host.actor_cell(behavior)?;
		let mut reference = sys::GlowcapReference { id: 0 };
		// SAFETY: as `spawn_actor` above, with `glowcap_host_session_publish`; `name` is a `&str` borrowed for the
		// whole call, and `reference` is the local out-parameter the callee writes.
		unsafe {
			register_actor_cell(
				cell,
				|| {
					ffi::glowcap_host_session_publish(
						self.ptr.get(),
						name.as_ptr(),
						name.len(),
						trampoline,
						cell as *mut core::ffi::c_void,
						ctx_free,
						&mut reference,
					)
				},
				|code| code == sys::OK,
			)?;
		}
		Ok(Ref::bare_id(reference.id))
	}

	// ── The verbs' shared plumbing ─────────────────────────────────────────────

	/// The Host routes every target, including locally hosted actors.
	pub(crate) fn tell(self: &Rc<SessionShared>, target: &Ref, verb: &str, args: &[Argument]) -> Result<()> {
		self.guard_open()?;
		self.drain_gc()?;
		let _arrival = DeliverGuard::enter(self);
		self.attend_inbound()?;
		let wire = target.to_sys()?;
		let mut arena = SendArena::for_host(&self.host);
		let (args_ptr, args_len) = arena.build(args)?;
		// SAFETY: `self.ptr` is this `SessionShared`'s live session handle (guarded open above); `wire` is a local
		// `GlowcapReference` borrowed for the call, `verb` is a `&str` borrowed for the call, and `args_ptr`/`args_len`
		// come from `arena`, a live local `SendArena` that outlives the call; the header says the host copies what it
		// queues.
		arena.finish(check_host(unsafe {
			ffi::glowcap_host_session_tell(self.ptr.get(), &wire, verb.as_ptr(), verb.len(), args_ptr, args_len)
		}))?;
		self.host.schedule_kick()
	}

	// ── Distributed GC (ADR-0025), on by default and set per Host ──────────────

	// Drain the parked GC releases: see [`crate::gc::drain`].
	pub(crate) fn drain_gc(&self) -> Result<()> {
		crate::gc::drain(&self.host)
	}
}
