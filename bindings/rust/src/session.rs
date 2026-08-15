//! The application surface over the byte-fed host (`libpancake_host`,
//! ADR-0072): [`Session`] and its verbs (`fetch`/`send`/`tell`/`spawn`/
//! `publish`/`enliven`/`serve`/`close`), plus mint/handshake (`establish_*`).
//! The managed dial executor (provider selection + channel open + [`Runtime::connect`]) lives in
//! [`crate::dial`]; [`Server`] / [`listen`] live in [`crate::listen`]. The
//! [`RemotePromise`] handle lives in [`crate::promise`]. CapTP action
//! decode+execute lives in [`crate::action`].
//! Per-session [`Caretaker`] / [`SessionShared`] live in [`crate::session_shared`];
//! the Host-scoped [`Ref`] lives beside [`Argument`](crate::Argument).
//! The byte-fed pump choreography — read raw bytes, `pancake_host_session_feed_bytes`,
//! drain the action queue, write what `take_outbound` drains, feed-refusal /
//! `last_abort`, EOF / `break_far_vows` — lives in [`crate::pump`]; this module
//! keeps CapTP verbs and thin wrappers into that path. A loop-backed session
//! (ADR-0112) carries the same verbs with no pump at all: the native loop owns
//! its wire ([`crate::driver_loop`]). The host owns everything
//! else: routing, redemption, gift origination, far vows.
//!
//! Everything runs on one tokio current-thread `LocalSet`; the handles are
//! `!Send` by construction, so create and use them on one task inside it.

use std::rc::Rc;
use std::time::Duration;

#[cfg(any(test, feature = "iroh"))]
use tokio::io::{AsyncRead, AsyncWrite};

#[cfg(any(test, feature = "iroh"))]
use crate::host::HostShared;
use crate::host::{check_host, try_spawn_local_handle, Host};
use crate::lifecycle::PendingWork;
use crate::session_shared::{Caretaker, SessionShared};
use crate::sys::host as ffi;
use crate::trampoline::outcome_behavior;
use crate::uri::OwnedLocator;
use crate::Ref;
use crate::{sys, Argument, Error, Locator, Result};

use crate::promise::{AsSendTarget, RemotePromise};

#[cfg(all(test, feature = "tcp"))]
pub(crate) type DesignatorScheme = u32;

/// How long a partner has to finish the keyed handshake once the byte channel
/// is open, on both halves: what [`Runtime::connect`](crate::Runtime::connect) allows a dialed
/// partner, and what a listener allows an accepted one.
///
/// Matches the CLI's own product default. Something finite is the point: this
/// project's rule for CapTP waits is that an unbounded one is a hang rather
/// than a slow success, and neither half of a connection is exempt. It bounds
/// the handshake alone, never opening the channel: a TCP connect keeps the
/// OS's own timeout, and an iroh dial-by-id keeps its discovery retry budget
/// (ADR-0082), both of which finish before the handshake starts.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u64);

/// A live CapTP session with one OCapN partner — the one object an application
/// holds, over one byte-fed `PancakeHostSession` the shared [`Host`] minted.
/// `!Send` by construction; use it on a single task inside a `LocalSet`.
/// A dial or accept returns an owning handle whose drop closes the session.
/// Host-retained views, such as `send_redeeming`'s `via`, do not close on drop;
/// explicit [`close`](Session::close) still closes the session they name.
pub struct Session {
	shared: Rc<SessionShared>,
	// Production handles own one alias. The false arm exists only for focused
	// lifecycle tests that need to observe the last-owner transition in-turn.
	owns_session: bool,
}

/// What [`Session::send_redeeming`] settles with: the partner's reply, and the
/// direct exporter session that reply routes to.
impl Session {
	/// Binding-internal: the raw handles the trace veneer names a
	/// session by (`annotate_session`). Null session pointer after
	/// close — the veneer treats that as nothing to annotate.
	pub(crate) fn trace_handles(&self) -> (*mut ffi::PancakeHost, *mut ffi::PancakeHostSession) {
		(self.shared.host.raw(), self.shared.ptr.get())
	}
}

