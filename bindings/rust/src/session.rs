//! The application surface over the byte-fed host (`libpancake_host`,
//! ADR-0072): [`Session`] and its verbs (`fetch`/`send`/`tell`/`spawn`/
//! `publish`/`enliven`/`serve`/`close`), plus mint/handshake (`establish_*`).
//! The dial executor (plan + channel open + [`connect`]) lives in
//! [`crate::dial`]; [`Server`] / [`listen`] live in [`crate::listen`]. The
//! [`RemotePromise`] handle lives in [`crate::promise`]. CapTP action
//! decode+execute lives in [`crate::action`].
//! Per-connection [`Caretaker`] / [`SessionShared`] live in [`crate::session_shared`];
//! the Host-scoped [`Ref`] lives beside [`Argument`](crate::Argument).
//! The byte-fed pump choreography — read raw bytes, `pancake_host_session_feed_bytes`,
//! drain the action queue, write what `take_outbound` drains, feed-refusal /
//! `last_abort`, EOF / `break_far_vows` — lives in [`crate::pump`]; this module
//! keeps CapTP verbs and thin wrappers into that path. The host owns everything
//! else: routing, redemption, gift origination, far vows.
//!
//! Everything runs on one tokio current-thread `LocalSet`; the handles are
//! `!Send` by construction, so create and use them on one task inside it.

use std::rc::Rc;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite};

use crate::host::{check_host, Host, HostShared};
use crate::session_shared::{Caretaker, SessionShared};
use crate::sys::host as ffi;
use crate::trampoline::outcome_behavior;
use crate::Ref;
use crate::{sys, Argument, Error, Result};

use crate::promise::{AsSendTarget, RemotePromise};

pub(crate) use crate::session_shared::io_err;

/// How long a partner has to finish the keyed handshake once the byte channel
/// is open, on both halves: what [`connect`](crate::connect) allows a dialed
/// partner, and what a listener allows an accepted one.
///
/// Matches the CLI's own product default. Something finite is the point: this
/// project's rule for CapTP waits is that an unbounded one is a hang rather
/// than a slow success, and neither half of a connection is exempt. It bounds
/// the handshake alone, never opening the channel: a TCP connect keeps the
/// OS's own timeout, and an iroh dial-by-id keeps its discovery retry budget
/// (ADR-0082), both of which finish before the handshake starts.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(10_000);

/// A live CapTP session with one OCapN partner — the one object an application
/// holds, over one byte-fed `PancakeHostSession` the shared [`Host`] minted.
/// `!Send` by construction; use it on a single task inside a `LocalSet`.
/// Dropping the handle closes the session, with one exception named on
/// [`Redeemed::via`]: a handle onto a session the host itself owns is a view,
/// and dropping the view leaves the connection running.
pub struct Session {
	shared: Rc<SessionShared>,
	// The ownership axis both teardown paths read. True for the handle that
	// dialed or accepted the session and is its owner: its `drop` and its
	// `close` end that one connection. Sweeping the host's redeemed exporter
	// connections is a separate axis, `owns_host` below. False for a view onto
	// a session the host owns and keeps
	// alive on its own account — an exporter connection a redeem dialed, handed
	// out by [`Session::send_redeeming`]. A view's `drop` closes nothing and its
	// `close` reaches no further than the one connection it names; sweeping
	// there would sever the very capability the caller asked for, along with
	// every other redeem in flight on the same host.
	owns_session: bool,
	// Set when this session created the host it runs on, which `connect` does
	// when the caller passes none. Such a host has no other reachable owner,
	// so closing the session takes it down; a caller-supplied host is never
	// closed here, because sibling sessions may still be using it.
	owns_host: bool,
}

