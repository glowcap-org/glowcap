//! The behavior trampoline: the ONE native callback in the whole binding
//! (plus its ctx-free sibling). Every hosted object — a
//! [`Connection::spawn`](crate::Connection::spawn) /
//! [`publish`](crate::Connection::publish) actor, a caretaker or attenuator
//! proxy, a node-wide giftable — shares a single process-lifetime
//! `PancakeHostBehavior` whose ctx is a [`Box<ActorCell>`] raw pointer;
//! `PancakeHostCtxFree` re-boxes and drops it exactly once when the host tears
//! the object down (connection or host release), so there is no keep table and
//! no leak. Settlements never cross the C boundary as callbacks; they ride the
//! action queue (SETTLE/FAIL, `crate::host`).
//!
//! Reply discipline: the vat copies `out_reply`'s payload the instant the
//! trampoline returns, so the marshalled reply and its owning value are
//! retained in the module's one keep slot across the return (overwritten by
//! the next reply — the previous one has long been copied). A panic must NEVER
//! cross the extern "C" frame (that is undefined behavior), so the body runs
//! under `catch_unwind` and every failure — a panicking behavior, an
//! attenuator's `Attenuated`, a revoked caretaker's `Revoked`, an
//! unknown-method error — crosses as `pancake_host_turn_break` carrying the
//! behavior's own words; a bare non-OK return would flatten them into a
//! generic reason. A [`TurnOutcome::Forward`] maps onto
//! `pancake_host_turn_forward` (the caretaker/attenuator primitive): a target
//! hosted by the same connection composes in process, a far target defers the
//! answer onto the forwarded send's vow.

use std::cell::{Cell, RefCell};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Weak;

use crate::connection::ConnShared;
use crate::host::{check_host, host_last_error};
use crate::sys::driver as ffi;
use crate::{args_from_sys, sys, Argument, Reference, Result, SendArena};

/// What one turn of a hosted behavior produced: a plain reply value, a
/// tail-forward of the answer to another reference (ADR-0064), or a broken
/// answer carrying the behavior's own diagnostic.
pub(crate) enum TurnOutcome {
	Value(Argument),
	Forward {
		target: Reference,
		verb: String,
		args: Vec<Argument>,
	},
	Break(String),
}

/// The internal behavior shape the trampoline runs. The public
/// [`Behavior`](crate::Behavior) (`Result<Argument, String>`) wraps into this;
/// the caretaker/attenuator proxies mint forwarding outcomes directly.
pub(crate) type InternalBehavior = Box<dyn FnMut(&str, &[Argument]) -> TurnOutcome>;

/// Wrap a public behavior into the internal outcome shape: `Ok` replies,
/// `Err(reason)` breaks the answer with the behavior's words.
pub(crate) fn outcome_behavior(
	mut behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
) -> InternalBehavior {
	Box::new(move |verb, args| match behavior(verb, args) {
		Ok(value) => TurnOutcome::Value(value),
		Err(reason) => TurnOutcome::Break(reason),
	})
}

/// One hosted object: its behavior, and the connection it serves (identity for
/// turn-ownership checks, and the hosted table a `Forward` chain composes
/// through in process). `None` for a node-wide giftable, whose forwards always
/// go through the host. Owned by the host row: `ctx = Box::into_raw`, freed
/// exactly once by [`ctx_free`] when the host tears the object down.
pub(crate) struct ActorCell {
	pub(crate) behavior: RefCell<InternalBehavior>,
	pub(crate) conn: Option<Weak<ConnShared>>,
}

// The turn context while a hosted object's trampoline runs: the opaque
// `PancakeHostTurn*` and the identity of the connection the turn arrived on
// (0 for a giftable), or None outside any turn. `Connection::spawn` reads it to
// pick the turn-time spawn over the top-level one (which the host refuses
// inside a callback); the action drain reads it to defer to the enclosing
// verb's unwind. A plain thread-local is enough: behaviors are synchronous, so
// no task switch can happen between the set and the read.
thread_local! {
	static CURRENT_TURN: Cell<Option<(usize, usize)>> = const { Cell::new(None) };
}

/// The current turn pointer when it belongs to the connection identified by
/// `conn_key` (the `Rc<ConnShared>` address), else `None`.
pub(crate) fn current_turn_for(conn_key: usize) -> Option<*mut ffi::PancakeHostTurn> {
	CURRENT_TURN.with(|t| match t.get() {
		Some((turn, key)) if key == conn_key => Some(turn as *mut ffi::PancakeHostTurn),
		_ => None,
	})
}

/// Whether ANY hosted turn is running — a wire-delivered turn under the host's
/// callback latch, or a locally-run behavior under [`LocalRunGuard`]. The drain
/// defers while one is (the host refuses the driving verbs inside a callback;
/// everything enqueued pumps when the enclosing call unwinds), and a connection
/// or host release parks instead of freeing the `ActorCell` whose behavior
/// frame is still on the stack.
pub(crate) fn inside_turn() -> bool {
	CURRENT_TURN.with(|t| t.get().is_some()) || LOCAL_RUN_DEPTH.with(|d| d.get() > 0)
}

