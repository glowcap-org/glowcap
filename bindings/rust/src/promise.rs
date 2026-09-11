//! The [`RemotePromise`] a [`Session`](crate::Session) send returns: lazy
//! observation, promise pipelining target, and `index`/`untag`/`get`
//! projection (ADR-0007 / ADR-0050 / ADR-0052). Also the shared fetch/enliven
//! mint→await→classify path (`await_minted` / `fetch_like`) and the far-send
//! mint→`RemotePromise` factory (`send_promise`). Session owns CapTP verb
//! wrappers; this module owns the handle type, post-mint wait/classify,
//! send→promise construction, and the projection FFI.

use std::future::{Future, IntoFuture};
use std::pin::Pin;
use std::rc::Rc;

use crate::host::check_host;
use crate::session_shared::SessionShared;
use crate::sys::host as ffi;
use crate::trampoline::DeliverGuard;
use crate::{sys, Argument, Error, Ref, Result, SendArena};

/// Shared fetch/enliven wait: the mint already registered the vow; kick the
/// drain so the deliver leaves now, and await the drain-routed outcome.
pub(crate) async fn await_minted(shared: &Rc<SessionShared>, vow: u64, track_gc: bool) -> Result<Argument> {
	let _release = crate::gc::VowGuard::new(&shared.host, vow);
	shared.attend_inbound()?;
	shared.host.vow_minted(vow, track_gc.then_some(shared));
	let settled = shared.host.await_vow(vow);
	shared.host.kick_actions().await?;
	settled.await
}

/// The one mint/await/classify body under `fetch` and `enliven`: mint the
/// host vow with `mint`, await its drain-routed completion, and classify —
/// only an opaque Host reference is a capability this surface can hand out.
/// `track` enrolls the fulfilled application value in distributed GC.
pub(crate) async fn fetch_like(
	shared: &Rc<SessionShared>,
	swiss: &[u8],
	label: &str,
	mint: unsafe extern "C" fn(*mut ffi::GlowcapHostSession, *const u8, usize, *mut u64) -> i32,
	track: bool,
) -> Result<Ref> {
	shared.guard_open()?;
	shared.drain_gc()?;
	let mut vow: u64 = 0;
	check_host(unsafe { mint(shared.ptr.get(), swiss.as_ptr(), swiss.len(), &mut vow) })?;
	let value = await_minted(shared, vow, track).await?;
	match value {
		Argument::Reference(reference) => Ok(reference),
		_ => Err(Error::broken(format!("{label:?} did not resolve to a capability"))),
	}
}

/// `Session::listen`'s wire half: mint the listen vow over a held far reference
/// (CapTP `op:listen`) and hand back the settle handle. The vow is plain — a
/// listen may settle to any value, not only a capability.
pub(crate) fn listen_far(shared: &Rc<SessionShared>, target: &crate::Ref) -> RemotePromise {
	let failed = |error: Error, session: &Rc<SessionShared>| RemotePromise::failed(error, Rc::clone(session));
	if let Err(error) = shared.guard_open() {
		return failed(error, shared);
	}
	if let Err(error) = shared.attend_inbound() {
		return failed(error, shared);
	}
	if let Err(error) = shared.drain_gc() {
		return failed(error, shared);
	}
	let wire = match target.to_sys() {
		Ok(wire) => wire,
		Err(error) => return failed(error, shared),
	};
	let mut vow: u64 = 0;
	let _arrival = DeliverGuard::enter(shared);
	let rc = unsafe { ffi::glowcap_host_session_listen(shared.ptr.get(), &wire, &mut vow) };
	if let Err(error) = check_host(rc) {
		return failed(error, shared);
	}
	shared.host.vow_minted(vow, Some(shared));
	if let Err(error) = shared.host.schedule_kick() {
		shared.host.settle_vow(vow, Err(error));
	}
	RemotePromise::observer(vow, Rc::clone(shared))
}