pub struct SendRedeemingResult {
	/// The value the send settled with, exactly what an ordinary
	/// [`Session::send`] would have yielded. Lift a capability out of it with
	/// `Ref::try_from(&reply)`.
	pub reply: Argument,
	/// The direct session the reply's capability lives in, when the reply is
	/// a capability a three-party-handoff redeem brought in; `None` for an
	/// ordinary far reply, or when that exporter session has already gone.
	///
	/// The Host retains this view and the reply capability independently of the
	/// returned Rust value, so dropping `via` does not close the exporter.
	/// Calling [`close`](Session::close) closes that exporter explicitly. It
	/// reaches neither the session you sent on nor another exporter session.
	pub via: Option<Session>,
}

/// Who the partner on a session proved itself to be, as
/// [`Session::partner_identity`] returns it.
///
/// Every field is copied out of the session at the call, so the values outlive
/// the session that produced them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PartnerIdentity {
	/// The partner's session public key, the one thing its handshake signature
	/// is made with. Always present.
	pub session_key: Vec<u8>,
	/// The location designator the partner signed, such as a hex key for
	/// `keyed-tcp` or a `host:port` for `tcp`. Empty when the partner's
	/// location carried no designator.
	pub designator: String,
	/// The verbatim `<ocapn-peer>` record the key and designator were read
	/// from, which is the span the signature covers. Empty when the session
	/// captured no record.
	pub locator_record: Vec<u8>,
	/// How the durable identity in `designator` was authenticated, if at all.
	/// Session identity, durable identity, and this provenance are three
	/// separate facts (ADR-0097): ask
	/// [`durable_identity_authenticated`](PartnerIdentity::durable_identity_authenticated)
	/// for a proved durable peer, never whether `designator` equals
	/// `session_key`.
	pub provenance: DurableProvenance,
}

/// How a partner's advertised durable identity was authenticated, the third
/// fact [`PartnerIdentity`] reports beside session key and designator.
///
/// The answer is a property of the connection rather than of its transport name
/// (ADR-0105): the same transport symbol reaches this peer over code that can
/// prove something and code that cannot, so no list of transports belongs here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DurableProvenance {
	/// The code that realized this connection verified the far end of the byte
	/// channel holds a durable key, and the partner claimed that same key.
	AuthenticatedTransport,
	/// No durable identity was proved. An address transport designates a socket
	/// address rather than a key, and a partner that advertised an address on a
	/// key transport claimed no durable identity to authenticate.
	Unauthenticated,
}

impl DurableProvenance {
	/// One ABI provenance value in its spoken form.
	///
	/// Two surfaces report the same provenance fact about the same partner —
	/// this identity query and the live trace's session-open — so the mapping
	/// lives here once rather than being spelled at each of them.
	pub(crate) fn from_abi(raw: u32) -> Self {
		match raw {
			sys::DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT => Self::AuthenticatedTransport,
			_ => Self::Unauthenticated,
		}
	}
}

impl PartnerIdentity {
	/// Whether the durable identity this partner advertised was
	/// cryptographically authenticated by the realized channel. This is the
	/// predicate to ask when an operation requires a proved durable peer; it
	/// stays correct once each session draws a fresh signing key.
	pub fn durable_identity_authenticated(&self) -> bool {
		self.provenance != DurableProvenance::Unauthenticated
	}
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