/// What [`Session::send_redeeming`] settles with: the partner's reply, and the
/// direct exporter session that reply routes to.
pub struct Redeemed {
	/// The value the send settled with, exactly what an ordinary
	/// [`Session::send`] would have yielded. Lift a capability out of it with
	/// `Ref::try_from(&reply)`.
	pub reply: Argument,
	/// The direct connection the reply's capability lives on, when the reply is
	/// a capability a three-party-handoff redeem brought in; `None` for an
	/// ordinary far reply, or when that exporter connection has already gone.
	///
	/// It is a view, not an owner: dropping it leaves the exporter connection
	/// open, because the host owns that connection and the reply capability
	/// depends on it. Calling [`close`](Session::close) on it is an explicit
	/// close of that one exporter connection, which severs the reply capability
	/// beside it. It reaches no further: the session you sent on, and every
	/// other exporter connection the host dialed, keep running.
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DurableProvenance {
	/// The transport layer proved the partner's durable key: iroh's QUIC
	/// handshake, or WebRTC's DTLS binding under capability-authorized
	/// signaling.
	AuthenticatedTransport,
	/// The hello carried a `session-key-attestation` signed by the durable key
	/// its designator names, and it verified (`keyed-tcp`, `keyed-relay`).
	/// Static authorization: it proves the durable key authorized this session
	/// key, not that the signer is live on this connection.
	DurableKeyAttestation,
	/// No durable identity was proved. An address transport designates a socket
	/// address rather than a key, and a partner that advertised an address on a
	/// key transport claimed no durable identity to authenticate.
	Unauthenticated,
}

impl PartnerIdentity {
	/// Whether the durable identity this partner advertised was
	/// cryptographically authenticated, by either mechanism. This is the
	/// predicate to ask when an operation requires a proved durable peer; it
	/// stays correct once each connection draws a fresh session key.
	pub fn durable_identity_authenticated(&self) -> bool {
		self.provenance != DurableProvenance::Unauthenticated
	}
}

impl Session {
	// The owning handle over a session this side dialed or accepted: dropping
	// it closes the connection.
	pub(crate) fn owning(shared: Rc<SessionShared>) -> Session {
		Session {
			shared,
			owns_session: true,
			owns_host: false,
		}
	}

	// Mark this session as the owner of the host it runs on: `connect` sets it
	// when it had to make one, and nothing else does.
	pub(crate) fn set_owns_host(&mut self, owns: bool) {
		self.owns_host = owns;
	}

	// A view onto a session the host owns, for a caller that needs to spawn and
	// send on it without taking its life in hand.
	pub(crate) fn view(shared: Rc<SessionShared>) -> Session {
		Session {
			shared,
			owns_session: false,
			owns_host: false,
		}
	}