/// Adapt the Host's immediate-owned / pending-vow resolution result without
/// exposing capability representation to the binding or its callers.
pub(crate) async fn resolve(shared: &Rc<SessionShared>, target: &Ref) -> Result<Argument> {
	shared.guard_open()?;
	shared.attend_inbound()?;
	shared.drain_gc()?;
	let wire = target.to_sys()?;
	let mut reference = sys::GlowcapReference { id: 0 };
	let mut vow = 0;
	{
		let _arrival = DeliverGuard::enter(shared);
		check_host(unsafe { ffi::glowcap_host_session_resolve(shared.ptr.get(), &wire, &mut reference, &mut vow) })?;
	}
	if vow != 0 {
		return await_minted(shared, vow, true).await;
	}
	let mut value = Argument::Reference(Ref::from_sys(&reference));
	crate::gc::track_owned_argument(&shared.host, &mut value);
	Ok(value)
}

pub(crate) fn send_promise(
	shared: &Rc<SessionShared>,
	target: CmdTarget,
	verb: &str,
	args: &[Argument],
) -> RemotePromise {
	let failed = |error: Error, session: &Rc<SessionShared>| RemotePromise::failed(error, Rc::clone(session));
	if let Err(error) = shared.guard_open() {
		return failed(error, shared);
	}
	if let Err(error) = shared.attend_inbound() {
		return failed(error, shared);
	}
	if let Err(error) = shared.drain_gc() {
		return failed(error, shared);
	}
	let mut arena = SendArena::default();
	let (args_ptr, args_len) = match arena.build(args) {
		Ok(built) => built,
		Err(error) => return failed(error, shared),
	};
	let mut vow: u64 = 0;
	let _arrival = DeliverGuard::enter(shared);
	let rc = match &target.0 {
		CmdTargetKind::Ref(reference) => {
			let wire = match reference.to_sys() {
				Ok(wire) => wire,
				Err(error) => return failed(error, shared),
			};
			unsafe {
				ffi::glowcap_host_session_send(
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
		// Promise pipelining: the Host admits addressable remote answers.
		CmdTargetKind::Pipeline { vow: None, .. } => {
			return failed(
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"this promise is await-only or refused and has no pipeline target".to_string(),
				),
				shared,
			)
		}
		CmdTargetKind::Pipeline {
			vow: Some(source),
			host,
		} => {
			if !Rc::ptr_eq(host, &shared.host) {
				return failed(
					Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						"this promise belongs to another Host".to_string(),
					),
					shared,
				);
			}
			unsafe {
				ffi::glowcap_host_vow_send(
					shared.host.raw(),
					*source,
					verb.as_ptr(),
					verb.len(),
					args_ptr,
					args_len,
					&mut vow,
				)
			}
		}
	};
	if let Err(error) = check_host(rc) {
		return failed(error, shared);
	}
	shared.host.vow_minted(vow, Some(shared));
	// The deliver is queued; the kick (scheduled, so a synchronous batch of
	// pipelined sends travels together) flushes it whether or not the
	// handle is ever awaited.
	if let Err(error) = shared.host.schedule_kick() {
		shared.host.settle_vow(vow, Err(error));
	}
	RemotePromise::admitted(vow, Rc::clone(shared))
}

/// Fire-and-forget eventual-send to a concrete capability or an unresolved
/// answer. The Host routes concrete capabilities and vow identities.
pub(crate) fn tell_target(shared: &Rc<SessionShared>, target: CmdTarget, verb: &str, args: &[Argument]) -> Result<()> {
	let _arrival = DeliverGuard::enter(shared);
	match &target.0 {
		CmdTargetKind::Ref(reference) => return shared.tell(reference, verb, args),
		CmdTargetKind::Pipeline { vow: None, .. } => {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"this promise is await-only or refused and has no pipeline target".to_string(),
			))
		}
		CmdTargetKind::Pipeline {
			vow: Some(source),
			host,
		} => {
			shared.guard_open()?;
			shared.attend_inbound()?;
			shared.drain_gc()?;
			if !Rc::ptr_eq(host, &shared.host) {
				return Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"this promise belongs to another Host".to_string(),
				));
			}
			let mut arena = SendArena::default();
			let (args_ptr, args_len) = arena.build(args)?;
			check_host(unsafe {
				ffi::glowcap_host_vow_tell(
					shared.host.raw(),
					*source,
					verb.as_ptr(),
					verb.len(),
					args_ptr,
					args_len,
				)
			})?;
			shared.host.schedule_kick()
		}
	}
}

