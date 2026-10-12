//! Session admission over embedder-owned channels. Native provider admission
//! remains in the driver. This module owns channel transfer and handshake.
use super::*;
use crate::host::HostShared;
use crate::uri::OwnedLocator;
use tokio::io::{AsyncRead, AsyncWrite};

/// The interpretation of an accepted listener's designator, supplied by its
/// transport provider. The shared core validates it against transport metadata.
#[derive(Clone, Copy, Debug)]
pub enum ChannelDesignator<'a> {
	Address(&'a str),
	Key(&'a str),
}

/// Transport-authored facts accompanying one accepted channel. A verified key
/// is supplied only after the channel realizer has authenticated that identity.
#[derive(Clone, Copy, Debug)]
pub struct AcceptedTransport<'a> {
	pub transport: &'a str,
	pub designator: ChannelDesignator<'a>,
	pub local_address: &'a str,
	pub verified_channel_key: Option<&'a str>,
}

impl Session {
	/// Mint the dialing half over a byte channel the caller already realized
	/// for `locator`. The locator travels whole. The host retains its own dial
	/// default for the transport, so no locator policy lives here. The
	/// handshake is bounded by `handshake_timeout` ([`HANDSHAKE_TIMEOUT`] on
	/// every dial the binding performs. `None` or a zero budget waits
	/// unbounded), and overrunning it fails with
	/// [`ErrorKind::TimedOut`](crate::ErrorKind::TimedOut). Binding-internal.
	#[cfg(any(test, feature = "async"))]
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
		Self::dial_channel(
			&Host::from_shared(host),
			locator,
			crate::Channel::stream(stream),
			handshake_timeout,
			verified_channel_key,
		)
		.await
	}

	/// Admit a channel already opened for the complete locator. The core owns
	/// framing and peer validation. `verified_channel_key` is a realizer's
	/// authenticated proof, never an unchecked hint from the locator.
	pub async fn dial_channel(
		host: &Host,
		locator: &Locator,
		channel: crate::Channel,
		handshake_timeout: Option<Duration>,
		verified_channel_key: Option<&str>,
	) -> Result<Session> {
		let host = host.shared();
		let opened = (|| {
			guard_byte_fed(&host)?;
			let owned = OwnedLocator::new(locator)?;
			let mut ptr = core::ptr::null_mut();
			// SAFETY: `host.raw()` is the `GlowcapHost` handle owned by `HostShared`, proven non-null by
			// `guard_byte_fed` above; `owned.borrow_view()` is a view into `owned`, a local `OwnedLocator` that
			// outlives the call, and `ptr` is a local out-parameter the callee fills with a host-owned session handle.
			check_host(unsafe {
				ffi::glowcap_host_session_open_dialed_locator(host.raw(), owned.borrow_view()?, &mut ptr)
			})?;
			Ok(ptr)
		})();
		let ptr = match opened {
			Ok(ptr) => ptr,
			Err(primary) => {
				return Err(crate::retain_cleanup_failure(
					primary,
					channel.close().await.map_err(crate::session_shared::io_err),
				));
			}
		};
		let session = Session::owning(SessionShared::new_channel(ptr, host, channel));
		session.establish(handshake_timeout, verified_channel_key).await
	}

	/// Admit one accepted channel with the provider's identity facts. Any
	/// synchronous admission refusal still closes the transferred channel and
	/// observes its cleanup result before returning the primary error.
	pub async fn accept_channel(
		host: &Host,
		transport: AcceptedTransport<'_>,
		channel: crate::Channel,
		handshake_timeout: Option<Duration>,
	) -> Result<Session> {
		let host = host.shared();
		let opened = (|| {
			guard_byte_fed(&host)?;
			let (scheme, designator) = match transport.designator {
				ChannelDesignator::Address(value) => (sys::DESIGNATOR_SCHEME_ADDRESS, value),
				ChannelDesignator::Key(value) => (sys::DESIGNATOR_SCHEME_KEY, value),
			};
			let mut ptr = core::ptr::null_mut();
			// SAFETY: `host.raw()` is the `GlowcapHost` handle owned by `HostShared`, proven non-null by
			// `guard_byte_fed` above; `transport.transport`, `designator`, and `transport.local_address` are borrowed
			// `&str` or slices that outlive the call and are read only during it, and `ptr` is a local out-parameter
			// the callee fills with a host-owned session handle.
			check_host(unsafe {
				ffi::glowcap_host_session_open_accepted(
					host.raw(),
					transport.transport.as_ptr(),
					transport.transport.len(),
					scheme,
					designator.as_ptr(),
					designator.len(),
					transport.local_address.as_ptr(),
					transport.local_address.len(),
					&mut ptr,
				)
			})?;
			Ok(ptr)
		})();
		let ptr = match opened {
			Ok(ptr) => ptr,
			Err(primary) => {
				return Err(crate::retain_cleanup_failure(
					primary,
					channel.close().await.map_err(crate::session_shared::io_err),
				));
			}
		};
		let verified_channel_key = transport.verified_channel_key;
		let session = Session::owning(SessionShared::new_channel(ptr, host, channel));
		session.establish(handshake_timeout, verified_channel_key).await
	}

	// Drive the keyed handshake to an open session and start the serve loop,
	// abandoning the connection on any failure (release + transport close) so a
	// rude partner costs one dial or one accept, never the caller.
	//
	// The one place both halves bound that handshake. A peer that opens the
	// byte channel and then says nothing is the case no failure check can catch,
	// nothing fails, the handshake waits, so unbounded it parks the
	// dialer forever, and on the accepting side every later connection behind
	// that one client. `None` is the caller's explicit opt-in to waiting
	// without a bound, and so is a zero budget: zero is how the C ABI and the
	// sibling bindings spell "no bound", so a caller threading a configured
	// millisecond count through must not land on a deadline of right now. An
	// elapsed budget takes the same abandon path a failed handshake does:
	// dropping the handshake future drops the read half, and the teardown below
	// releases the half-built session and closes the transport.
	#[cfg(any(test, feature = "async"))]
	async fn establish(
		self,
		handshake_timeout: Option<Duration>,
		verified_channel_key: Option<&str>,
	) -> Result<Session> {
		// Until authentication completes, cancellation abandons the channel.
		// A normal Session drop drains terminal frames; that cannot complete
		// when the channel itself is still opening.
		struct Opening(Option<Rc<SessionShared>>);
		impl Drop for Opening {
			fn drop(&mut self) {
				if let Some(shared) = self.0.take() {
					shared.close_transport();
				}
			}
		}
		let mut opening = Opening(Some(Rc::clone(&self.shared)));
		let handshake = async {
			// Proof must be admitted before the first partner byte. Its refusal
			// uses the same channel-retirement path as a failed handshake.
			if let Some(key) = verified_channel_key {
				self.bind_verified_channel_key(key)?;
			}
			let driving = crate::pump::run_handshake(&self.shared);
			tokio::pin!(driving);
			// Close must interrupt an opening transport as well as a silent
			// peer. Neither can deliver the bytes a pending flush waits for.
			loop {
				let activity = self.shared.host.close_activity();
				tokio::pin!(activity);
				activity.as_mut().enable();
				if self.shared.closing() {
					return Err(Error::from_code(sys::ERR_CLOSED));
				}
				tokio::select! {
					biased;
					() = activity.as_mut() => {},
					outcome = &mut driving => return outcome,
				}
			}
		};
		let outcome = match handshake_timeout.filter(|budget| !budget.is_zero()) {
			Some(budget) => match crate::execution::timeout(budget, handshake).await {
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
				opening.0.take();
				self.shared.spawn_serve();
				Ok(self)
			}
			Err(error) => {
				opening.0.take();
				// Explicit rather than left to the `Drop` behind it: a
				// half-built session is abandoned on the same terms whatever
				// this handle's ownership disposition is. `close_transport` is
				// idempotent (`released`), so that drop is a no-op.
				self.shared.close_transport();
				let cleanup = self.closed().await;
				Err(crate::retain_cleanup_failure(error, cleanup))
			}
		}
	}

	/// Accept a partner over a byte channel the caller realized itself: a
	/// WebSocket a page opened, a pipe, anything that reads and writes bytes.
	/// The session is one of `host`'s, sharing its identity and directory. It
	/// is accepted as if over `transport` at `server_designator` (a
	/// `host:port` for `tcp`), the address the partner's hello names, and
	/// `accepted_local_addr` is what the channel reports as its local end.
	/// The keyed handshake is bounded by `handshake_timeout`. The session is
	/// served once it completes, and closing the returned handle ends it.
	#[cfg(feature = "async")]
	pub async fn accept_over<S>(
		host: &Host,
		transport: &str,
		server_designator: &str,
		accepted_local_addr: &str,
		stream: S,
		handshake_timeout: Option<Duration>,
	) -> Result<Session>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		Self::accept_channel(
			host,
			AcceptedTransport {
				transport,
				designator: ChannelDesignator::Address(server_designator),
				local_address: accepted_local_addr,
				verified_channel_key: None,
			},
			crate::Channel::stream(stream),
			handshake_timeout,
		)
		.await
	}

	/// Dial a partner over a byte channel the caller realized itself for
	/// `locator`: the mirror of [`Session::accept_over`]. The session is one
	/// of `host`'s. The handshake is bounded by `handshake_timeout`.
	#[cfg(feature = "async")]
	pub async fn dial_over<S>(
		host: &Host,
		locator: &crate::Locator,
		stream: S,
		handshake_timeout: Option<Duration>,
	) -> Result<Session>
	where
		S: AsyncRead + AsyncWrite + Unpin + 'static,
	{
		Self::establish_dialed_locator(host.shared(), locator, stream, handshake_timeout, None).await
	}
}

fn guard_byte_fed(host: &HostShared) -> Result<()> {
	host.guard_handle()?;
	#[cfg(not(target_arch = "wasm32"))]
	if host.driver_loop().is_some() {
		return Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			"a driver-owned Host cannot adopt an embedder channel".into(),
		));
	}
	Ok(())
}
