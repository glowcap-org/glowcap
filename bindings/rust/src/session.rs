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

use tokio::io::{AsyncRead, AsyncWrite};

use crate::host::{check_host, Host, HostShared};
use crate::session_shared::{Caretaker, Ref, SessionShared};
use crate::sys::driver as ffi;
use crate::trampoline::outcome_behavior;
use crate::{Argument, Result};

use crate::promise::{AsSendTarget, RemotePromise};

pub(crate) use crate::session_shared::io_err;

/// A live CapTP session with one OCapN partner — the one object an application
/// holds, over one byte-fed `PancakeHostSession` the shared [`Host`] minted.
/// `!Send` by construction; use it on a single task inside a `LocalSet`.
/// Dropping the handle closes the session.
pub struct Session {
	shared: Rc<SessionShared>,
}

impl Session {
	/// Mint the dialing half from an already-parsed locator (`transport` +
	/// `designator`), matching a DIAL action's pieces. Binding-internal.
	pub(crate) async fn establish_dialed_locator<S>(
		host: Rc<HostShared>,
		transport: &str,
		designator: &str,
		stream: S,
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
		Session {
			shared: SessionShared::new(ptr, host, stream),
		}
		.establish()
		.await
	}

	/// Mint the accepting half over a connection the caller's own listener
	/// produced: the keyed op:start-session signs the listener's own
	/// `transport_name`/`designator` — the address a partner can actually dial,
	/// and the locator a give made on this host names as the exporter location.
	/// Every host-wide giftable is published on the new session before the
	/// open returns, so a dialer's pipelined fetch finds it. Binding-internal.
	pub(crate) async fn establish_accepted<S>(
		host: Rc<HostShared>,
		transport_name: &str,
		designator: &str,
		stream: S,
		direct_addresses_hint: &str,
	) -> Result<Session>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		let mut ptr: *mut ffi::PancakeHostSession = core::ptr::null_mut();
		check_host(unsafe {
			ffi::pancake_host_session_open_accepted(
				host.raw(),
				transport_name.as_ptr(),
				transport_name.len(),
				designator.as_ptr(),
				designator.len(),
				direct_addresses_hint.as_ptr(),
				direct_addresses_hint.len(),
				&mut ptr,
			)
		})?;
		Session {
			shared: SessionShared::new(ptr, host, stream),
		}
		.establish()
		.await
	}

	// Drive the keyed handshake to an open session and start the serve loop,
	// abandoning the connection on any failure (release + transport close) so a
	// rude partner costs one accept, never the listener.
	async fn establish(self) -> Result<Session> {
		match crate::pump::run_handshake(&self.shared).await {
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
	pub fn set_exporter_locator(&self, raw: Vec<u8>) {
		if self.shared.guard_open().is_err() {
			return;
		}
		let _ = check_host(unsafe {
			ffi::pancake_host_session_set_exporter_location(
				self.shared.ptr.get(),
				raw.as_ptr(),
				raw.len(),
			)
		});
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
		// Close just this session (never the host's other exporters — a
		// dialed exporter's own teardown must not sweep its siblings).
		self.shared.close_transport();
	}
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
