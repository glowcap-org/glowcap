//! Explicit byte-fed transport composition.
//!
//! A [`Connector`] belongs to a transport module. It interprets that
//! transport's locators, opens the byte channel, and establishes the CapTP
//! session on a caller-owned [`Host`](crate::Host). Generic dial code only
//! verifies that the connector advertises the requested symbol and invokes it.

use core::future::Future;
use core::pin::Pin;
use core::task::{Context, Poll};
use std::rc::Rc;
use std::time::Duration;

use crate::{sys, Error, Host, Locator, Result, Session};

/// Borrowed, transport-authored policy for one connection operation.
///
/// Transport modules implement this over their typed option values. The
/// generic Runtime only verifies the advertised symbol and borrows the ABI
/// payload for the duration of the connection future.
pub trait TransportOperationOptions: core::fmt::Debug {
	fn transports(&self) -> &'static [&'static str];
	fn as_bytes(&self) -> &[u8];

	fn supports(&self, transport: &str) -> bool {
		self.transports().iter().any(|candidate| *candidate == transport)
	}
}

/// Why the Host is opening a byte channel. Pending dials include handoff
/// redemption and select-or-dial application calls. The introducer, when
/// present, is the session that supplied the oldest remaining give, captured
/// before the connector starts. Its view does not keep a closed connection
/// open and dropping it does not close the introducing connection.
///
/// Applications can resolve signaling context from this exact session. The
/// binding neither chooses an application route nor serializes introductions.
pub enum DialOrigin {
	Explicit,
	Pending { introducer: Option<Session> },
}

pub type ConnectFuture<'a> = Pin<Box<dyn Future<Output = Result<Session>> + 'a>>;
type ConnectFn = dyn for<'a> Fn(Host, &'a Locator, DialOrigin, Option<&'a [u8]>, Option<Duration>) -> ConnectFuture<'a>;

struct ContainedConnectFuture<'a> {
	inner: ConnectFuture<'a>,
}

impl Future for ContainedConnectFuture<'_> {
	type Output = Result<Session>;

	fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
		match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.inner.as_mut().poll(cx))) {
			Ok(outcome) => outcome,
			Err(payload) => Poll::Ready(Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!(
					"connector callback panicked: {}",
					crate::panic_message(payload.as_ref())
				),
			))),
		}
	}
}

/// A configured byte-channel connector supplied explicitly by an embedder.
///
/// Native applications normally use a transport module's
/// `driver_loop::Provider`. Connectors are for runtimes that
/// own channel establishment themselves, including browser-style embeddings.
#[derive(Clone)]
pub struct Connector {
	transports: &'static [&'static str],
	connect: Rc<ConnectFn>,
}

impl Connector {
	/// Construct a connector for a static transport-symbol inventory.
	/// Transport modules own this constructor call; generic application code
	/// normally uses their `connector` factory.
	pub fn new<F>(transports: &'static [&'static str], connect: F) -> Result<Self>
	where
		F: for<'a> Fn(Host, &'a Locator, DialOrigin, Option<&'a [u8]>, Option<Duration>) -> ConnectFuture<'a> + 'static,
	{
		if transports.is_empty() {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"a connector must advertise at least one transport".to_string(),
			));
		}
		Ok(Self {
			transports,
			connect: Rc::new(connect),
		})
	}

	pub fn transports(&self) -> &'static [&'static str] {
		self.transports
	}

	pub(crate) fn supports(&self, transport: &str) -> bool {
		self.transports.iter().any(|candidate| *candidate == transport)
	}

	pub(crate) fn same_instance(&self, other: &Self) -> bool {
		Rc::ptr_eq(&self.connect, &other.connect)
	}

	pub(crate) async fn connect<'a>(
		&self,
		host: Host,
		locator: &'a Locator,
		origin: DialOrigin,
		transport_options: Option<&'a [u8]>,
		handshake_timeout: Option<Duration>,
	) -> Result<Session> {
		let future = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
			(self.connect)(host, locator, origin, transport_options, handshake_timeout)
		}))
		.map_err(|payload| {
			Error::with_detail(
				sys::ERR_INTERNAL,
				format!(
					"connector callback panicked: {}",
					crate::panic_message(payload.as_ref())
				),
			)
		})?;
		ContainedConnectFuture { inner: future }.await
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn empty_transport_inventory_is_a_typed_refusal() {
		let result = Connector::new(&[], |_host, _locator, _origin, _options, _timeout| {
			Box::pin(async { Err(Error::with_detail(sys::ERR_INTERNAL, "unused".to_string())) })
		});
		let error = result.err().expect("empty inventory is refused");
		assert_eq!(error.code(), sys::ERR_INVALID_ARGUMENT);
	}

	#[cfg(feature = "async")]
	#[tokio::test(flavor = "current_thread")]
	async fn panicking_connector_future_is_a_typed_refusal() {
		let connector = Connector::new(&["test"], |_host, _locator, _origin, _options, _timeout| {
			Box::pin(async { panic!("connector exploded") })
		})
		.unwrap();
		let host = Host::with_codec(crate::Codec::Syrup).unwrap();
		let locator = crate::uri::parse_locator("ocapn://example.test?transport=test").unwrap();
		let error = connector
			.connect(host, &locator, DialOrigin::Explicit, None, None)
			.await
			.err()
			.expect("panic is contained");
		assert_eq!(error.code(), sys::ERR_INTERNAL);
		assert!(error.to_string().contains("connector exploded"));
	}
}