// How many locally-run behavior frames are on this thread's stack. A local
// send/tell to a self-hosted object runs its behavior with no host turn, so the
// wire path's `TurnGuard` latch never engages; this sibling marker makes
// `inside_turn()` true for the run's duration without minting a fake turn
// pointer (which `current_turn_for` could hand to a turn verb).
thread_local! {
	static LOCAL_RUN_DEPTH: Cell<usize> = const { Cell::new(0) };
}

/// Marks a locally-run behavior (`ConnShared::run_hosted`) for its synchronous
/// duration, so a behavior that closes or drops its own captured `Connection`
/// parks the release — `close_transport`'s immediate arm would free the
/// `Box<ActorCell>` whose `behavior.borrow_mut()` frame is still running. The
/// caller drains the parked releases right after this drops, mirroring the
/// feed path.
pub(crate) struct LocalRunGuard;

impl LocalRunGuard {
	pub(crate) fn enter() -> LocalRunGuard {
		LOCAL_RUN_DEPTH.with(|d| d.set(d.get() + 1));
		LocalRunGuard
	}
}

impl Drop for LocalRunGuard {
	fn drop(&mut self) {
		LOCAL_RUN_DEPTH.with(|d| d.set(d.get() - 1));
	}
}

// Sets the turn context for one callback and restores the previous one on
// every exit path, unwinds included, so a panic can never leave a stale turn.
struct TurnGuard {
	prev: Option<(usize, usize)>,
}

impl TurnGuard {
	fn enter(turn: *mut ffi::PancakeHostTurn, conn_key: usize) -> TurnGuard {
		let prev = CURRENT_TURN.with(|t| t.replace(Some((turn as usize, conn_key))));
		TurnGuard { prev }
	}
}

impl Drop for TurnGuard {
	fn drop(&mut self) {
		CURRENT_TURN.with(|t| t.set(self.prev));
	}
}

// The most recent reply's owning value and its marshalled C tree's child
// arrays, retained across the trampoline's return so the host's immediate copy
// reads live memory. One slot suffices: the host copies before any other Rust
// code can run, so by the time this is overwritten the previous reply is long
// copied. The `Argument`'s heap payloads are address-stable when the value
// moves into the slot, so the pointers taken before the move stay valid.
thread_local! {
	static LAST_REPLY_KEEP: RefCell<Option<(Argument, SendArena)>> = const { RefCell::new(None) };
}

// Break this turn's answer with the actor's own diagnostic and return the code
// the trampoline hands back (OK: the break already settled the answer).
fn turn_break(turn: *mut ffi::PancakeHostTurn, message: &str) -> i32 {
	let rc = unsafe { ffi::pancake_host_turn_break(turn, message.as_ptr(), message.len()) };
	if rc == sys::OK {
		sys::OK
	} else {
		rc
	}
}

// Resolve a behavior's outcome into the turn's answer: a plain value marshals
// into the reply slot; a `Forward` composes in process when this side hosts
// the target, else defers through the host's turn-forward; a `Break` settles
// the answer broken with the behavior's own words.
fn settle_reply(
	cell: &ActorCell,
	turn: *mut ffi::PancakeHostTurn,
	outcome: TurnOutcome,
	out_reply: *mut sys::PancakeArgument,
) -> i32 {
	// The locally hosted Forward prefix runs in this same turn (a giftable has
	// no connection, so its forwards always go through the host).
	let outcome = match cell.conn.as_ref().and_then(|conn| conn.upgrade()) {
		Some(conn) => conn.chase_local_forwards(outcome),
		None => outcome,
	};
	match outcome {
		TurnOutcome::Break(message) => turn_break(turn, &message),
		TurnOutcome::Forward { target, verb, args } => {
			// The host forwards: the real answer rides the forwarded send's vow
			// and out_reply gets a void placeholder. The arena and args stay
			// pinned until the call returns.
			let wire = match target.to_sys() {
				Ok(wire) => wire,
				Err(_) => return turn_break(turn, "forward target is not sendable"),
			};
			let mut arena = SendArena::default();
			let (args_ptr, args_len) = match arena.build(&args) {
				Ok(built) => built,
				Err(_) => return turn_break(turn, "forward arguments failed to marshal"),
			};
			let rc = unsafe {
				ffi::pancake_host_turn_forward(
					turn,
					&wire,
					verb.as_ptr(),
					verb.len(),
					args_ptr,
					args_len,
					out_reply,
				)
			};
			if rc != sys::OK {
				let reason = host_last_error().unwrap_or_else(|| "forward refused".to_string());
				return turn_break(turn, &reason);
			}
			sys::OK
		}
		TurnOutcome::Value(value) => {
			// The keep slot pins the reply's owning value and the marshalled
			// tree's child arrays across the return; the host copies the
			// payload the instant the trampoline returns.
			let mut arena = SendArena::default();
			let c = match arena.one(&value) {
				Ok(c) => c,
				Err(_) => return turn_break(turn, "reply failed to marshal"),
			};
			unsafe { *out_reply = c };
			LAST_REPLY_KEEP.with(|keep| *keep.borrow_mut() = Some((value, arena)));
			sys::OK
		}
	}
}

