//! The behavior trampoline: the ONE native callback in the whole binding
//! (plus its ctx-free sibling). Every hosted object — a
//! [`Session::spawn`](crate::Session::spawn) /
//! [`publish`](crate::Session::publish) actor, a caretaker or attenuator
//! proxy, a host-wide giftable — shares a single process-lifetime
//! `PancakeHostBehavior` whose ctx is a [`Box<ActorCell>`] raw pointer;
//! `PancakeHostCtxFree` re-boxes and drops it exactly once when the Host tears
//! the object down at Host release, so there is no keep table and
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
//! hosted by the same Host composes in process, a far target defers the
//! answer onto the forwarded send's vow.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::host::{check_host, drain_pending_releases, host_last_error};
use crate::promise::CmdTarget;
use crate::session_shared::{Caretaker, SessionShared};
use crate::sys::host as ffi;
use crate::{args_from_sys, sys, Argument, Error, Ref, Result, SendArena};

/// What one turn of a hosted behavior produced: a plain reply value, a
/// tail-forward of the answer to another reference (ADR-0064), or a broken
/// answer carrying the behavior's own diagnostic.
pub(crate) enum TurnOutcome {
	Value(Argument),
	Forward {
		target: Ref,
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

/// ADR-0064 caretaker: spawn a proxy that forwards to `target` until revoke,
/// then breaks every call `Revoked`.
pub(crate) fn caretaker_proxy(shared: &Rc<SessionShared>, target: &Ref) -> Result<Caretaker> {
	let live = Arc::new(AtomicBool::new(true));
	let flag = Arc::clone(&live);
	let target = target.clone();
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
	Ok(Caretaker::new(shared.spawn_actor(behavior)?, live))
}

/// ADR-0064 attenuator: spawn a proxy that forwards only allow-listed verbs
/// and breaks every other call `Attenuated`.
pub(crate) fn attenuate_proxy(shared: &Rc<SessionShared>, target: &Ref, verbs: &[&str]) -> Result<Ref> {
	let allowed: HashSet<String> = verbs.iter().map(|verb| verb.to_string()).collect();
	let target = target.clone();
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
	shared.spawn_actor(behavior)
}

/// One hosted object's behavior. Its identity and local-composition index live
/// on the Host; the Port delivering a wire turn is supplied by the feed bracket.
/// Owned by the Host row: `ctx = Box::into_raw`, freed exactly once by
/// [`ctx_free`] when the Host tears the object down.
pub(crate) struct ActorCell {
	pub(crate) behavior: RefCell<InternalBehavior>,
	pub(crate) context: Rc<crate::ContextInner>,
	pub(crate) diagnostic_id: u64,
}

// What a hosted callback reads as the arriving deliver context. The byte-fed
// pump brackets each feed with the arriving Session; a native loop step
// (ADR-0112) delivers for any of its host's sessions at once, so it brackets
// itself with the loop's adopted Host instead — the loop-tier sibling of the
// Session bracket, which is what latches a turn to its Host (turn-time spawn)
// when a behavior fires inside `pancake_driver_step`.
enum DeliverCtx {
	Session(Weak<SessionShared>),
	Host(Weak<crate::host::HostShared>),
}

// The deliver context whose feed (or loop step) is running. Hosted callbacks
// fire synchronously inside that FFI call, so this supplies the arriving Port
// (or at least its Host) even after the Port that originally spawned the
// actor has closed.
thread_local! {
	static ACTIVE_DELIVER: RefCell<Option<DeliverCtx>> = const { RefCell::new(None) };
}

pub(crate) struct DeliverGuard {
	prev: Option<DeliverCtx>,
}

impl DeliverGuard {
	pub(crate) fn enter(session: &Rc<SessionShared>) -> DeliverGuard {
		let prev = ACTIVE_DELIVER.with(|active| active.replace(Some(DeliverCtx::Session(Rc::downgrade(session)))));
		DeliverGuard { prev }
	}

	/// The loop-step bracket: behaviors fired inside `pancake_driver_step`
	/// latch their turns to the loop's adopted Host through this.
	pub(crate) fn enter_host(host: &Rc<crate::host::HostShared>) -> DeliverGuard {
		let prev = ACTIVE_DELIVER.with(|active| active.replace(Some(DeliverCtx::Host(Rc::downgrade(host)))));
		DeliverGuard { prev }
	}
}

impl Drop for DeliverGuard {
	fn drop(&mut self) {
		ACTIVE_DELIVER.with(|active| {
			active.replace(self.prev.take());
		});
	}
}

fn active_deliver() -> Option<Rc<SessionShared>> {
	ACTIVE_DELIVER.with(|active| match active.borrow().as_ref() {
		Some(DeliverCtx::Session(session)) => session.upgrade(),
		_ => None,
	})
}

// The Host key of the running deliver, whichever bracket carries it: the
// arriving Session's Host on the byte-fed path, the adopted Host itself on a
// loop step. Zero outside any deliver.
fn active_deliver_host_key() -> usize {
	ACTIVE_DELIVER.with(|active| match active.borrow().as_ref() {
		Some(DeliverCtx::Session(session)) => session.upgrade().map(|session| session.host_key()).unwrap_or(0),
		Some(DeliverCtx::Host(host)) => host.upgrade().map(|host| Rc::as_ptr(&host) as usize).unwrap_or(0),
		None => 0,
	})
}

// The turn context while a hosted object's trampoline runs: the opaque
// `PancakeHostTurn*` and the identity of the Session whose Port delivered it,
// or None outside any turn. `Session::spawn` reads it to
// pick the turn-time spawn over the top-level one (which the host refuses
// inside a callback); the action drain reads it to defer to the enclosing
// verb's unwind. A plain thread-local is enough: behaviors are synchronous, so
// no task switch can happen between the set and the read.
thread_local! {
	static CURRENT_TURN: Cell<Option<(usize, usize)>> = const { Cell::new(None) };
}

/// The current turn pointer when it belongs to `host_key` (the
/// `Rc<HostShared>` address), else `None`.
pub(crate) fn current_turn_for(host_key: usize) -> Option<*mut ffi::PancakeHostTurn> {
	CURRENT_TURN.with(|t| match t.get() {
		Some((turn, key)) if key == host_key => Some(turn as *mut ffi::PancakeHostTurn),
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

/// Marks a locally-run behavior (`SessionShared::run_hosted`) for its synchronous
/// duration, so a behavior that closes or drops its own captured `Session`
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
	fn enter(turn: *mut ffi::PancakeHostTurn, host_key: usize) -> TurnGuard {
		let prev = CURRENT_TURN.with(|t| t.replace(Some((turn as usize, host_key))));
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

/// Chase a behavior outcome through the locally hosted `Forward` prefix:
/// while it forwards to a near target this session hosts, run that
/// behavior in the same turn (a caretaker over an attenuator composes
/// exactly as it does over the wire). Returns the terminal — a `Value`, a
/// `Break`, or the first `Forward` whose target is not hosted here, which
/// each caller defers its own way: the trampoline through the host's
/// turn-forward, `send` onto the forwarded send's wire reply, `tell` as a
/// far tell. Shared by the wire trampoline and `Session`'s local send arm.
pub(crate) fn chase_local_forwards(session: &SessionShared, mut outcome: TurnOutcome) -> TurnOutcome {
	// The wire path defers each hop onto a fresh turn, so a forward cycle
	// there loops asynchronously; the local chase runs hops synchronously
	// and must bound them, or a caretaker forwarding to itself spins this
	// loop forever. Legitimate proxy chains are a handful deep.
	const MAX_LOCAL_FORWARD_HOPS: usize = crate::abi_constants::MAX_LOCAL_FORWARD_HOPS;
	let mut hops = 0usize;
	loop {
		let TurnOutcome::Forward { target, verb, args } = outcome else {
			return outcome;
		};
		hops += 1;
		if hops > MAX_LOCAL_FORWARD_HOPS {
			return TurnOutcome::Break(crate::abi_constants::FORWARD_CYCLE_MESSAGE.to_string());
		}
		let hosted = session.hosted_cell(target.id());
		let Some(cell) = hosted else {
			return TurnOutcome::Forward { target, verb, args };
		};
		// The cell is host-owned and alive while its Host is
		// unreleased; the hosted table is cleared before the release that
		// frees it.
		let cell = unsafe { &*cell };
		outcome = (cell.behavior.borrow_mut())(&verb, &args);
	}
}

/// Run the hosted behavior at `ref_id` and chase its Forward prefix, or
/// `None` when this side does not host it — the one lookup/run/chase prefix
/// under the local send and tell arms.
pub(crate) fn run_hosted(shared: &SessionShared, ref_id: u64, verb: &str, args: &[Argument]) -> Option<TurnOutcome> {
	let cell = shared.hosted_cell(ref_id)?;
	let outcome = {
		// The local-turn marker: a behavior that closes (or drops) its own
		// captured `Session` mid-run would otherwise take
		// `close_transport`'s immediate-release arm and free this very
		// cell's `Box<ActorCell>` while its `behavior.borrow_mut()` frame
		// is still on the stack. With the marker, `inside_turn()` is true
		// and the release parks, exactly as on the wire path's `TurnGuard`.
		let _guard = LocalRunGuard::enter();
		let first = {
			let cell = unsafe { &*cell };
			(cell.behavior.borrow_mut())(verb, args)
		};
		chase_local_forwards(shared, first)
	};
	// The marker dropped before anything can await (the callers' own
	// Forward-to-far send comes after this returns): run the parked
	// releases and kick the drain, mirroring the feed path.
	drain_pending_releases();
	if let Err(error) = shared.host.schedule_kick() {
		shared.host.fail_pending_vows(error.code(), &error.to_string());
	}
	Some(outcome)
}

/// The local arm of `send`, run on first observation: a `Forward` to another
/// object this side hosts composes in process; a `Forward` to a far target
/// defers the answer onto the forwarded send's reply (ADR-0064); a behavior
/// error breaks with its own words, as over the wire.
pub(crate) async fn run_local_send(
	shared: Rc<SessionShared>,
	ref_id: u64,
	verb: String,
	args: Vec<Argument>,
) -> Result<Argument> {
	let Some(outcome) = run_hosted(&shared, ref_id, &verb, &args) else {
		return Err(Error::broken("no such hosted object".to_string()));
	};
	match outcome {
		TurnOutcome::Value(value) => Ok(value),
		TurnOutcome::Break(message) => Err(Error::broken(message)),
		TurnOutcome::Forward { target, verb, args } => {
			crate::promise::send_promise(&shared, CmdTarget::Ref(target), &verb, &args).await
		}
	}
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
	session: Option<&SessionShared>,
	turn: *mut ffi::PancakeHostTurn,
	outcome: TurnOutcome,
	out_reply: *mut sys::PancakeArgument,
) -> i32 {
	// The locally hosted Forward prefix runs in this same turn through the Host
	// index reached by the arriving Session.
	let outcome = match session {
		Some(session) => chase_local_forwards(session, outcome),
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
				ffi::pancake_host_turn_forward(turn, &wire, verb.as_ptr(), verb.len(), args_ptr, args_len, out_reply)
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
	let session = active_deliver();
	let host_key = active_deliver_host_key();
	let _guard = TurnGuard::enter(turn, host_key);
	let outcome = (cell.behavior.borrow_mut())(&verb, &args);
	settle_reply(session.as_deref(), turn, outcome, out_reply)
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
			// A panic may not cross the C frame. If even projecting its break
			// panics, return an explicit internal refusal; reporting OK would tell
			// the host a reply was committed when none was.
			let message = crate::panic_message(payload.as_ref());
			catch_unwind(AssertUnwindSafe(|| turn_break(turn, &message))).unwrap_or(sys::ERR_INTERNAL)
		}
	}
}

/// The ctx-free sibling: re-box and drop the [`ActorCell`] the registration
/// handed the host. Runs exactly once per row that took ownership, at Host
/// release; it calls no `pancake_host_*` function, and a
/// panicking drop is swallowed rather than unwound across the C frame.
pub(crate) unsafe extern "C" fn ctx_free(ctx: *mut core::ffi::c_void) {
	if ctx.is_null() {
		return;
	}
	let cell = Box::from_raw(ctx as *mut ActorCell);
	let context = Rc::clone(&cell.context);
	let diagnostic_id = cell.diagnostic_id;
	if let Err(error) = drop_actor_cell(cell) {
		context.report_failure(
			crate::FailureLayer::Binding,
			crate::FailureScope::Host,
			diagnostic_id,
			0,
			"actor-cell.drop",
			&error,
		);
	}
}

fn drop_actor_cell(cell: Box<ActorCell>) -> Result<()> {
	catch_unwind(AssertUnwindSafe(|| drop(cell)))
		.map_err(|payload| Error::with_detail(sys::ERR_INTERNAL, crate::panic_message(payload.as_ref())))
}

/// Reclaim a registration's cell when the minting call refused it without
/// taking ownership (a null-pointer or reentry refusal, per the header's
/// publish/spawn contract); any later failure already ran [`ctx_free`].
pub(crate) unsafe fn reclaim_refused_cell(code: i32, cell: *mut ActorCell) -> Result<()> {
	if code == sys::ERR_NULL_POINTER || code == sys::ERR_INVALID_ARGUMENT {
		return drop_actor_cell(Box::from_raw(cell));
	}
	Ok(())
}

/// Spawn a hosted object from INSIDE a turn — the turn-time form the host
/// allows where the top-level spawn is refused. Returns its opaque Host id; on
/// a refusal that left ctx ours the cell is
/// reclaimed.
pub(crate) fn turn_spawn(turn: *mut ffi::PancakeHostTurn, cell: *mut ActorCell) -> Result<u64> {
	let mut reference = sys::PancakeReference { id: 0 };
	let rc = unsafe {
		ffi::pancake_host_turn_spawn(
			turn,
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
	Ok(reference.id)
}
