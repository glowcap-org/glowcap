//! The [`RemotePromise`] a [`Session`](crate::Session) send returns: lazy
//! observation, promise pipelining target, and `index`/`untag`/`get`
//! projection (ADR-0003 / ADR-0004). Also the shared fetch/enliven
//! mint→await→classify path (`await_minted` / `fetch_like`) and the far-send
//! mint→`RemotePromise` factory (`send_promise`). Session owns CapTP verb
//! wrappers. This module owns the handle type, post-mint wait/classify,
//! send→promise construction, and the projection FFI.

use std::future::{Future, IntoFuture};
use std::pin::Pin;
use std::rc::Rc;

use crate::host::check_host;
use crate::session_shared::SessionShared;
use crate::sys::host as ffi;
use crate::trampoline::DeliverGuard;
use crate::{Argument, Error, Ref, Result, SendArena, sys};

/// Shared fetch/enliven wait: the mint already registered the vow. Kick the
/// drain so the deliver leaves now, and await the drain-routed outcome.
pub(crate) async fn await_minted(shared: &Rc<SessionShared>, vow: u64, track_gc: bool) -> Result<Argument> {
	let _release = crate::gc::VowGuard::new(&shared.host, vow);
	shared.attend_inbound()?;
	shared.host.vow_minted(vow, track_gc.then_some(shared));
	shared.host.observe_vow(vow).await
}

/// The one mint/await/classify body under `fetch` and `enliven`: mint the
/// host vow with `mint`, await its drain-routed completion, and classify:
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
	// SAFETY: `shared.ptr.get()` is this `SessionShared`'s session handle, still live because `guard_open` above found
	// it unreleased; `mint` is one of the session's `glowcap_host_session_*` mint verbs, `swiss` borrows the caller's
	// slice for the call, and `vow` is a local out-parameter the callee writes.
	check_host(unsafe { mint(shared.ptr.get(), swiss.as_ptr(), swiss.len(), &mut vow) })?;
	let value = await_minted(shared, vow, track).await?;
	match value {
		Argument::Reference(reference) => Ok(reference),
		_ => Err(Error::broken(format!("{label:?} did not resolve to a capability"))),
	}
}