/// Where a `send` is addressed. A `Ref` names a capability (a near export or a
/// far token) as usual; a `Pipeline` names the still-pending answer of an
/// earlier send by its Host vow. `None` denotes an await-only observer or a
/// refused operation; neither has a pipeline target.
/// Public only because it appears in the [`AsSendTarget`] trait's plumbing;
/// hidden from docs and not meant to be named by applications.
#[doc(hidden)]
pub struct CmdTarget(CmdTargetKind);

enum CmdTargetKind {
	Ref(Ref),
	Pipeline {
		vow: Option<u64>,
		host: Rc<crate::host::HostShared>,
	},
}

impl CmdTarget {
	pub(crate) fn reference(reference: Ref) -> Self {
		Self(CmdTargetKind::Ref(reference))
	}
}

/// What `send` and `tell` accept as a target: a capability [`crate::Ref`], or a
/// [`RemotePromise`] from an earlier send to pipeline against. Borrowed in both
/// cases so an unawaited `RemotePromise` can still be awaited later.
pub trait AsSendTarget {
	#[doc(hidden)]
	fn as_send_target(&self) -> CmdTarget;
}

impl AsSendTarget for &RemotePromise {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget(CmdTargetKind::Pipeline {
			vow: self.vow(),
			host: Rc::clone(&self.session.host),
		})
	}
}

impl AsSendTarget for &Ref {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget::reference((*self).clone())
	}
}

// How one operation settles when its handle is awaited: an admitted
// call, an await-only listen observer, or a refusal
// already in hand.
pub(crate) enum PromiseState {
	Call(u64),
	Observer(u64),
	Failed(Error),
}

/// The handle [`crate::Session::send`] returns: the eventual result of one
/// eventual-send, and — the point of promise pipelining (ADR-0007) — a target
/// you can `send` to before it resolves.
///
/// It is `IntoFuture<Output = Result<Argument>>`, so `session.send(...).await` yields
/// the reply exactly as a plain future would (a [`crate::Ref`] via `Ref::try_from(&arg)`
/// if the partner returned a capability; a typed `Err` on a break). Pass it
/// *unawaited* — by reference — as the `target` of a later `send` to address the
/// object the answer will resolve to: the dependent call rides a `desc:answer`
/// deliver the partner queues until the answer settles, so a `create -> use`
/// chain costs one round trip instead of one per link:
///
/// ```ignore
/// let task = session.send(&root, "create", &["x".into()]);   // not awaited
/// session.send(&task, "assign", &["alice".into()]);           // pipelined at the answer
/// let status = session.send(&task, "status", &[]).await?;     // settles the chain
/// ```
///
/// A handle awaited for its value resolves once; a handle only used as a target
/// (never awaited) is a dependency anchor whose own reply is dropped — the
/// settle is drain-routed and stored, so an unawaited anchor whose far answer
/// breaks never faults anything.
/// A pipeline target belongs to the Host that minted it; another Host refuses
/// it before interpreting the Host-local vow number.
///
/// The projection verbs [`index`](RemotePromise::index) /
/// [`untag`](RemotePromise::untag) / [`get`](RemotePromise::get)
/// (ADR-0050/ADR-0052) pipeline an element, untag, or Struct-field access *at
/// the answer*, before it resolves: each returns a new `RemotePromise` for the
/// projected value, so `task.untag("cell").index(0)` or `task.get("name")`
/// costs no extra round trip.
pub struct RemotePromise {
	pub(crate) state: PromiseState,
	pub(crate) session: Rc<SessionShared>,
	release: Option<crate::gc::VowGuard>,
}

impl RemotePromise {
	/// Return an eagerly refused operation before publishing dependent state.
	/// Success means admission succeeded; the remote outcome still requires
	/// awaiting this promise. This consumes the same operation without polling,
	/// sending again, or running the event loop inside the caller's transaction.
	pub fn into_admitted(self) -> Result<Self> {
		if let PromiseState::Failed(error) = self.state {
			Err(error)
		} else {
			Ok(self)
		}
	}