	/// Mint the dialing half from an already-parsed locator (`transport` +
	/// `designator`), matching a DIAL action's pieces. The handshake is bounded
	/// by `handshake_timeout` ([`HANDSHAKE_TIMEOUT`] on every dial the binding
	/// performs; `None` or a zero budget waits unbounded), and overrunning it
	/// fails with [`ErrorKind::TimedOut`](crate::ErrorKind::TimedOut).
	/// Binding-internal.
	pub(crate) async fn establish_dialed_locator<S>(
		host: Rc<HostShared>,
		transport: &str,
		designator: &str,
		stream: S,
		handshake_timeout: Option<Duration>,
	) -> Result<Session>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		host.guard_open()?;
		let mut ptr: *mut ffi::PancakeHostSession = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_session_open_dialed_locator(
				host.raw(),
				transport.as_ptr(),
				transport.len(),
				designator.as_ptr(),
				designator.len(),
				&mut ptr,
			)
		})?;
		Session::owning(SessionShared::new(ptr, host, stream))
			.establish(handshake_timeout)
			.await
	}

	/// Mint the accepting half over a connection the caller's own listener
	/// produced. `server_designator` is the listener's signing designator (key
	/// for keyed-tcp/iroh; unused for tcp); `accepted_local_addr` is what
	/// accept reported. Signing designator/hint come from
	/// `pancake_host_plan_accept` (ADR-0078). The handshake is bounded by
	/// `handshake_timeout` ([`HANDSHAKE_TIMEOUT`] in every accept loop here;
	/// `None` or a zero budget waits unbounded, which a caller with no inline
	/// accept loop of its own may want), and overrunning it fails with
	/// [`ErrorKind::TimedOut`](crate::ErrorKind::TimedOut), which an accept loop
	/// skips like any other bad partner. Binding-internal.
	pub(crate) async fn establish_accepted<S>(
		host: Rc<HostShared>,
		transport_name: &str,
		server_designator: &str,
		stream: S,
		accepted_local_addr: &str,
		handshake_timeout: Option<Duration>,
	) -> Result<Session>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		host.guard_open()?;
		let mut plan = ffi::PancakeAcceptPlan {
			designator: core::ptr::null(),
			designator_len: 0,
			direct_addresses_hint: core::ptr::null(),
			direct_addresses_hint_len: 0,
		};
		check_host(unsafe {
			ffi::pancake_host_plan_accept(
				transport_name.as_ptr(),
				transport_name.len(),
				server_designator.as_ptr(),
				server_designator.len(),
				accepted_local_addr.as_ptr(),
				accepted_local_addr.len(),
				&mut plan,
			)
		})?;
		let designator = unsafe {
			if plan.designator_len == 0 {
				&[][..]
			} else {
				core::slice::from_raw_parts(plan.designator, plan.designator_len)
			}
		};
		let hint = unsafe {
			if plan.direct_addresses_hint_len == 0 {
				&[][..]
			} else {
				core::slice::from_raw_parts(
					plan.direct_addresses_hint,
					plan.direct_addresses_hint_len,
				)
			}
		};
		let mut ptr: *mut ffi::PancakeHostSession = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_session_open_accepted(
				host.raw(),
				transport_name.as_ptr(),
				transport_name.len(),
				designator.as_ptr(),
				designator.len(),
				hint.as_ptr(),
				hint.len(),
				&mut ptr,
			)
		})?;
		Session::owning(SessionShared::new(ptr, host, stream))
			.establish(handshake_timeout)
			.await
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

	/// Record the verbatim exporter-location bytes (from
	/// [`encode_peer_locator`](crate::encode_peer_locator))
	/// the gifter embeds when *this* connection is the exporter side of a handoff
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
	pub fn set_exporter_locator(&self, raw: Vec<u8>) -> Result<()> {
		self.shared.guard_open()?;
		check_host(unsafe {
			ffi::pancake_host_session_set_exporter_location(
				self.shared.ptr.get(),
				raw.as_ptr(),
				raw.len(),
			)
		})?;
		Ok(())
	}

	/// Who this session's partner proved itself to be during the handshake.
	///
	/// A partner's keyed `op:start-session` carries an Ed25519 signature over
	/// its own location record, and the engine verifies that signature before
	/// the session opens. So a success here always means the signature was
	/// checked, and there is no unverified answer to mistake for a verified
	/// one. The signed span covers the whole record, which is what binds
	/// [`designator`](PartnerIdentity::designator) to
	/// [`session_key`](PartnerIdentity::session_key): the partner cannot claim
	/// a designator it does not own without also owning the key.
	///
	/// That binding is how a server refuses a caller that names a locator
	/// belonging to someone else. Compare the locator the caller claims in its
	/// request against the identity this returns, and turn a mismatch away.
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
		check_host(unsafe {
			ffi::pancake_host_session_partner_identity(self.shared.ptr.get(), &mut out)
		})?;
		// Session-owned views, valid only until the session is released, so
		// every field is copied before it leaves this call.
		let (session_key, designator, locator_record) = unsafe {
			(
				crate::owned_from_view(out.session_key, out.session_key_len),
				crate::owned_from_view(out.designator, out.designator_len),
				crate::owned_from_view(out.locator_record, out.locator_record_len),
			)
		};
		let provenance = match out.provenance {
			sys::DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT => {
				DurableProvenance::AuthenticatedTransport
			}
			sys::DURABLE_PROVENANCE_DURABLE_KEY_ATTESTATION => {
				DurableProvenance::DurableKeyAttestation
			}
			_ => DurableProvenance::Unauthenticated,
		};
		Ok(PartnerIdentity {
			session_key,
			designator: String::from_utf8_lossy(&designator).into_owned(),
			locator_record,
			provenance,
		})
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
			ffi::pancake_host_session_published_ref(
				self.shared.ptr.get(),
				name.as_ptr(),
				name.len(),
				&mut reference,
			)
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
	/// exporter connection that hosts it, transparently.
	/// Listen on a promise capability this session holds (CapTP `op:listen`,
	/// ADR-0095): the returned handle settles with the promise's resolution,
	/// which may be any value, not only a capability. A re-gifted promise
	/// routes to its exporter session transparently.
	pub fn listen(&self, target: &Ref) -> RemotePromise {
		crate::promise::listen_promise(&self.shared, target)
	}

	pub fn send<T: AsSendTarget>(&self, target: T, verb: &str, args: &[Argument]) -> RemotePromise {
		crate::promise::send_promise(&self.shared, target.as_send_target(), verb, args)
	}

	/// Eventual-send `verb(args)` to `target`, await the reply, and also hand
	/// back the direct connection a three-party-handoff redeem opened to answer
	/// it.
	///
	/// When `target` answers with a `desc:handoff-give` — a rooms `introduce`,
	/// say — the host redeems it by dialing the exporter, and the reply resolves
	/// to a capability that routes over that fresh direct connection. That
	/// connection is otherwise internal. This surfaces it as
	/// [`via`](Redeemed::via), so the caller can host its own objects on the very
	/// connection the redeemed capability lives on. That is the one place a
	/// reply capability handed back to the exporter is valid, because an OCapN
	/// near export names a position on one specific connection's peer: spawn the
	/// inbox on `via` and the exporter can call it, spawn it on this session and
	/// the exporter has no route to it.
	///
	/// `via` is resolved from the reply's own token, which carries the exporter
	/// connection it lives on, rather than from watching which dial ran during
	/// the send. So it is right with several redeems in flight at once, and it
	/// names the exporter even when the redeem reused a connection an earlier
	/// one already dialed, where there is no fresh dial to observe. `via` is
	/// `None` when the reply is not a redeemed-handoff capability (an ordinary
	/// far reply) or when its exporter connection has already gone.
	///
	/// ```ignore
	/// let Redeemed { reply, via } = conn.send_redeeming(&directory, "introduce", &[nick]).await?;
	/// let member = Ref::try_from(&reply).expect("introduce answers with a capability");
	/// let hop = via.as_ref().unwrap_or(&conn);
	/// let inbox = hop.spawn(reply_behavior)?;   // hosted where the reply lives
	/// hop.send(&member, "dm", &[text, (&inbox).into()]).await?;
	/// ```
	pub async fn send_redeeming<T: AsSendTarget>(
		&self,
		target: T,
		verb: &str,
		args: &[Argument],
	) -> Result<Redeemed> {
		self.shared.guard_open()?;
		let reply = self.send(target, verb, args).await?;
		let via = match Ref::try_from(&reply) {
			Ok(capability) => self
				.shared
				.host
				.exporter_for(&capability)?
				.and_then(|home| {
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
		Ok(Redeemed { reply, via })
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
	/// Calling it without awaiting is fine, the loop runs regardless. The
	/// `Session` handle should stay alive while the loop serves: dropping it
	/// closes the connection under the partner.
	pub fn serve(&self) -> impl std::future::Future<Output = ()> {
		let handle = self.shared.take_serving();
		async move {
			if let Some(handle) = handle {
				let _ = handle.await;
			}
		}
	}

	pub(crate) fn raw_conn(&self) -> *mut ffi::PancakeHostSession {
		self.shared.raw_conn()
	}

	/// Close the session. A running [`serve`](Session::serve) completes; pending
	/// vows settle broken.
	///
	/// This closes the connection it names and nothing else: not a sibling
	/// session, and not the connections the host dialed by itself to redeem a
	/// handoff — the `via` from [`send_redeeming`](Session::send_redeeming) is
	/// one of those. [`Host::close`](crate::Host::close) is what ends those.
	///
	/// A session that had to create its own host — the ordinary
	/// [`connect`](crate::connect) with no host passed — closes that host with
	/// it, so single-session code needs no host call.
	pub fn close(&self) {
		self.shared.closing.set(true);
		self.shared.close_transport();
		// A host this session created has no other owner, so it goes too, and
		// with it every connection it dialed for redeems. A caller-supplied
		// host stays: sibling sessions on it are still running, and closing
		// their exporters from here is not this session's call to make.
		if self.owns_host {
			self.shared.host.close_host();
		}
	}
}

impl Drop for Session {
	fn drop(&mut self) {
		// A view onto a host-owned session (`Redeemed::via`) is not the
		// connection's owner, so its drop is a no-op: closing there would sever
		// the redeemed capability the caller was handed alongside it.
		if !self.owns_session {
			return;
		}
		// Close just this session (never a sibling's connection — that is the
		// host's to close, not this session's).
		self.shared.close_transport();
		// A host this session created has no other owner. Its sessions hold it
		// by `Rc` and it holds them back, so without emptying that table the
		// host, the exporters it dialed, and their sockets all outlive every
		// handle the application still has. `close` does this; a dropped
		// session has the same obligation.
		if self.owns_host {
			self.shared.host.close_host();
		}
	}
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