/// `Session::listen`'s wire half: mint the listen vow over a held far reference
/// (CapTP `op:listen`) and hand back the settle handle. The vow is plain: a
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
	// SAFETY: `shared.ptr.get()` is this `SessionShared`'s session handle, still live because `guard_open` above found
	// it unreleased; `wire` is a local `GlowcapReference` from `target.to_sys()` and `vow` a local out-parameter, both
	// borrowed for the call.
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
		// SAFETY: `shared.ptr.get()` is this `SessionShared`'s session handle, still live because `guard_open` above
		// found it unreleased; `wire` is a local `GlowcapReference` from `target.to_sys()`, and `reference` and `vow`
		// are local out-parameters the callee writes.
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
	// The target is checked before any promise argument is minted, so a refused
	// target leaves nothing to give back.
	let addressed = match &target.0 {
		CmdTargetKind::Ref(reference) => match reference.to_sys() {
			Ok(wire) => Addressed::Wire(wire),
			Err(error) => return failed(error, shared),
		},
		CmdTargetKind::Pipeline(promise) => match promise.far_vow(&shared.host) {
			Ok(source) => Addressed::Vow(source),
			Err(error) => return failed(error, shared),
		},
	};
	let mut arena = SendArena::for_host(&shared.host);
	let (args_ptr, args_len) = match arena.build(args) {
		Ok(built) => built,
		Err(error) => return failed(error, shared),
	};
	let mut vow: u64 = 0;
	let _arrival = DeliverGuard::enter(shared);
	let rc = match addressed {
		Addressed::Wire(wire) => {
			// SAFETY: `shared.ptr.get()` is this `SessionShared`'s session handle, still live because `guard_open`
			// above found it unreleased; `wire` is a local `GlowcapReference` from `reference.to_sys()`, `verb` borrows
			// the caller's `&str`, and `args_ptr` and `args_len` come from the local `arena`, which borrows `args` and
			// outlives the call; `vow` is a local out-parameter the callee writes.
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
		Addressed::Vow(source) => {
			// SAFETY: `shared.host.raw()` is the live Host handle of `shared.host`, which `far_vow` showed minted
			// `source`; `verb` borrows the caller's `&str`, and `args_ptr` and `args_len` come from the local `arena`,
			// which borrows `args` and outlives the call; `vow` is a local out-parameter the callee writes.
			unsafe {
				ffi::glowcap_host_vow_send(
					shared.host.raw(),
					source,
					verb.as_ptr(),
					verb.len(),
					args_ptr,
					args_len,
					&mut vow,
				)
			}
		}
	};
	if let Err(error) = arena.finish(check_host(rc)) {
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

/// A send target the Host accepts: a capability's wire identity, or the vow
/// whose answer the send pipelines onto.
enum Addressed {
	Wire(sys::GlowcapReference),
	Vow(u64),
}

/// Fire-and-forget eventual-send to a concrete capability or an unresolved
/// answer. The Host routes concrete capabilities and vow identities.
pub(crate) fn tell_target(shared: &Rc<SessionShared>, target: CmdTarget, verb: &str, args: &[Argument]) -> Result<()> {
	let _arrival = DeliverGuard::enter(shared);
	match &target.0 {
		CmdTargetKind::Ref(reference) => shared.tell(reference, verb, args),
		CmdTargetKind::Pipeline(promise) => {
			let source = promise.far_vow(&shared.host)?;
			shared.guard_open()?;
			shared.attend_inbound()?;
			shared.drain_gc()?;
			let mut arena = SendArena::for_host(&shared.host);
			let (args_ptr, args_len) = arena.build(args)?;
			// SAFETY: `shared.host.raw()` is the live Host handle of `shared.host`, which `far_vow` showed minted
			// `source`; `verb` borrows the caller's `&str`, and `args_ptr` and `args_len` come from the
			// local `arena`, which borrows `args` and outlives the call.
			arena.finish(check_host(unsafe {
				ffi::glowcap_host_vow_tell(shared.host.raw(), source, verb.as_ptr(), verb.len(), args_ptr, args_len)
			}))?;
			shared.host.schedule_kick()
		}
	}
}

/// Where a `send` is addressed. A `Ref` names a capability (a near export or a
/// far token) as usual. A `Pipeline` names the answer of a send this side
/// made, by the same [`PromiseArgument`] a promise passes as.
/// Public only because it appears in the [`AsSendTarget`] trait's plumbing.
/// Hidden from docs and not meant to be named by applications.
#[doc(hidden)]
pub struct CmdTarget(CmdTargetKind);

enum CmdTargetKind {
	Ref(Ref),
	Pipeline(PromiseArgument),
}

impl CmdTarget {
	pub(crate) fn reference(reference: Ref) -> Self {
		Self(CmdTargetKind::Ref(reference))
	}
}

/// What `send` and `tell` accept as a target: a capability [`crate::Ref`], or a
/// [`RemotePromise`] from an earlier send to pipeline against. Borrowed in both status-allow: event or source ordering
/// cases so an unawaited `RemotePromise` can still be awaited later.
pub trait AsSendTarget {
	#[doc(hidden)]
	fn as_send_target(&self) -> CmdTarget;
}

impl AsSendTarget for &RemotePromise {
	fn as_send_target(&self) -> CmdTarget {
		CmdTarget(CmdTargetKind::Pipeline(PromiseArgument::from(*self)))
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
/// eventual-send, and (the point of promise pipelining, ADR-0003) a target
/// you can `send` to before it resolves.
///
/// It is `IntoFuture<Output = Result<Argument>>`, so `session.send(...).await` yields
/// the reply exactly as a plain future would (a [`crate::Ref`] via `Ref::try_from(&arg)`
/// if the partner returned a capability. A typed `Err` on a break). Pass it
/// *unawaited*, by reference, as the `target` of a later `send` to address the
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
/// A handle awaited for its value resolves once. A handle only used as a target
/// (never awaited) is a dependency anchor whose own reply is dropped: the
/// settle is drain-routed and stored, so an unawaited anchor whose far answer
/// breaks never faults anything.
/// A pipeline target belongs to the Host that minted it. Another Host refuses
/// it before interpreting the Host-local vow number.
///
/// The projection verbs [`index`](RemotePromise::index) /
/// [`untag`](RemotePromise::untag) / [`get`](RemotePromise::get)
/// (ADR-0004) pipeline an element, untag, or Struct-field access *at
/// the answer*, before it resolves: each returns a new `RemotePromise` for the
/// projected value, so `task.untag("cell").index(0)` or `task.get("name")`
/// costs no extra round trip.
pub struct RemotePromise {
	pub(crate) state: PromiseState,
	pub(crate) session: Rc<SessionShared>,
	release: Option<crate::gc::VowGuard>,
}

/// A [`RemotePromise`] addressed by its Host answer: the
/// [`Argument::Promise`] payload `Argument::from(&promise)` builds, and the
/// address a pipelined send targets. A send through it reaches the answer,
/// pending or settled. A promise whose send never left carries that first failure forward, an
/// await-only promise has no answer to address, and a promise another Host
/// returned is refused, each at the send with `InvalidArgument` before any
/// frame moves. Equality is the same answer of the same Host.
/// This identity does not own the answer. Keep the original handle alive until
/// sending, or use [`RemotePromise::retain`] to own a capability across suspension.
/// Cloning a `PromiseArgument` does not extend the answer's lifetime.
#[derive(Clone)]
pub struct PromiseArgument {
	vow: Result<u64>,
	host: Rc<crate::host::HostShared>,
}

impl PromiseArgument {
	/// Mint one owned capability occurrence through the existing Host vow owner.
	pub(crate) fn mint(&self, host: &Rc<crate::host::HostShared>) -> Result<sys::GlowcapReference> {
		let vow = self.far_vow(host)?;
		let mut reference = sys::GlowcapReference { id: 0 };
		// SAFETY: far_vow checked that this live Host owns the vow. The callee writes
		// one owned occurrence to the local out-parameter.
		check_host(unsafe { ffi::glowcap_host_vow_capability(host.raw(), vow, &mut reference) })?;
		Ok(reference)
	}

	/// The far vow a send through `host` addresses, or the refusal the send
	/// reports.
	pub(crate) fn far_vow(&self, host: &Rc<crate::host::HostShared>) -> Result<u64> {
		let vow = self.vow.clone()?;
		if !Rc::ptr_eq(&self.host, host) {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"this promise belongs to another Host".to_string(),
			));
		}
		Ok(vow)
	}
}

impl PartialEq for PromiseArgument {
	fn eq(&self, other: &Self) -> bool {
		self.vow == other.vow && Rc::ptr_eq(&self.host, &other.host)
	}
}

impl std::fmt::Debug for PromiseArgument {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.debug_struct("PromiseArgument")
			.field("vow", &self.vow)
			.finish_non_exhaustive()
	}
}

impl From<&RemotePromise> for PromiseArgument {
	fn from(promise: &RemotePromise) -> PromiseArgument {
		PromiseArgument {
			vow: match &promise.state {
				PromiseState::Call(vow) => Ok(*vow),
				PromiseState::Observer(_) => Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"this promise is await-only and has no pipeline target".to_string(),
				)),
				PromiseState::Failed(error) => Err(error.clone()),
			},
			host: Rc::clone(&promise.session.host),
		}
	}
}