	pub(crate) fn admitted(vow: u64, session: Rc<SessionShared>) -> Self {
		Self {
			state: PromiseState::Call(vow),
			release: Some(crate::gc::VowGuard::new(&session.host, vow)),
			session,
		}
	}

	pub(crate) fn observer(vow: u64, session: Rc<SessionShared>) -> Self {
		Self {
			state: PromiseState::Observer(vow),
			release: Some(crate::gc::VowGuard::new(&session.host, vow)),
			session,
		}
	}

	pub(crate) fn failed(error: Error, session: Rc<SessionShared>) -> Self {
		Self {
			state: PromiseState::Failed(error),
			release: None,
			session,
		}
	}

	// The addressable answer, or None for observer vows and refused calls.
	pub(crate) fn vow(&self) -> Option<u64> {
		match self.state {
			PromiseState::Call(vow) => Some(vow),
			_ => None,
		}
	}

	// Issue a projection at this promise's answer and return a new pipelinable
	// promise for the projected value. By `&self`, so a handle can be projected
	// *and* still awaited later for its own value (the late-source-await case).
	fn project(&self, op: ProjectOp<'_>) -> RemotePromise {
		let source = match &self.state {
			PromiseState::Call(source) => *source,
			// Preserve the first refusal. Reclassifying it as an await-only promise
			// hides the operation that actually failed and sends callers debugging
			// the projection instead of the rejected send.
			PromiseState::Failed(error) => return RemotePromise::failed(error.clone(), Rc::clone(&self.session)),
			PromiseState::Observer(_) => {
				return RemotePromise::failed(
					Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						"this promise is await-only and cannot be projected".to_string(),
					),
					Rc::clone(&self.session),
				)
			}
		};
		let mut vow: u64 = 0;
		let _arrival = DeliverGuard::enter(&self.session);
		let rc = match &op {
			ProjectOp::Index(i) => unsafe {
				ffi::glowcap_host_vow_index(self.session.host.raw(), source, *i as u64, &mut vow)
			},
			ProjectOp::Untag(tag) => unsafe {
				ffi::glowcap_host_vow_untag(self.session.host.raw(), source, tag.as_ptr(), tag.len(), &mut vow)
			},
			ProjectOp::Get(field) => unsafe {
				ffi::glowcap_host_vow_get(self.session.host.raw(), source, field.as_ptr(), field.len(), &mut vow)
			},
		};
		match check_host(rc) {
			Ok(()) => {
				self.session.host.vow_minted(vow, Some(&self.session));
				if let Err(error) = self.session.host.schedule_kick() {
					self.session.host.settle_vow(vow, Err(error));
				}
				RemotePromise::admitted(vow, Rc::clone(&self.session))
			}
			Err(error) => RemotePromise::failed(error, Rc::clone(&self.session)),
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
		self.project(ProjectOp::Untag(tag))
	}

	/// Pipeline an `op:get` for `field` at this answer (ADR-0050): a new
	/// [`RemotePromise`] for the Struct field of whatever this resolves to.
	pub fn get(&self, field: &str) -> RemotePromise {
		self.project(ProjectOp::Get(field))
	}
}

// Which projection a `RemotePromise` issues against its answer.
enum ProjectOp<'a> {
	Index(i64),
	Untag(&'a str),
	Get(&'a str),
}

impl IntoFuture for RemotePromise {
	type Output = Result<Argument>;
	type IntoFuture = Pin<Box<dyn Future<Output = Result<Argument>>>>;

	fn into_future(self) -> Self::IntoFuture {
		Box::pin(async move {
			let _release = self.release;
			match self.state {
				PromiseState::Failed(error) => Err(error),
				PromiseState::Call(vow) | PromiseState::Observer(vow) => {
					self.session.attend_inbound()?;
					// Await the drain-routed completion. The waiter registers
					// synchronously (the row already exists — the mint was the
					// registration), then the kick puts the queued batch on the
					// wire and routes any already-arrived outcome.
					let settled = self.session.host.await_vow(vow);
					self.session.host.kick_actions().await?;
					settled.await
				}
			}
		})
	}
}
