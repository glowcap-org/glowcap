//! Per-connection capability handles and shared state: [`Ref`], [`Caretaker`],
//! and [`SessionShared`]. [`Session`](crate::Session) is the application handle
//! over one `SessionShared`; pump/host/trampoline/gc borrow `SessionShared` directly.
//! Binding spine Pass 5 (conn extraction).

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::Notify;

use crate::host::{check_host, park_session_release, try_spawn_local, HostShared};
use crate::sys::driver as ffi;
use crate::trampoline::{
	ctx_free, current_turn_for, inside_turn, reclaim_refused_cell, trampoline, turn_spawn,
	ActorCell, InternalBehavior, TurnOutcome,
};
use crate::{sys, Argument, Error, Reference, Result, SendArena};

pub(crate) const READ_CHUNK: usize = 16 * 1024;

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
/// You get a `Ref` from [`Session::spawn`] (a local actor you host),
/// [`Session::fetch`] (a capability a partner published), or a capability a
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
	guard: Option<Rc<crate::gc::ImportGuard>>,
}

impl Ref {
	/// The underlying wire reference (for the rare power-user path).
	pub fn reference(&self) -> Reference {
		self.reference.clone()
	}

	// A reference with no GC death rite, the default for everything but a
	// GC-tracked fetch result.
	pub(crate) fn bare(reference: Reference) -> Ref {
		Ref {
			reference,
			guard: None,
		}
	}

	// A far capability carrying its distributed-GC death rite (ADR-0063).
	pub(crate) fn tracked(reference: Reference, guard: Rc<crate::gc::ImportGuard>) -> Ref {
		Ref {
			reference,
			guard: Some(guard),
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

/// The per-connection state the handle, the serve task, and the host's action
/// drain share. Fields the [`crate::pump`] path reads are `pub(crate)`.
pub(crate) struct SessionShared {
	pub(crate) ptr: Cell<*mut ffi::PancakeHostSession>,
	key: usize,
	pub(crate) host: Rc<HostShared>,
	// The transport halves: the serve task takes the read half for its life;
	// FLUSH drains serialize on the write half's async lock so frames stay
	// whole and in submission order.
	pub(crate) reader: RefCell<Option<Box<dyn AsyncRead + Unpin>>>,
	pub(crate) writer: Rc<tokio::sync::Mutex<Option<Box<dyn AsyncWrite + Unpin>>>>,
	// Set the moment teardown begins (an application close, or the transport
	// reporting EOF), so the serve loop can tell a read cancelled by our own
	// close from a real fault.
	pub(crate) closing: Cell<bool>,
	pub(crate) released: Cell<bool>,
	// Wakes the serve task off its parked read when the connection closes.
	pub(crate) closed: Notify,
	// Wakes the serve task to drain parked GC tokens (a finalizer may fire
	// inside a behavior trampoline, where the release verbs are refused).
	pub(crate) gc_wakeup: Notify,
	// Export position -> hosted cell for the objects this session hosts, so
	// a `Forward` whose target this side hosts composes in process (and a send
	// to a self-spawned `Ref` runs in process). The cells are host-owned
	// (freed by ctx_free at teardown); this table is cleared before the
	// release that frees them.
	hosted: RefCell<HashMap<u64, *const ActorCell>>,
	// True for an exporter connection the host's action drain dialed to redeem
	// a handoff, so `close()` can sweep it.
	host_dialed: Cell<bool>,
	// Distributed GC (ADR-0063), opt-in and off by default.
	pub(crate) gc: Cell<bool>,
	pub(crate) gc_pending: RefCell<Vec<u64>>,
	// The auto-started serve task's handle; `Session::serve` takes it.
	serving: Cell<Option<tokio::task::JoinHandle<()>>>,
}

impl SessionShared {
	pub(crate) fn new<S>(
		ptr: *mut ffi::PancakeHostSession,
		host: Rc<HostShared>,
		stream: S,
	) -> Rc<SessionShared>
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
			closing: Cell::new(false),
			released: Cell::new(false),
			closed: Notify::new(),
			gc_wakeup: Notify::new(),
			hosted: RefCell::new(HashMap::new()),
			host_dialed: Cell::new(false),
			gc: Cell::new(false),
			gc_pending: RefCell::new(Vec::new()),
			serving: Cell::new(None),
		});
		// Join the host's registry so a FLUSH action can find the transport and
		// a dialed exporter stays reachable for teardown.
		host.register_session(shared.key, Rc::clone(&shared));
		shared
	}

	pub(crate) fn raw_conn(&self) -> *mut ffi::PancakeHostSession {
		self.ptr.get()
	}

	pub(crate) fn is_host_dialed(&self) -> bool {
		self.host_dialed.get()
	}

	/// The hosted cell behind a near export this session binds, for
	/// in-process `Forward` composition and the local send arm.
	pub(crate) fn hosted_cell(&self, position: u64) -> Option<*const ActorCell> {
		self.hosted.borrow().get(&position).copied()
	}

	pub(crate) fn closing(&self) -> bool {
		self.closing.get() || self.released.get()
	}

