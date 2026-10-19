//! The application surface over the byte-fed host (`libglowcap_host`,
//! ADR-0022): [`Session`] and its verbs (`fetch`/`send`/`tell`/`spawn`/
//! `publish`/`enliven`/`serve`/`close`), plus mint/handshake (`establish_*`).
//! The managed dial executor (provider selection + channel open + [`Runtime::connect`]) lives in
//! [`crate::dial`]. [`Server`] / [`listen`] live in [`crate::listen`]. The
//! [`RemotePromise`] handle lives in [`crate::promise`]. CapTP action
//! decode+execute lives in [`crate::action`].
//! Per-session [`Caretaker`] / [`SessionShared`] live in [`crate::session_shared`].
//! The Host-scoped [`Ref`] lives beside [`Argument`](crate::Argument).
//! The byte-fed pump choreography, read packets, `glowcap_host_session_feed_packet`,
//! drain the action queue, write what `take_packet` drains, feed-refusal /
//! `last_abort`, EOF / `break_far_vows`, lives in [`crate::pump`]. This module
//! keeps CapTP verbs and thin wrappers into that path. A loop-backed session
//! (ADR-0024) carries the same verbs with no pump at all: the driver loop owns
//! its wire ([`crate::driver_loop`]). The host owns everything
//! else: routing, redemption, gift origination, far vows.
//!
//! Everything runs on one tokio current-thread `LocalSet`. The handles are
//! `!Send` by construction, so create and use them on one task inside it.

use std::rc::Rc;
use std::time::Duration;

use crate::Ref;
use crate::host::{Host, check_host};
use crate::session_shared::{Caretaker, SessionShared};
use crate::sys::host as ffi;
use crate::trampoline::outcome_behavior;
use crate::uri::OwnedLocator;
use crate::{Argument, Error, Locator, Result, sys};

use crate::promise::{AsSendTarget, RemotePromise};

mod close;
mod establish;
pub use establish::{AcceptedTransport, ChannelDesignator};
mod identity;
mod profile;

pub(crate) use close::session_close_result;
pub use identity::{DurableProvenance, PartnerIdentity};

/// How long a partner has to finish the keyed handshake once the byte channel
/// is open, on both halves: what [`Runtime::connect`](crate::Runtime::connect) allows a dialed
/// partner, and what a listener allows an accepted one.
///
/// Matches the CLI's own product default. Something finite is the point: this
/// project's rule for CapTP waits is that an unbounded one is a hang rather
/// than a slow success, and neither half of a connection is exempt. It bounds
/// the handshake alone, never opening the channel: a TCP connect keeps the
/// OS's own timeout, and an iroh dial-by-id keeps its discovery retry budget
/// (ADR-0030), both of which finish before the handshake starts.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u64);

/// A live CapTP session with one OCapN partner: the one object an application
/// holds, over one byte-fed `GlowcapHostSession` the shared [`Host`] minted.
/// `!Send` by construction. Use it on a single task inside a `LocalSet`.
/// A dial or accept returns an owning handle whose drop closes the session.
/// Host-retained views, such as `send_redeeming`'s `via`, do not close on drop.
/// Explicit [`close`](Session::close) still closes the session they name.
pub struct Session {
	shared: Rc<SessionShared>,
	// Application owners control retirement; Host pumps and callback views do
	// not add an owner merely to observe or drive that lifetime.
	owns_session: bool,
}

/// What [`Session::send_redeeming`] settles with: the partner's reply, and the
/// direct exporter session that reply routes to.
impl Session {
	/// Binding-internal: the raw handles the trace veneer names a
	/// session by (`annotate_session`). Null session pointer after
	/// close: the veneer treats that as nothing to annotate.
	pub(crate) fn trace_handles(&self) -> (*mut ffi::GlowcapHost, *mut ffi::GlowcapHostSession) {
		(self.shared.host.raw(), self.shared.ptr.get())
	}
}