impl From<&RemotePromise> for Argument {
	fn from(promise: &RemotePromise) -> Argument {
		Argument::Promise(PromiseArgument::from(promise))
	}
}

impl RemotePromise {
	/// Retain this answer as a capability independently of this call handle.
	/// The returned reference can be held across suspension, passed, or listened
	/// to after this handle is dropped or awaited. Its final drop releases the
	/// owned occurrence. Refused calls and await-only observers cannot be retained.
	pub fn retain(&self) -> Result<Ref> {
		let raw = PromiseArgument::from(self).mint(&self.session.host)?;
		let mut reference = Ref::from_sys(&raw);
		reference.attach_guard(crate::gc::owned_guard(&self.session.host, raw.id));
		Ok(reference)
	}

	// The addressable answer, or None for observer vows and refused calls.
	#[cfg(all(test, feature = "tcp"))]
	pub(crate) fn vow(&self) -> Option<u64> {
		match self.state {
			PromiseState::Call(vow) => Some(vow),
			_ => None,
		}
	}

	/// Return an eagerly refused operation before publishing dependent state.
	/// Success means admission succeeded. The remote outcome still requires
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

	// Issue a projection at this promise's answer and return a new pipelinable
	// promise for the projected value. By `&self`, so a handle can be projected
	// *and* still awaited later for its own value (the late-source-await case).
	fn project(&self, op: ProjectOp<'_>) -> RemotePromise {
		let source = match &self.state {
			PromiseState::Call(source) => *source,
			// Preserve the first refusal. Reclassifying it as an await-only promise
			// hides the operation that failed and sends callers debugging
			// the projection instead of the rejected send.
			PromiseState::Failed(error) => return RemotePromise::failed(error.clone(), Rc::clone(&self.session)),
			PromiseState::Observer(_) => {
				return RemotePromise::failed(
					Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						"this promise is await-only and cannot be projected".to_string(),
					),
					Rc::clone(&self.session),
				);
			}
		};
		let mut vow: u64 = 0;
		let _arrival = DeliverGuard::enter(&self.session);
		let rc = match &op {
			// SAFETY: `self.session.host.raw()` is the Host handle of the session this promise was minted on, and
			// `source` is the vow it holds in `PromiseState::Call`; `vow` is a local out-parameter the callee writes.
			ProjectOp::Index(i) => unsafe {
				ffi::glowcap_host_vow_index(self.session.host.raw(), source, *i as u64, &mut vow)
			},
			// SAFETY: as the `ProjectOp::Index` arm above for the handle and `source`; `tag` borrows the caller's
			// `&str` for the call, and `vow` is a local out-parameter the callee writes.
			ProjectOp::Untag(tag) => unsafe {
				ffi::glowcap_host_vow_untag(self.session.host.raw(), source, tag.as_ptr(), tag.len(), &mut vow)
			},
			// SAFETY: as the `ProjectOp::Index` arm above for the handle and `source`; `field` borrows the caller's
			// `&str` for the call, and `vow` is a local out-parameter the callee writes.
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

	/// Pipeline an `op:index` for `i` at this answer (ADR-0004): a new
	/// [`RemotePromise`] for the List element of whatever this resolves to.
	pub fn index(&self, i: i64) -> RemotePromise {
		self.project(ProjectOp::Index(i))
	}

	/// Pipeline an `op:untag` for `tag` at this answer (ADR-0004): a new
	/// [`RemotePromise`] for the payload of whatever this resolves to, which must
	/// be a Tagged record whose tag equals `tag`.
	pub fn untag(&self, tag: &str) -> RemotePromise {
		self.project(ProjectOp::Untag(tag))
	}

	/// Pipeline an `op:get` for `field` at this answer (ADR-0004): a new
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
					// synchronously (the row already exists: the mint was the
					// registration), then the kick puts the queued batch on the
					// wire and routes any already-arrived outcome.
					self.session.host.observe_vow(vow).await
				}
			}
		})
	}
}
