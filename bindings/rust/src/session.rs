//! The application surface over the byte-fed host (`libpancake_driver`,
//! ADR-0072): [`Session`] and its verbs (`fetch`/`send`/`tell`/`spawn`/
//! `publish`/`enliven`/`serve`/`close`), plus mint/handshake (`establish_*`).
//! The dial executor (plan + channel open + [`connect`]) lives in
//! [`crate::dial`]; [`Server`] / [`listen`] live in [`crate::listen`]. The
//! [`RemotePromise`] handle lives in [`crate::promise`]. CapTP action
//! decode+execute lives in [`crate::action`].
//! Per-connection [`Ref`] / [`Caretaker`] / [`SessionShared`] live in [`crate::session_shared`].
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
use crate::session_shared::{Caretaker, Ref, SessionShared};
use crate::sys::driver as ffi;
use crate::trampoline::outcome_behavior;
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
	// Whether dropping this handle tears the connection down. True for the
	// handle that dialed or accepted the session and is its owner. False for a
	// view onto a session the host owns and keeps alive on its own account —
	// an exporter connection a redeem dialed, handed out by
	// [`Session::send_redeeming`]. Closing there would sever the very
	// capability the caller asked for.
	closes_on_drop: bool,
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
	/// depends on it. Calling [`close`](Session::close) on it is still an
	/// explicit close, and closes it.
	pub via: Option<Session>,
}

impl Session {
	// The owning handle over a session this side dialed or accepted: dropping
	// it closes the connection.
	pub(crate) fn owning(shared: Rc<SessionShared>) -> Session {
		Session {
			shared,
			closes_on_drop: true,
		}
	}

	// A view onto a session the host owns, for a caller that needs to spawn and
	// send on it without taking its life in hand.
	pub(crate) fn view(shared: Rc<SessionShared>) -> Session {
		Session {
			shared,
			closes_on_drop: false,
		}
	}

	/// Mint the dialing half from an already-parsed locator (`transport` +
	/// `designator`), matching a DIAL action's pieces. The handshake is bounded
	/// by `handshake_timeout` ([`HANDSHAKE_TIMEOUT`] on every dial the binding
	/// performs; `None` waits unbounded), and overrunning it fails with
	/// [`ErrorKind::TimedOut`](crate::ErrorKind::TimedOut). Binding-internal.
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
	/// `None` waits unbounded, which a caller with no inline accept loop of its
	/// own may want), and overrunning it fails with
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
	// without a bound. An elapsed budget takes the same abandon path a failed
	// handshake does: dropping the handshake future drops the read half, and
	// the teardown below releases the half-built session and closes the
	// transport.
	async fn establish(self, handshake_timeout: Option<Duration>) -> Result<Session> {
		let handshake = crate::pump::run_handshake(&self.shared);
		let outcome = match handshake_timeout {
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
				self.shared.close_transport();
				// Skip the Drop teardown; close_transport already ran.
				Err(error)
			}
		}
	}

	/// The session's shared [`Host`], its retained identity and gift registry.
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

	/// Spawn a local actor and return a capability to it. Pass the returned `Ref`
	/// as a `send` argument to hand a partner a callback. The position comes from
	/// the session's one export allocator, so it can never alias a bootstrap or
	/// resolver export. Callable from inside a served turn (a factory's `create`
	/// minting the task it replies with).
	pub async fn spawn(
		&self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		self.shared.spawn_actor(outcome_behavior(behavior))
	}

	/// Publish an actor so a partner can [`fetch`](Session::fetch) it by `name`
	/// (a swiss-number). Returns a capability to it.
	pub async fn publish(
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
	pub async fn caretaker(&self, target: &Ref) -> Result<Caretaker> {
		crate::trampoline::caretaker_proxy(&self.shared, target)
	}

	/// Wrap `target` (local or far) in an attenuator (ADR-0064): a proxy that
	/// forwards only the calls whose verb is in `verbs` and breaks every other
	/// with `Attenuated`. Returns the proxy capability to hand a partner. `target`
	/// may be a wire-imported capability, so this narrows authority you hold.
	pub async fn attenuate(&self, target: &Ref, verbs: &[&str]) -> Result<Ref> {
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

	/// Enliven a sturdyref against this session (ADR-0012): bring the durable
	/// `(peer, swissnum)` to life as a live [`Ref`]. Parses `sturdyref` for its
	/// swissnum, then fetches it through the host's dedup cache — a repeat
	/// enliven of the same swissnum on this session short-circuits with no wire
	/// traffic (its completion is queued before the minting call returns). The
	/// session must already be open to the sturdyref's peer; the sans-io core
	/// tracks no remote locator and never dials. Rejects with the typed break
	/// when the partner refuses, and with a broken error on a non-capability
	/// fulfillment.
	pub async fn enliven(&self, sturdyref: &str) -> Result<Ref> {
		let swissnum = crate::uri::parse_sturdyref(sturdyref)?
			.swissnum
			.into_bytes();
		crate::promise::fetch_like(
			&self.shared,
			&swissnum,
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
	/// let inbox = hop.spawn(reply_behavior).await?;   // hosted where the reply lives
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
				.map(Session::view),
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

	// The DIAL arm marks the exporter connection it dialed so `close()` can
	// sweep it, and reads the raw conn for `pancake_host_dialed`.
	// Binding-internal.
	pub(crate) fn mark_host_dialed(&self) {
		self.shared.mark_host_dialed();
	}

	pub(crate) fn raw_conn(&self) -> *mut ffi::PancakeHostSession {
		self.shared.raw_conn()
	}

	/// Close the session and every exporter connection its host dialed for
	/// handoffs. A running [`serve`](Session::serve) completes; pending vows
	/// settle broken.
	pub fn close(&self) {
		self.shared.closing.set(true);
		self.shared.host.close_exporters();
		self.shared.close_transport();
	}
}

impl Drop for Session {
	fn drop(&mut self) {
		// A view onto a host-owned session (`Redeemed::via`) is not the
		// connection's owner, so its drop is a no-op: closing there would sever
		// the redeemed capability the caller was handed alongside it.
		if !self.closes_on_drop {
			return;
		}
		// Close just this session (never the host's other exporters — a
		// dialed exporter's own teardown must not sweep its siblings).
		self.shared.close_transport();
	}
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