pub struct SendRedeemingResult {
	/// The value the send settled with, what an ordinary
	/// [`Session::send`] would have yielded. Lift a capability out of it with
	/// `Ref::try_from(&reply)`.
	pub reply: Argument,
	/// The direct session the reply's capability lives in, when the reply is
	/// a capability a three-party-handoff redeem brought in. `None` for an
	/// ordinary far reply, or when that exporter session has already gone.
	///
	/// The Host retains this view and the reply capability independently of the
	/// returned Rust value, so dropping `via` does not close the exporter.
	/// Calling [`close`](Session::close) closes that exporter explicitly. It
	/// reaches neither the session you sent on nor another exporter session.
	pub via: Option<Session>,
}

impl Session {
	// The owning handle over a session this side dialed or accepted: dropping
	// it closes the connection.
	pub(crate) fn owning(shared: Rc<SessionShared>) -> Session {
		shared.owner_handles.set(shared.owner_handles.get() + 1);
		Session {
			shared,
			owns_session: true,
		}
	}

	// A view onto a session the host owns, for a caller that needs to spawn and
	// send on it without taking its life in hand.
	pub(crate) fn view(shared: Rc<SessionShared>) -> Session {
		Session {
			shared,
			owns_session: false,
		}
	}

	/// Transfer an admitted dial to Host custody without closing it. Its pump
	/// observes lifetime. Application handles acquired through reference_session
	/// own it. With no application handle yet, Host shutdown remains the owner.
	pub(crate) fn into_host_retained(mut self) -> Self {
		if self.owns_session {
			self.shared.owner_handles.set(self.shared.owner_handles.get() - 1);
			self.owns_session = false;
		}
		self.shared.retain_by_host();
		self
	}

	/// The session's shared [`Host`], its retained identity and handoff router.
	/// Shared by every session of one Host, so the gifter half of a handoff
	/// can reach a sibling session's session keys. An application reads it to
	/// publish Host-publications ([`Host::publish`]), share one identity
	/// across dials, or set the redeem posture.
	pub fn host(&self) -> Host {
		Host::from_shared(Rc::clone(&self.shared.host))
	}

	/// Record the complete exporter locator the gifter embeds when *this*
	/// session is the exporter side of a handoff
	/// this host originates (ADR-0039). Needed when the partner's signed location
	/// is not dialable on its own: an iroh partner signs only its node id, so a
	/// gifter that learned the exporter's `direct-addresses` out of band sets the
	/// full locator here. Unset, origination falls back to the partner's signed
	/// location.
	///
	/// Fallible because silent failure defeats the call: on failure origination
	/// reverts to the partner's signed location, and the recipient's redeem dial
	/// fails later, in another process, with an unrelated message.
	/// The other three bindings raise here.
	pub fn set_exporter_locator(&self, locator: Option<&Locator>) -> Result<()> {
		self.shared.guard_open()?;
		let owned = locator.map(OwnedLocator::new).transpose()?;
		let view = match owned.as_ref() {
			Some(value) => value.borrow_view()?,
			None => core::ptr::null(),
		};
		// SAFETY: `self.shared.ptr` is this session's `GlowcapHostSession` handle, owned by the Host and nulled only
		// when the session is released, and `guard_open` above proved it live; `view` is null, which the header defines
		// as clearing the override, or points into `owned`, a local `OwnedLocator` that outlives the call, and the Host
		// clones the borrowed view.
		check_host(unsafe { ffi::glowcap_host_session_set_exporter_location(self.shared.ptr.get(), view) })?;
		Ok(())
	}

	/// A [`Ref`] for the object published under `name` on this session, or `None`
	/// when nothing is published there.
	///
	/// [`Session::publish`] returns its own `Ref`, so this is for the other
	/// publisher: [`Host::publish`](crate::Host::publish) hosts
	/// one actor under a Host-wide alias and returns nothing. This lazily projects
	/// the actor onto the session and returns its Host identity. No enrollment
	/// step exists.
	///
	/// Calls to the returned reference use the FFI Host's local eventual
	/// dispatch with this session as their causal owner.
	pub fn published_ref(&self, name: &str) -> Result<Option<Ref>> {
		self.shared.guard_open()?;
		let mut reference = sys::GlowcapReference { id: 0 };
		// SAFETY: `self.shared.ptr` is this session's live `GlowcapHostSession` handle (`guard_open` above); `name` is
		// a `&str` borrowed for the call, and `reference` is a local out-parameter the callee fills.
		let rc = unsafe {
			ffi::glowcap_host_session_published_ref(self.shared.ptr.get(), name.as_ptr(), name.len(), &mut reference)
		};
		if rc == sys::ERR_NOT_FOUND {
			return Ok(None);
		}
		check_host(rc)?;
		Ok(Some(Ref::bare_id(reference.id)))
	}