	/// Mint the dialing half over a byte channel the caller already realized
	/// for `locator`. The locator travels whole; the host retains its own dial
	/// default for the transport, so no locator policy lives here. The
	/// handshake is bounded by `handshake_timeout` ([`HANDSHAKE_TIMEOUT`] on
	/// every dial the binding performs; `None` or a zero budget waits
	/// unbounded), and overrunning it fails with
	/// [`ErrorKind::TimedOut`](crate::ErrorKind::TimedOut). Binding-internal.
	#[cfg(any(test, feature = "iroh"))]
	pub(crate) async fn establish_dialed_locator<S>(
		host: Rc<HostShared>,
		locator: &crate::Locator,
		stream: S,
		handshake_timeout: Option<Duration>,
		verified_channel_key: Option<&str>,
	) -> Result<Session>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		host.guard_handle()?;
		let owned = OwnedLocator::new(locator)?;
		let mut ptr: *mut ffi::PancakeHostSession = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_session_open_dialed_locator(host.raw(), owned.borrow_view()?, &mut ptr)
		})?;
		let session = Session::owning(SessionShared::new(ptr, host, stream));
		// Before the first partner byte, which is the only window a realizer's
		// proof can be weighed in.
		if let Some(key) = verified_channel_key {
			session.bind_verified_channel_key(key)?;
		}
		session.establish(handshake_timeout).await
	}

	/// Mint the accepting half over a connection the caller's own listener
	/// produced. `server_designator` is the listener's signing designator (key
	/// for keyed-tcp/iroh; unused for tcp); `accepted_local_addr` is what
	/// accept reported. The host resolves what this accept signs and retains
	/// it without displacing an explicitly selected advertised locator
	/// (ADR-0078); no locator policy lives in this binding. The handshake is bounded by
	/// `handshake_timeout` ([`HANDSHAKE_TIMEOUT`] in every accept loop here;
	/// `None` or a zero budget waits unbounded, which a caller with no inline
	/// accept loop of its own may want), and overrunning it fails with
	/// [`ErrorKind::TimedOut`](crate::ErrorKind::TimedOut), which an accept loop
	/// skips like any other bad partner. Binding-internal.
	#[cfg(all(test, feature = "tcp"))]
	pub(crate) async fn establish_accepted<S>(
		host: Rc<HostShared>,
		transport_name: &str,
		designator_scheme: DesignatorScheme,
		server_designator: &str,
		stream: S,
		accepted_local_addr: &str,
		handshake_timeout: Option<Duration>,
		verified_channel_key: Option<&str>,
	) -> Result<Session>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		host.guard_handle()?;
		let mut ptr: *mut ffi::PancakeHostSession = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_session_open_accepted(
				host.raw(),
				transport_name.as_ptr(),
				transport_name.len(),
				designator_scheme,
				server_designator.as_ptr(),
				server_designator.len(),
				accepted_local_addr.as_ptr(),
				accepted_local_addr.len(),
				&mut ptr,
			)
		})?;
		let session = Session::owning(SessionShared::new(ptr, host, stream));
		// Before the first partner byte, which is the only window a realizer's
		// proof can be weighed in.
		if let Some(key) = verified_channel_key {
			session.bind_verified_channel_key(key)?;
		}
		session.establish(handshake_timeout).await
	}

	// Drive the keyed handshake to an open session and start the serve loop,
	// abandoning the connection on any failure (release + transport close) so a
	// rude partner costs one dial or one accept, never the caller.
	//
	// The one place both halves bound that handshake. A peer that opens the
	// byte channel and then says nothing is the case no failure check can catch
	// — nothing fails, the handshake simply waits — so unbounded it parks the
	// dialer forever, and on the accepting side every later connection behind
	// that one client. `None` is the caller's explicit opt-in to waiting
	// without a bound, and so is a zero budget: zero is how the C ABI and the
	// sibling bindings spell "no bound", so a caller threading a configured
	// millisecond count through must not land on a deadline of right now. An
	// elapsed budget takes the same abandon path a failed handshake does:
	// dropping the handshake future drops the read half, and the teardown below
	// releases the half-built session and closes the transport.
	#[cfg(any(test, feature = "iroh"))]
	async fn establish(self, handshake_timeout: Option<Duration>) -> Result<Session> {
		let handshake = crate::pump::run_handshake(&self.shared);
		let outcome = match handshake_timeout.filter(|budget| !budget.is_zero()) {
			Some(budget) => match tokio::time::timeout(budget, handshake).await {
				Ok(outcome) => outcome,
				Err(_) => Err(Error::with_detail(
					sys::ERR_TIMEOUT,
					format!(
						"the partner did not finish the OCapN handshake within {}ms",
						budget.as_millis()
					),
				)),
			},
			None => handshake.await,
		};
		match outcome {
			Ok(()) => {
				self.shared.spawn_serve();
				Ok(self)
			}
			Err(error) => {
				// Explicit rather than left to the `Drop` behind it: a
				// half-built session is abandoned on the same terms whatever
				// this handle's ownership disposition is. `close_transport` is
				// idempotent (`released`), so that drop is a no-op.
				self.shared.close_transport();
				Err(error)
			}
		}
	}

	/// The session's shared [`Host`], its retained identity and handoff router.
	/// Shared by every session of one Host, so the gifter half of a handoff
	/// can reach a sibling session's session keys. An application reads it to
	/// publish Host-giftables ([`Host::publish_giftable`]), share one identity
	/// across dials, or set the redeem posture.
	pub fn host(&self) -> Host {
		Host::from_shared(Rc::clone(&self.shared.host))
	}

	/// Record the complete exporter locator the gifter embeds when *this*
	/// session is the exporter side of a handoff
	/// this host originates (ADR-0009). Needed when the partner's signed location
	/// is not dialable on its own — an iroh partner signs only its node id, so a
	/// gifter that learned the exporter's `direct-addresses` out of band sets the
	/// full locator here. Unset, origination falls back to the partner's signed
	/// location.
	///
	/// Fallible, unlike an earlier shape that returned `()` and dropped both a
	/// closed session and a refused call. This is the one method where silence
	/// produces exactly the outcome the caller called it to avoid: on failure
	/// origination reverts to the partner's signed location, and the recipient's
	/// redeem dial fails later, in another process, with an unrelated message.
	/// The other three bindings raise here.
	pub fn set_exporter_locator(&self, locator: Option<&Locator>) -> Result<()> {
		self.shared.guard_open()?;
		let owned = locator.map(OwnedLocator::new).transpose()?;
		let view = match owned.as_ref() {
			Some(value) => value.borrow_view()?,
			None => core::ptr::null(),
		};
		check_host(unsafe { ffi::pancake_host_session_set_exporter_location(self.shared.ptr.get(), view) })?;
		Ok(())
	}

	/// Who this session's partner proved itself to be during the handshake.
	///
	/// A partner's keyed `op:start-session` carries an Ed25519 signature over
	/// its own location record, and the engine verifies that signature before
	/// the session opens. So a success here always means the signature was
	/// checked. The signed span binds the whole locator claim to the fresh
	/// [`session_key`](PartnerIdentity::session_key); it does not prove control
	/// of the durable [`designator`](PartnerIdentity::designator). Read
	/// [`provenance`](PartnerIdentity::provenance) before relying on a durable
	/// identity.
	///
	/// The bytes are copied out of the session here, so the returned
	/// [`PartnerIdentity`] stays valid after the session closes.
	///
	/// Two refusals are ordinary rather than faults. Before the partner's
	/// `op:start-session` has arrived with a key there is nothing to report
	/// yet, and a session opened without partner verification has no proved
	/// identity at all.
	pub fn partner_identity(&self) -> Result<PartnerIdentity> {
		self.shared.guard_open()?;
		let mut out = ffi::PancakePartnerIdentity {
			session_key: core::ptr::null(),
			session_key_len: 0,
			designator: core::ptr::null(),
			designator_len: 0,
			locator_record: core::ptr::null(),
			locator_record_len: 0,
			provenance: sys::DURABLE_PROVENANCE_UNAUTHENTICATED,
		};
		check_host(unsafe { ffi::pancake_host_session_partner_identity(self.shared.ptr.get(), &mut out) })?;
		// Session-owned views, valid only until the session is released, so
		// every field is copied before it leaves this call.
		let (session_key, designator, locator_record) = unsafe {
			(
				crate::owned_from_view(out.session_key, out.session_key_len),
				crate::owned_from_view(out.designator, out.designator_len),
				crate::owned_from_view(out.locator_record, out.locator_record_len),
			)
		};
		let provenance = DurableProvenance::from_abi(out.provenance);
		Ok(PartnerIdentity {
			session_key,
			designator: String::from_utf8_lossy(&designator).into_owned(),
			locator_record,
			provenance,
		})
	}

	/// Testify what proved this connection's far end, when your own transport
	/// proved one.
	///
	/// pancake does not open your sockets, so it cannot see what opening them
	/// established. An iroh connection completes only with the holder of the
	/// node id you dialed or accepted, and that is a stronger fact than
	/// anything a partner can claim about itself — but only you hold it. Pass
	/// the node id here and [`partner_identity`](Session::partner_identity)
	/// reports `AuthenticatedTransport`; withhold it and the same session
	/// reports `Unauthenticated`.
	///
	/// `designator` is that identity as a locator writes it, which is exactly
	/// what the iroh transport's remote node id hands you.
	///
	/// Call it after opening the session and before feeding the first byte from
	/// the partner. It fails afterwards, because by then the handshake this
	/// evidence was for has already been judged. Naming a second, different
	/// identity fails too: one connection has one far end. Naming the same one
	/// twice is the same statement made twice and succeeds.
	pub fn bind_verified_channel_key(&self, designator: &str) -> Result<()> {
		self.shared.guard_open()?;
		check_host(unsafe {
			ffi::pancake_host_session_bind_verified_channel_key(
				self.shared.ptr.get(),
				designator.as_ptr(),
				designator.len(),
			)
		})?;
		Ok(())
	}

	/// Opt this session into distributed GC (ADR-0063), off by default. Once
	/// on, a far capability returned by [`fetch`](Session::fetch) releases its
	/// import to the partner — a single `op:gc-exports` delta, routed through the
	/// host to the import's home connection — when the last `Ref` to it is
	/// dropped, so the partner can release the matching export. Capabilities
	/// lifted elsewhere (a `send` reply, a delivered argument via `Ref::try_from`,
	/// an `enliven` result the dedup cache owns) are outside this seam. Returns
	/// `self` for chaining after `connect`.
	pub fn with_gc(self) -> Session {
		self.shared.gc.set(true);
		self
	}

	/// A [`Ref`] for the object published under `name` on this session, or `None`
	/// when nothing is published there.
	///
	/// [`Session::publish`] returns its own `Ref`, so this is for the other
	/// publisher: [`Host::publish_giftable`](crate::Host::publish_giftable) hosts
	/// one actor under a Host-wide alias and returns nothing. This lazily projects
	/// the actor onto the session and returns its Host identity; no enrollment
	/// step exists.
	///
	/// A send to the returned `Ref` runs the behavior in process rather than over
	/// the wire, and a giftable registered no session, so `current_session()`
	/// inside it is `None`. Pass it on as a capability argument; a
	/// behavior written to answer over the connection its call arrived on will not
	/// answer a local send.
	pub fn published_ref(&self, name: &str) -> Result<Option<Ref>> {
		self.shared.guard_open()?;
		let mut reference = sys::PancakeReference { id: 0 };
		let rc = unsafe {
			ffi::pancake_host_session_published_ref(self.shared.ptr.get(), name.as_ptr(), name.len(), &mut reference)
		};
		if rc == sys::ERR_NOT_FOUND {
			return Ok(None);
		}
		check_host(rc)?;
		// Join the host's giftable to the identity this session surfaced, so a
		// later local send to the returned Ref composes in process.
		self.shared.bind_host_giftable(name, reference.id);
		Ok(Some(Ref::bare_id(reference.id)))
	}

	/// Give a capability back to the partner, now, because this application is
	/// done holding it.
	///
	/// Releases one application retain. For a remote capability the Host emits
	/// any required `op:gc-exports`; a local capability needs no wire message.
	/// [`with_gc`](Session::with_gc) does this too, but only for a
	/// [`fetch`](Session::fetch) result; this works for any far capability this
	/// session holds, including one lifted from a delivered argument or a reply.
	///
	/// `cap` is taken by value, so the handle you released is gone. A clone
	/// made earlier reads [`Ref::released`] as true and is a caller error to
	/// use. The Host generation makes the stale id fail closed, and the binding
	/// rejects the clone before crossing the ABI.
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
	/// is opaque and Host-scoped; wire export positions stay inside pancake.
	/// Callable from inside a served turn (a factory's `create` minting the task
	/// it replies with).
	pub fn spawn(
		&self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		self.shared.spawn_actor(outcome_behavior(behavior))
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

	/// Wrap `target` (local or far) in a revocable caretaker (ADR-0064). Returns a
	/// [`Caretaker`] whose `proxy` is an ordinary capability you hand a partner;
	/// every call through it forwards to `target` until you
	/// [`revoke`](Caretaker::revoke) it, after which each call breaks with
	/// `Revoked`. `target` may be a capability you imported over the wire — the
	/// proxy forwards transparently — so this hands out a revocable view of
	/// authority you do not own locally.
	pub fn caretaker(&self, target: &Ref) -> Result<Caretaker> {
		crate::trampoline::caretaker_proxy(&self.shared, target)
	}

	/// Wrap `target` (local or far) in an attenuator (ADR-0064): a proxy that
	/// forwards only the calls whose verb is in `verbs` and breaks every other
	/// with `Attenuated`. Returns the proxy capability to hand a partner. `target`
	/// may be a wire-imported capability, so this narrows authority you hold.
	pub fn attenuate(&self, target: &Ref, verbs: &[&str]) -> Result<Ref> {
		crate::trampoline::attenuate_proxy(&self.shared, target, verbs)
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
		crate::promise::fetch_like(
			&self.shared,
			name.as_bytes(),
			name,
			ffi::pancake_host_session_fetch,
			true,
			|reference| crate::gc::track_import(&self.shared, reference),
		)
		.await
	}

	/// Enliven a sturdyref against this session (ADR-0098): bring the durable
	/// `(peer, swissnum)` to life as a live [`Ref`]. The host verifies the complete
	/// locator against this session before consulting its dedup cache — a repeat
	/// enliven of the same swissnum on this session short-circuits with no wire
	/// traffic (its completion is queued before the minting call returns). The
	/// session must already be open to the sturdyref's peer; this session-level
	/// call never dials. Rejects with the typed break
	/// when the partner refuses, and with a broken error on a non-capability
	/// fulfillment.
	pub async fn enliven(&self, sturdyref: &str) -> Result<Ref> {
		crate::promise::fetch_like(
			&self.shared,
			sturdyref.as_bytes(),
			"enliven",
			ffi::pancake_host_session_enliven,
			false,
			|reference| crate::gc::track_import(&self.shared, reference),
		)
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
	/// `Into<Argument>`. A `Ref` this session spawned runs in process; a
	/// partner's rides the wire, and a redeemed or fetched token routes to the
	/// exporter session that hosts it, transparently.
	/// Listen on a far capability this session holds (CapTP `op:listen`,
	/// ADR-0095): the returned handle settles with the listen notification,
	/// which may be any value, not only a capability. In 1.0, the target may be
	/// a far promise or live far object; in pancake-next, the target must be a
	/// promise. A re-gifted promise routes to its exporter session
	/// transparently.
	pub fn listen(&self, target: &Ref) -> RemotePromise {
		crate::promise::listen_far(&self.shared, target)
	}

	pub fn send<T: AsSendTarget>(&self, target: T, verb: &str, args: &[Argument]) -> RemotePromise {
		crate::promise::send_promise(&self.shared, target.as_send_target(), verb, args)
	}

	/// Eventual-send `verb(args)` to `target`, await the reply, and also hand
	/// back the direct session a three-party-handoff redeem opened to answer
	/// it.
	///
	/// When `target` answers with a `desc:handoff-give` — a rooms `introduce`,
	/// say — the host redeems it by dialing the exporter, and the reply resolves
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
	/// the host; the scheduled drain flushes it, in order with the sends around
	/// it.
	pub fn tell(&self, target: &Ref, verb: &str, args: &[Argument]) -> Result<()> {
		self.shared.tell(target, verb, args)
	}

	/// Run the inbound event loop in the background (it already runs from
	/// `connect`); the returned future completes when the connection closes.
	/// Calling starts or resumes delivery immediately. Await the future to
	/// observe admission or task failure and the eventual close; deliberately
	/// dropping it gives up that observation while delivery continues. Keep the
	/// `Session` handle alive while serving, because dropping it closes the
	/// connection under the partner.
	pub fn serve(&self) -> impl std::future::Future<Output = Result<()>> {
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
		async move {
			admission?;
			if let Some(handle) = handle {
				let outcome = handle
					.await
					.map_err(|error| Error::with_detail(sys::ERR_INTERNAL, format!("{CONTEXT}: {error}")))?;
				outcome?;
			}
			Ok(())
		}
	}

	pub(crate) fn raw_session(&self) -> *mut ffi::PancakeHostSession {
		self.shared.raw_session()
	}

	pub(crate) fn close_transport(&self) {
		self.shared.close_transport();
	}

	/// Close the session. A running [`serve`](Session::serve) completes; pending
	/// vows settle closed.
	///
	/// This closes the connection it names and nothing else: not a sibling
	/// session, and not the connections the host dialed by itself to redeem a
	/// handoff — the `via` from [`send_redeeming`](Session::send_redeeming) is
	/// one of those. [`Host::close`](crate::Host::close) is what ends those.
	///
	pub async fn close(&self, pending: PendingWork) -> Result<()> {
		if self.shared.released.get() {
			return self.shared.terminal_result();
		}
		request_session_close(&self.shared, pending)?;
		ensure_session_close_driver(&self.shared)?;
		wait_session_close(&self.shared).await;
		self.shared.terminal_result()
	}
}

fn ensure_session_close_driver(shared: &Rc<SessionShared>) -> Result<()> {
	if shared.close_task.borrow().is_some() {
		return Ok(());
	}
	let driver = Rc::clone(shared);
	let Some(task) = try_spawn_local_handle(async move { drive_session_close(driver).await }) else {
		return Err(Error::with_detail(
			sys::ERR_INTERNAL,
			"session close requires a running LocalSet".into(),
		));
	};
	*shared.close_task.borrow_mut() = Some(task);
	Ok(())
}

async fn drive_session_close(shared: Rc<SessionShared>) {
	while !shared.released.get() {
		if let Some(loop_) = shared.loop_wire.as_ref() {
			// The loop tier's discipline: progress happens only inside
			// `pancake_driver_step`, so this driver is the deadline-stepper.
			// Register the loop-activity waiter before stepping, so a rival
			// path's step landing between this step and the park still wakes
			// this driver instead of being lost.
			let notified = loop_.step_activity();
			tokio::pin!(notified);
			notified.as_mut().enable();
			if let Err(error) = loop_.step_now() {
				loop_.fail_background(error);
				return;
			}
			if shared.released.get() {
				break;
			}
			// Park on loop activity or on the nearest pending-work deadline
			// (this session's close grace included). An expiry takes effect
			// only inside a step, so the timer wake is what applies it; with
			// no finite deadline pending, readiness-driven steps alone
			// advance the loop.
			match loop_.step_wait() {
				Ok(Some(wait)) => {
					tokio::select! {
						() = notified.as_mut() => {}
						() = tokio::time::sleep(wait) => {}
					}
				}
				Ok(None) => notified.await,
				Err(error) => {
					shared.record_close_result(error.code());
					shared.close_transport();
					return;
				}
			}
			continue;
		}
		// Register the activity waiter before the progress check, so a verb
		// completing between the check and the await still wakes this loop
		// instead of being lost.
		let notified = shared.host.close_activity();
		tokio::pin!(notified);
		notified.as_mut().enable();
		let mut lifecycle = 0;
		let rc = unsafe { ffi::pancake_host_session_close_progress(shared.ptr.get(), monotonic_ms(), &mut lifecycle) };
		if rc != sys::OK && rc != sys::ERR_TIMEOUT {
			shared.record_close_result(rc);
			shared.close_transport();
			return;
		}
		// Drain what progress queued (this session's release rides an action)
		// before parking; a productive drain re-signals the registered waiter.
		if let Err(error) = shared.host.kick_actions().await {
			shared.record_close_result(error.code());
			shared.close_transport();
			return;
		}
		if shared.released.get() {
			break;
		}
		// The host-level wait covers every session's FINISH grace deadline,
		// this one included; with no finite deadline pending, only host
		// activity can advance terminal progress.
		match shared.host.close_wait() {
			Ok(Some(wait)) => {
				tokio::select! {
					() = notified.as_mut() => {}
					() = tokio::time::sleep(wait) => {}
				}
			}
			Ok(None) => notified.await,
			Err(error) => {
				shared.record_close_result(error.code());
				shared.close_transport();
				return;
			}
		}
	}
}

async fn wait_session_close(shared: &SessionShared) {
	while !shared.released.get() {
		let notified = shared.closed.notified();
		tokio::pin!(notified);
		notified.as_mut().enable();
		if shared.released.get() {
			break;
		}
		notified.await;
	}
}

fn monotonic_ms() -> i64 {
	use std::sync::OnceLock;
	use std::time::Instant;

	static EPOCH: OnceLock<Instant> = OnceLock::new();
	let elapsed = EPOCH.get_or_init(Instant::now).elapsed().as_millis();
	i64::try_from(elapsed).unwrap_or(i64::MAX)
}

pub(crate) fn session_close_result(code: i32) -> Result<()> {
	if code == sys::OK {
		Ok(())
	} else if code == sys::ERR_TIMEOUT {
		Err(Error::with_detail(
			code,
			"finish close exhausted its grace period".into(),
		))
	} else {
		Err(Error::with_detail(code, "native session close failed".into()))
	}
}

impl Drop for Session {
	fn drop(&mut self) {
		// Focused lifecycle tests use a borrowed handle while dropping the real
		// owner from inside its callback.
		if !self.owns_session {
			return;
		}
		let owners = self.shared.owner_handles.get();
		debug_assert!(owners != 0);
		self.shared.owner_handles.set(owners - 1);
		if owners != 1 {
			return;
		}
		if self.shared.released.get() {
			return;
		}
		if request_session_close(&self.shared, PendingWork::Cancel)
			.and_then(|()| ensure_session_close_driver(&self.shared))
			.is_err()
		{
			self.shared.close_transport();
		}
	}
}

pub(crate) fn request_session_close(shared: &Rc<SessionShared>, pending: PendingWork) -> Result<()> {
	if shared.released.get() {
		return Ok(());
	}
	if let Some(loop_) = shared.loop_wire.as_ref() {
		loop_.request_session_close(shared.ptr.get(), pending)?;
	} else {
		let options = pending.to_ffi()?;
		check_host(unsafe { ffi::pancake_host_session_close(shared.ptr.get(), &options, monotonic_ms()) })?;
		// A close request or escalation is close-relevant activity: a driver
		// parked on a now-superseded wait must re-check progress.
		shared.host.note_close_activity();
		shared.host.schedule_kick()?;
	}
	shared.closing.set(true);
	Ok(())
}

#[cfg(all(test, feature = "tcp"))]
#[path = "session_tests.rs"]
mod tests;