// The shared trampoline body: decode the deliver, run the cell's behavior
// under the turn context, and settle the reply.
unsafe fn trampoline_body(
	ctx: *mut core::ffi::c_void,
	turn: *mut ffi::PancakeHostTurn,
	verb: *const u8,
	verb_len: usize,
	args: *const sys::PancakeArgument,
	args_len: usize,
	out_reply: *mut sys::PancakeArgument,
) -> i32 {
	if ctx.is_null() {
		return turn_break(turn, "no such hosted object");
	}
	let cell = &*(ctx as *const ActorCell);
	// A zero-length verb is the positional call (the Goblins methodless shape).
	let verb = if verb_len == 0 || verb.is_null() {
		String::new()
	} else {
		String::from_utf8_lossy(core::slice::from_raw_parts(verb, verb_len)).into_owned()
	};
	// The one owned lift per deliver: the borrowed C args become owned Rust
	// values before any behavior code can run.
	let args = args_from_sys(args, args_len);
	let conn_key = cell
		.conn
		.as_ref()
		.map(|weak| weak.as_ptr() as usize)
		.unwrap_or(0);
	let _guard = TurnGuard::enter(turn, conn_key);
	let outcome = (cell.behavior.borrow_mut())(&verb, &args);
	settle_reply(cell, turn, outcome, out_reply)
}

// Render a caught panic payload as the diagnostic the break carries, so a
// behavior's `panic!("Revoked")` reaches the caller with its own words.
fn panic_text(payload: &(dyn std::any::Any + Send)) -> String {
	if let Some(text) = payload.downcast_ref::<&str>() {
		(*text).to_string()
	} else if let Some(text) = payload.downcast_ref::<String>() {
		text.clone()
	} else {
		"behavior panicked".to_string()
	}
}

/// The one shared `PancakeHostBehavior` in the process. A panic in the
/// behavior (or anywhere in the body) is caught here — never unwound across
/// the C frame — and settles the answer broken with the panic's own message.
pub(crate) unsafe extern "C" fn trampoline(
	ctx: *mut core::ffi::c_void,
	turn: *mut ffi::PancakeHostTurn,
	verb: *const u8,
	verb_len: usize,
	args: *const sys::PancakeArgument,
	args_len: usize,
	out_reply: *mut sys::PancakeArgument,
) -> i32 {
	match catch_unwind(AssertUnwindSafe(|| {
		trampoline_body(ctx, turn, verb, verb_len, args, args_len, out_reply)
	})) {
		Ok(code) => code,
		Err(payload) => {
			// Best-effort break carrying the panic's words; a second panic while
			// breaking is swallowed (the non-OK-return generic break stands in).
			let message = panic_text(payload.as_ref());
			catch_unwind(AssertUnwindSafe(|| turn_break(turn, &message))).unwrap_or(sys::OK)
		}
	}
}

/// The ctx-free sibling: re-box and drop the [`ActorCell`] the registration
/// handed the host. Runs exactly once per row that took ownership, at
/// connection or host release; it calls no `pancake_host_*` function, and a
/// panicking drop is swallowed rather than unwound across the C frame.
pub(crate) unsafe extern "C" fn ctx_free(ctx: *mut core::ffi::c_void) {
	if ctx.is_null() {
		return;
	}
	let _ = catch_unwind(AssertUnwindSafe(|| {
		drop(Box::from_raw(ctx as *mut ActorCell));
	}));
}

/// Reclaim a registration's cell when the minting call refused it without
/// taking ownership (a null-pointer or reentry refusal, per the header's
/// publish/spawn contract); any later failure already ran [`ctx_free`].
pub(crate) unsafe fn reclaim_refused_cell(code: i32, cell: *mut ActorCell) {
	if code == sys::ERR_NULL_POINTER || code == sys::ERR_INVALID_ARGUMENT {
		drop(Box::from_raw(cell));
	}
}

/// Spawn a hosted object at a fresh export position from INSIDE a turn — the
/// turn-time form the host allows where the top-level spawn is refused.
/// Returns the export position; on a refusal that left ctx ours the cell is
/// reclaimed.
pub(crate) fn turn_spawn(turn: *mut ffi::PancakeHostTurn, cell: *mut ActorCell) -> Result<u64> {
	let mut position: u64 = 0;
	let rc = unsafe {
		ffi::pancake_host_turn_spawn(
			turn,
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
	Ok(position)
}