	/// Give a capability back to the partner, now, because this application is
	/// done holding it.
	///
	/// Releases one application retain. For a remote capability the Host emits
	/// any required `op:gc-exports`. A local capability needs no wire message.
	/// Dropping the last clone does this for every far capability a Host
	/// projects while [`Host::set_release_on_drop`](crate::Host::set_release_on_drop)
	/// is on (the default). This verb also works for a handle outside that
	/// automatic seam.
	///
	/// `cap` is taken by value, so the handle you released is gone. A clone
	/// made earlier reads [`Ref::released`] as true and is a caller error to
	/// use. Another occurrence may keep the same Host identity live, so the
	/// binding refuses the spent occurrence before local dispatch or ABI use.
	///
	/// A capability from another Host, or one already released, is an error.
	pub fn release(&self, cap: Ref) -> Result<()> {
		self.shared.guard_open()?;
		if cap.released() {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"capability already released".to_string(),
			));
		}
		crate::gc::release_ref(self.shared.host.raw(), cap.id())?;
		crate::gc::disarm(&cap);
		cap.mark_released();
		Ok(())
	}

	/// Spawn a local actor and return a capability to it. Pass the returned `Ref`
	/// as a `send` argument to hand a partner a callback. The returned identity
	/// is opaque and Host-scoped. Wire export positions stay inside glowcap.
	/// Callable from inside a served turn (a factory's `create` minting the task
	/// it replies with).
	pub fn spawn(
		&self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		self.shared.spawn_actor(outcome_behavior(behavior))
	}

	/// Spawn an actor whose local root is owned by the returned reference.
	/// The last clone's Drop parks its release on the Host, including when Drop
	/// runs inside a callback. Remote exports retain their own actor roots.
	/// Unlike `spawn`, this does not require a later explicit `release`. It is
	/// independent of the session's distributed-GC opt-in.
	pub fn spawn_owned(
		&self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		let mut reference = self.spawn(behavior)?;
		reference.attach_guard(crate::gc::owned_guard(&self.shared.host, reference.id()));
		Ok(reference)
	}

	/// Publish an actor so a partner can [`fetch`](Session::fetch) it by `name`
	/// (a swiss-number). Returns a capability to it.
	pub fn publish(
		&self,
		name: &str,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		self.shared.publish_actor(name, outcome_behavior(behavior))
	}

	/// Wrap `target` (local or far) in a revocable caretaker (ADR-0016). Returns a
	/// [`Caretaker`] whose `proxy` is an ordinary capability you hand a partner.
	/// Every call through it forwards to `target` until you
	/// [`revoke`](Caretaker::revoke) it, after which each call breaks with
	/// `Revoked`. `target` may be a capability you imported over the wire, the
	/// proxy forwards transparently, so this hands out a revocable view of
	/// authority you do not own locally.
	pub fn caretaker(&self, target: &Ref) -> Result<Caretaker> {
		crate::trampoline::caretaker_proxy(&self.shared, target)
	}

	/// Wrap `target` (local or far) in an attenuator (ADR-0016): a proxy that
	/// forwards only the calls whose verb is in `verbs` and breaks every other
	/// with `Attenuated`. Returns the proxy capability to hand a partner. `target`
	/// may be a wire-imported capability, so this narrows authority you hold.
	pub fn attenuate(&self, target: &Ref, verbs: &[&str]) -> Result<Ref> {
		crate::trampoline::attenuate_proxy(&self.shared, target, verbs)
	}

	/// Fetch a partner's published capability by `name`. Returns a `Ref` you can
	/// `send` to. The canonical fetch lives in the library: one call registers
	/// the bootstrap import, allocates the answer, and queues the deliver. The
	/// host enrolls the fulfilled capability under a node-unique token (ADR-0026)
	/// before the completion is queued, so a return re-gifts the right home.
	/// Rejects with the typed break when the partner refuses the fetch, and with
	/// a broken error when it fulfills with something that is not a live
	/// capability.
	pub async fn fetch(&self, name: &str) -> Result<Ref> {
		crate::promise::fetch_like(
			&self.shared,
			name.as_bytes(),
			name,
			ffi::glowcap_host_session_fetch,
			true,
		)
		.await
	}

	/// Enliven a sturdyref against this session (ADR-0007): bring the durable
	/// `(peer, swissnum)` to life as a live [`Ref`]. The host verifies the complete
	/// locator against this session before consulting its dedup cache: a repeat
	/// enliven of the same swissnum on this session short-circuits with no wire
	/// traffic (its completion is queued before the minting call returns). The
	/// session must already be open to the sturdyref's peer. This session-level
	/// call never dials. Rejects with the typed break
	/// when the partner refuses, and with a broken error on a non-capability
	/// fulfillment.
	pub async fn enliven(&self, sturdyref: &str) -> Result<Ref> {
		crate::promise::fetch_like(
			&self.shared,
			sturdyref.as_bytes(),
			"enliven",
			ffi::glowcap_host_session_enliven,
			true,
		)
		.await
	}

	/// Listen on a far capability this session holds (CapTP `op:listen`,
	/// ADR-0003): the returned handle settles with the listen notification,
	/// which may be any value, not only a capability. In 1.0, the target may be
	/// a far promise or live far object. In glowcap-next, the target must be a
	/// promise. A re-gifted promise routes to its exporter session
	/// transparently.
	pub fn listen(&self, target: &Ref) -> RemotePromise {
		crate::promise::listen_far(&self.shared, target)
	}

	/// Resolve an opaque capability. A live object returns an independently
	/// owned handle without wire traffic. A promise awaits its settlement,
	/// which may be any value. The Host owns routing and handoff redemption.
	pub async fn resolve(&self, target: &Ref) -> Result<Argument> {
		crate::promise::resolve(&self.shared, target).await
	}

	/// Eventual-send `verb(args)` to `target` and return a [`RemotePromise`] for
	/// the reply. `await` it for the value (a capability via `Ref::try_from`, a
	/// typed `Err` on a partner break).
	///
	/// `target` is a capability `&Ref` *or* a `&RemotePromise` from an earlier
	/// send: passing the latter pipelines (ADR-0003). The call is addressed at
	/// the answer that send will resolve, so a dependent chain costs one round
	/// trip instead of one per link. `args` may contain capabilities via
	/// `Into<Argument>`. A `Ref` this session spawned runs in process. A
	/// partner's rides the wire, and a redeemed or fetched token routes to the
	/// exporter session that hosts it, transparently.
	pub fn send<T: AsSendTarget>(&self, target: T, verb: &str, args: &[Argument]) -> RemotePromise {
		crate::promise::send_promise(&self.shared, target.as_send_target(), verb, args)
	}

	/// Eventual-send `verb(args)` to `target`, await the reply, and also hand
	/// back the direct session a three-party-handoff redeem opened to answer
	/// it.
	///
	/// When `target` answers with a `desc:handoff-give`, a rooms `introduce`,
	/// say, the host redeems it by dialing the exporter, and the reply resolves
	/// to a capability that routes over a fresh direct session. The byte
	/// connection is otherwise internal. This surfaces the session as
	/// [`via`](SendRedeemingResult::via), so the caller can host its own objects in the same
	/// session as the redeemed capability. That is the one place a
	/// reply capability handed back to the exporter is valid, because an OCapN
	/// near export names a position in one specific session: spawn the
	/// inbox on `via` and the exporter can call it, spawn it on this session and
	/// the exporter has no route to it.
	///
	/// `via` is resolved from the reply's own token, which carries the exporter
	/// session it lives in, rather than from watching which dial ran during
	/// the send. So it is right with several redeems in flight at once, and it
	/// names the exporter even when the redeem reused a session an earlier
	/// one already dialed, where there is no fresh dial to observe. `via` is
	/// `None` when the reply is not a redeemed-handoff capability (an ordinary
	/// far reply) or when its exporter session has already gone.
	///
	/// ```ignore
	/// let SendRedeemingResult { reply, via } = session.send_redeeming(&directory, "introduce", &[nick]).await?;
	/// let member = Ref::try_from(&reply).expect("introduce answers with a capability");
	/// let hop = via.as_ref().unwrap_or(&session);
	/// let inbox = hop.spawn(reply_behavior)?;   // hosted where the reply lives
	/// hop.send(&member, "dm", &[text, (&inbox).into()]).await?;
	/// ```
	pub async fn send_redeeming<T: AsSendTarget>(
		&self,
		target: T,
		verb: &str,
		args: &[Argument],
	) -> Result<SendRedeemingResult> {
		self.shared.guard_open()?;
		let reply = self.send(target, verb, args).await?;
		let via = match Ref::try_from(&reply) {
			Ok(capability) => self.shared.host.exporter_for(&capability)?.and_then(|home| {
				if Rc::ptr_eq(&home, &self.shared) {
					None
				} else {
					Some(Session::view(home))
				}
			}),
			// Not a capability in hand, so it names no route: a plain value, a
			// sturdyref, or a broken reference.
			Err(()) => None,
		};
		Ok(SendRedeemingResult { reply, via })
	}

	/// Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and
	/// no reply comes back, so a notification or broadcast costs one deliver
	/// rather than a deliver plus a reply. Returns once the deliver is queued on
	/// the host. The scheduled drain flushes it, in order with the sends around
	/// it.
	pub fn tell<T: AsSendTarget>(&self, target: T, verb: &str, args: &[Argument]) -> Result<()> {
		crate::promise::tell_target(&self.shared, target.as_send_target(), verb, args)
	}

	/// Start or resume inbound delivery immediately. The first call takes the
	/// serve task. Awaiting it observes admission or task failure and eventual
	/// close. Later calls report admission only. Use [`Session::closed`] for
	/// independent retirement observers. Dropping a serve future gives up its
	/// observation while delivery continues. Keep the
	/// `Session` handle alive while serving, because dropping it closes the
	/// connection under the partner.
	///
	/// `use<>` says the future captures nothing from this call: admission, the
	/// serve handle, and the close observer are all taken out of the shared
	/// state before the `async move`, so the future outlives the borrow. Rust
	/// 2024 would otherwise capture `&self` implicitly, and a caller that
	/// starts serving and then moves the `Session` into its client, which is
	/// the ordinary shape, because the handle must stay alive, would be
	/// refused for a borrow the future does not hold. Keeping the handle alive
	/// is a contract the sentence above states, not one the borrow checker is
	/// asked to carry.
	pub fn serve(&self) -> impl std::future::Future<Output = Result<()>> + use<> {
		// A loop-backed session's inbound is held until its embedder serves;
		// announce readiness before parking on closure, the byte-fed
		// serve-resume contract spoken at the loop tier.
		const CONTEXT: &str = "session serve task failed";
		let admission = self.shared.attend_inbound();
		let handle = if admission.is_ok() {
			self.shared.take_serving()
		} else {
			None
		};
		let observer = Session::view(Rc::clone(&self.shared));
		async move {
			admission?;
			if let Some(handle) = handle {
				let outcome = handle
					.await
					.map_err(|error| Error::with_detail(sys::ERR_INTERNAL, format!("{CONTEXT}: {error}")))?;
				let retired = observer.closed().await;
				return match (outcome, retired) {
					(Err(primary), Err(secondary)) if primary != secondary => Err(primary.with_secondary(secondary)),
					(Err(primary), _) => Err(primary),
					(Ok(()), retired) => retired,
				};
			}
			Ok(())
		}
	}

	pub(crate) fn raw_session(&self) -> *mut ffi::GlowcapHostSession {
		self.shared.raw_session()
	}

	pub(crate) fn close_transport(&self) {
		self.shared.close_transport();
	}
}

#[cfg(all(test, feature = "tcp"))]
#[path = "session_tests.rs"]
mod tests;