	pub(crate) fn guard_open(&self) -> Result<()> {
		if self.released.get() {
			Err(Error::with_detail(
				sys::ERR_CLOSED,
				"connection closed".to_string(),
			))
		} else {
			Ok(())
		}
	}

	pub(crate) fn session_open(&self) -> bool {
		!self.released.get()
			&& unsafe { ffi::pancake_host_session_session_open(self.ptr.get()) } == 1
	}

	// ── The pump ────────────────────────────────────────────────────────────────

	// Spawn the inbound serve loop as its own task. Runs from establish, so a
	// connection pumps from birth: an accepted partner's traffic and a dialed
	// exporter's withdraw both arrive without an explicit `serve()` call.
	pub(crate) fn spawn_serve(self: &Rc<SessionShared>) {
		let shared = Rc::clone(self);
		let handle = tokio::task::spawn_local(async move {
			crate::pump::serve_loop(shared).await;
		});
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
		self.released.set(true);
		self.host.unregister_session(self.key);
		// The cells behind these pointers are freed by the release below;
		// nothing may resolve through them afterwards.
		self.hosted.borrow_mut().clear();
		let ptr = self.ptr.replace(core::ptr::null_mut());
		if !ptr.is_null() {
			if inside_turn() {
				park_session_release(ptr, Rc::clone(&self.host));
			} else {
				unsafe { ffi::pancake_host_session_release(ptr) };
			}
		}
		// The release queued FAIL completions (and sibling withdraws may have
		// failed closed): route them now.
		self.host.schedule_kick();
	}

	pub(crate) fn mark_host_dialed(&self) {
		self.host_dialed.set(true);
	}

	/// Take the serve task's handle (the `Session::serve` future awaits it).
	pub(crate) fn take_serving(&self) -> Option<tokio::task::JoinHandle<()>> {
		self.serving.take()
	}

	// ── Hosting ─────────────────────────────────────────────────────────────────

	// Register `behavior` as a hosted object of this session: inside a
	// served turn through the turn-time spawn (the host refuses the top-level
	// one there), else through the session spawn.
	pub(crate) fn spawn_actor(self: &Rc<SessionShared>, behavior: InternalBehavior) -> Result<Ref> {
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
					ffi::pancake_host_session_spawn(
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

	pub(crate) fn publish_actor(
		self: &Rc<SessionShared>,
		name: &str,
		behavior: InternalBehavior,
	) -> Result<Ref> {
		self.guard_open()?;
		self.drain_gc();
		let cell = Box::into_raw(Box::new(ActorCell {
			behavior: RefCell::new(behavior),
			conn: Some(Rc::downgrade(self)),
		}));
		let mut position: u64 = 0;
		let rc = unsafe {
			ffi::pancake_host_session_publish(
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

	// The local arm of `tell`: deferred to its own task so a behavior telling a
	// self-hosted object never re-enters the running cell's borrow; the result
	// is discarded (no answer), a far forward continues as a far tell, and a
	// behavior error breaks nothing — there is no answer to break.
	// Called with no `LocalSet` running (practically unreachable: every path to
	// a live `Session` already required one), `try_spawn_local` swallows the
	// spawn and the tell is lost, a tolerated loss for a fire-and-forget verb
	// with no answer to strand.
	pub(crate) fn tell_local(
		self: &Rc<SessionShared>,
		position: u64,
		verb: String,
		args: Vec<Argument>,
	) {
		let shared = Rc::clone(self);
		try_spawn_local(async move {
			if let Some(TurnOutcome::Forward { target, verb, args }) =
				crate::trampoline::run_hosted(&shared, position, &verb, &args)
			{
				let _ = shared.tell_wire(&target, &verb, &args);
			}
		});
	}

	pub(crate) fn tell_wire(
		self: &Rc<SessionShared>,
		target: &Reference,
		verb: &str,
		args: &[Argument],
	) -> Result<()> {
		let wire = target.to_sys()?;
		let mut arena = SendArena::default();
		let (args_ptr, args_len) = arena.build(args)?;
		check_host(unsafe {
			ffi::pancake_host_session_tell(
				self.ptr.get(),
				&wire,
				verb.as_ptr(),
				verb.len(),
				args_ptr,
				args_len,
			)
		})?;
		self.host.schedule_kick();
		Ok(())
	}

	/// Near-hosted vs far tell dispatch: a self-hosted near runs `tell_local`,
	/// everything else mints through `tell_wire`. Session keeps the CapTP verb.
	pub(crate) fn tell(
		self: &Rc<SessionShared>,
		target: &Ref,
		verb: &str,
		args: &[Argument],
	) -> Result<()> {
		self.guard_open()?;
		self.drain_gc();
		let reference = target.reference();
		if let Reference::Near { id, .. } = &reference {
			if self.hosted_cell(*id).is_some() {
				self.tell_local(*id, verb.to_string(), args.to_vec());
				return Ok(());
			}
		}
		self.tell_wire(&reference, verb, args)
	}

	// ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

	// Drain the parked GC releases — see [`crate::gc::drain`].
	pub(crate) fn drain_gc(&self) {
		crate::gc::drain(self);
	}
}
