//! The [`RemotePromise`] a [`Session`](crate::Session) send returns: lazy
//! observation, promise pipelining target, and `index`/`untag` projection
//! (ADR-0007 / ADR-0050 / ADR-0052). Also the shared fetch/enliven
//! mint→await→classify path (`await_minted` / `fetch_like`) and the far-send
//! mint→`RemotePromise` factory (`send_promise`). Session owns CapTP verb
//! wrappers; this module owns the handle type, post-mint wait/classify, and
//! send→promise construction. Binding spine Pass 3a / 4b / 4d.

use std::future::{Future, IntoFuture};
use std::pin::Pin;
use std::rc::Rc;

use crate::host::check_host;
use crate::session_shared::{Ref, SessionShared};
use crate::sys::driver as ffi;
use crate::{sys, Argument, Error, Reference, Result, SendArena};

/// Shared fetch/enliven wait: the mint already registered the vow; kick the
/// drain so the deliver leaves now, and await the drain-routed outcome.
pub(crate) async fn await_minted(shared: &Rc<SessionShared>, vow: u64) -> Result<Argument> {
	shared.host.vow_minted(vow);
	let settled = shared.host.await_vow(vow);
	shared.host.kick_actions().await;
	settled.await
}

/// The one mint/await/classify body under `fetch` and `enliven`: mint the
/// host vow with `mint`, await its drain-routed completion, and classify —
/// only a live near/far reference is a capability this surface can hand out.
/// `track` marks the Far arm for distributed GC via `track_import`.
pub(crate) async fn fetch_like(
	shared: &Rc<SessionShared>,
	swiss: &[u8],
	label: &str,
	mint: unsafe extern "C" fn(*mut ffi::PancakeHostSession, *const u8, usize, *mut u64) -> i32,
	track: bool,
	track_import: impl FnOnce(Reference) -> Ref,
) -> Result<Ref> {
	shared.guard_open()?;
	shared.drain_gc();
	let mut vow: u64 = 0;
	check_host(unsafe { mint(shared.ptr.get(), swiss.as_ptr(), swiss.len(), &mut vow) })?;
	let value = await_minted(shared, vow).await?;
	match value {
		Argument::Reference(reference @ Reference::Near { .. }) => Ok(Ref::bare(reference)),
		Argument::Reference(reference @ Reference::Far { .. }) if track => {
			Ok(track_import(reference))
		}
		Argument::Reference(reference @ Reference::Far { .. }) => Ok(Ref::bare(reference)),
		_ => Err(Error::broken(format!(
			"{label:?} did not resolve to a capability"
		))),
	}
}

/// The send spine both `Session::send` and a local `Forward`'s far arm
/// ride: mint the vow (which IS the registration) under the same synchronous
/// call stack, then hand back the promise.
pub(crate) fn send_promise(
	shared: &Rc<SessionShared>,
	target: CmdTarget,
	verb: &str,
	args: &[Argument],
) -> RemotePromise {
	let failed =
		|error: Error, conn: &Rc<SessionShared>| RemotePromise::failed(error, Rc::clone(conn));
	if let Err(error) = shared.guard_open() {
		return failed(error, shared);
	}
	shared.drain_gc();
	// A send to an object this side hosts runs its behavior in process — a
	// proxy over a *far* target then defers onto the wire reply, the same
	// forward semantics a partner's delivery gets (ADR-0064).
	if let CmdTarget::Ref(Reference::Near { id, .. }) = &target {
		if shared.hosted_cell(*id).is_some() {
			return RemotePromise::local(*id, verb.to_string(), args.to_vec(), Rc::clone(shared));
		}
	}
	let mut arena = SendArena::default();
	let (args_ptr, args_len) = match arena.build(args) {
		Ok(built) => built,
		Err(error) => return failed(error, shared),
	};
	let mut vow: u64 = 0;
	let rc = match &target {
		CmdTarget::Ref(reference) => {
			let wire = match reference.to_sys() {
				Ok(wire) => wire,
				Err(error) => return failed(error, shared),
			};
			unsafe {
				ffi::pancake_host_session_send(
					shared.ptr.get(),
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
					"cannot pipeline against a local-send promise; await it for a Ref".to_string(),
				),
				shared,
			)
		}
		CmdTarget::Pipeline(Some(source)) => unsafe {
			ffi::pancake_host_vow_send(
				shared.host.raw(),
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
		return failed(error, shared);
	}
	shared.host.vow_minted(vow);
	// The deliver is queued; the kick (scheduled, so a synchronous batch of
	// pipelined sends travels together) flushes it whether or not the
	// handle is ever awaited.
	shared.host.schedule_kick();
	RemotePromise::far(vow, Rc::clone(shared))
}

/// Where a `send` is addressed. A `Ref` names a capability (a near export or a
/// far token) as usual; a `Pipeline` names the still-pending answer of an
/// earlier far send by its host vow, so the send pipelines at that answer — the
/// wire form of promise pipelining. `None` inside `Pipeline` is a local send's
/// promise, which has no wire answer to pipeline against and is refused.
/// Public only because it appears in the [`AsSendTarget`] trait's plumbing;
/// hidden from docs and not meant to be named by applications.
#[doc(hidden)]
pub enum CmdTarget {
	Ref(Reference),
	Pipeline(Option<u64>),
}

/// What a `send` accepts as its target: a capability [`crate::Ref`], or a
/// [`RemotePromise`] from an earlier send to pipeline against. Borrowed in both
/// cases so an unawaited `RemotePromise` can still be awaited later.
pub trait AsSendTarget {
	#[doc(hidden)]
	fn as_send_target(&self) -> CmdTarget;
}

impl AsSendTarget for &RemotePromise {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget::Pipeline(self.vow())
	}
}

impl AsSendTarget for &Ref {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget::Ref(self.reference().clone())
	}
}

// How one send settles when its handle is awaited: a far vow the drain's
// SETTLE/FAIL arms route, a deferred local turn (run on first observation, so
// a `Forward` to a far target can await the wire reply), or a refusal already
// in hand (surfaced on await, the same path a partner break takes).
pub(crate) enum PromiseState {
	Far(u64),
	Local {
		position: u64,
		verb: String,
		args: Vec<Argument>,
	},
	Failed(Error),
}

/// The handle [`crate::Session::send`] returns: the eventual result of one
/// eventual-send, and — the point of promise pipelining (ADR-0007) — a target
/// you can `send` to before it resolves.
///
/// It is `IntoFuture<Output = Result<Argument>>`, so `conn.send(...).await` yields
/// the reply exactly as a plain future would (a [`crate::Ref`] via `Ref::try_from(&arg)`
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
	pub(crate) state: PromiseState,
	pub(crate) conn: Rc<SessionShared>,
}

impl RemotePromise {
	pub(crate) fn far(vow: u64, conn: Rc<SessionShared>) -> Self {
		Self {
			state: PromiseState::Far(vow),
			conn,
		}
	}

	pub(crate) fn local(
		position: u64,
		verb: String,
		args: Vec<Argument>,
		conn: Rc<SessionShared>,
	) -> Self {
		Self {
			state: PromiseState::Local {
				position,
				verb,
				args,
			},
			conn,
		}
	}

	pub(crate) fn failed(error: Error, conn: Rc<SessionShared>) -> Self {
		Self {
			state: PromiseState::Failed(error),
			conn,
		}
	}

	// The host vow this send's answer settles, or None for a local send (not
	// pipelinable).
	pub(crate) fn vow(&self) -> Option<u64> {
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
			return RemotePromise::failed(
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"cannot project a local-send promise; await it for a value".to_string(),
				),
				Rc::clone(&self.conn),
			);
		};
		let mut vow: u64 = 0;
		let rc = match &op {
			ProjectOp::Index(i) => unsafe {
				ffi::pancake_host_vow_index(self.conn.host.raw(), source, *i as u64, &mut vow)
			},
			ProjectOp::Untag(tag) => unsafe {
				ffi::pancake_host_vow_untag(
					self.conn.host.raw(),
					source,
					tag.as_ptr(),
					tag.len(),
					&mut vow,
				)
			},
		};
		match check_host(rc) {
			Ok(()) => {
				self.conn.host.vow_minted(vow);
				RemotePromise::far(vow, Rc::clone(&self.conn))
			}
			Err(error) => RemotePromise::failed(error, Rc::clone(&self.conn)),
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
					let settled = self.conn.host.await_vow(vow);
					self.conn.host.kick_actions().await;
					settled.await
				}
				PromiseState::Local {
					position,
					verb,
					args,
				} => crate::trampoline::run_local_send(self.conn, position, verb, args).await,
			}
		})
	}
}
