//! Browser realization of keyed-relay and noise-relay. Locator hints select
//! the rendezvous endpoint; the Host owns framing, Noise and peer admission.
use crate::{abi_constants::*, AcceptedTransport, ChannelDesignator, Connector, Error, Host, Locator, Result, Session};
use std::time::Duration;
use web_sys::Url;

/// One idle relay seat. Readiness observes the WebSocket upgrade, while
/// incoming() waits for the caller's first bytes without consuming or copying
/// them. The peer handshake deadline starts only after that idle wait.
pub struct Registration {
	host: Host,
	locator: Locator,
	channel: crate::Channel,
	shared: std::rc::Rc<super::Shared>,
}
impl Registration {
	pub fn open(host: &Host, locator: &Locator, registration_url: &str) -> Result<Self> {
		route(locator)?;
		if host.designator()? != locator.designator {
			return Err(invalid(
				"relay registration must name the accepting Host's public identity",
			));
		}
		let endpoint = Route::parse(registration_url)?;
		let socket =
			web_sys::WebSocket::new(&endpoint.append("id", &locator.designator)).map_err(super::socket::js_error)?;
		let shared = super::Shared::new(super::socket::Socket::WebSocket(socket));
		let close = super::io::Closer::new(shared.clone());
		let channel = crate::Channel::byte_chunks(
			super::io::Reader(shared.clone()),
			super::io::StreamWriter::new(shared.clone()),
			close,
		);
		Ok(Self {
			host: host.clone(),
			locator: locator.clone(),
			channel,
			shared,
		})
	}
	/// The application supplies the finite opening deadline and keeps custody
	/// of this registration if it cancels the readiness observation.
	pub async fn ready(&self) -> Result<()> {
		std::future::poll_fn(|cx| super::io::ready(&self.shared, cx)).await?;
		Ok(())
	}
	pub async fn incoming(&self) -> Result<()> {
		std::future::poll_fn(|cx| {
			use std::{io, task::Poll};
			let mut state = self.shared.state.borrow_mut();
			state.result()?;
			if !state.queue.is_empty() {
				return Poll::Ready(Ok(()));
			}
			if state.closed || state.closing {
				return Poll::Ready(Err(io::Error::new(
					io::ErrorKind::UnexpectedEof,
					"relay registration closed",
				)));
			}
			state.reader = Some(cx.waker().clone());
			Poll::Pending
		})
		.await?;
		Ok(())
	}
	/// Transfer the seat to the Host's bounded handshake and close custody.
	/// Call incoming() first to exclude the idle registration from this budget.
	pub async fn accept(self, handshake: Duration) -> Result<Session> {
		if handshake.is_zero() {
			self.channel.close().await?;
			return Err(invalid("browser relay acceptance requires a finite handshake budget"));
		}
		Session::accept_channel(
			&self.host,
			AcceptedTransport {
				transport: &self.locator.transport,
				designator: ChannelDesignator::Key(&self.locator.designator),
				local_address: "",
				verified_channel_key: None,
			},
			self.channel,
			Some(handshake),
		)
		.await
	}
	pub async fn close(self) -> Result<()> {
		self.channel.close().await?;
		Ok(())
	}
}

/// Compose both relay profiles without linking a native transport archive.
pub fn connector() -> Result<Connector> {
	Connector::new(
		&[TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY],
		|host, locator, _origin, options, timeout| {
			Box::pin(async move {
				if options.is_some() {
					return Err(invalid("browser relay has no per-operation byte options"));
				}
				let channel = super::open_websocket(&dial_url(locator)?)?;
				Session::dial_channel(&host, locator, channel, timeout, None).await
			})
		},
	)
}

/// Validate a relay locator and render its rendezvous URL without opening I/O.
pub fn dial_url(locator: &Locator) -> Result<String> {
	Ok(route(locator)?.append("rendezvous", &locator.designator))
}

/// Hold one registration until a caller pairs with it, then accept that
/// session. The application bounds and replenishes its registration seats.
/// The supplied locator is this Host's public identity and relay profile;
/// registration_url names the relay's registration endpoint, before `?id=`.
/// Cancellation retires the channel through the Host's normal close custody.
pub async fn accept(host: &Host, locator: &Locator, registration_url: &str, handshake: Duration) -> Result<Session> {
	if handshake.is_zero() {
		return Err(invalid("browser relay acceptance requires a finite handshake budget"));
	}
	Registration::open(host, locator, registration_url)?
		.accept(handshake)
		.await
}

fn route(locator: &Locator) -> Result<Route<'_>> {
	if !matches!(
		locator.transport.as_str(),
		TRANSPORT_KEYED_RELAY | TRANSPORT_NOISE_RELAY
	) {
		return Err(invalid("browser relay requires keyed-relay or noise-relay"));
	}
	if locator.designator.len() != 64
		|| !locator
			.designator
			.bytes()
			.all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
	{
		return Err(invalid("relay designator must be 64 lowercase hexadecimal characters"));
	}
	Route::parse(locator.require_string_hint("rendezvous-relay")?)
}

/// URL interpretation belongs to the browser. Before invoking it, bound the
/// untrusted hint and refuse controls, malformed escapes and reserved query
/// names, matching the native relay's admission contract. Keep the admitted
/// input when appending the relay-owned query rather than rebuilding its path.
struct Route<'a>(&'a str);
impl<'a> Route<'a> {
	fn parse(input: &'a str) -> Result<Self> {
		if input.is_empty()
			|| input.len() > RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES
			|| !input.bytes().all(|b| (0x21..=0x7e).contains(&b))
		{
			return Err(invalid("relay endpoint must be bounded visible ASCII URI bytes"));
		}
		let mut bytes = input.bytes();
		while let Some(byte) = bytes.next() {
			if byte == b'%'
				&& !(bytes.next().is_some_and(|b| b.is_ascii_hexdigit())
					&& bytes.next().is_some_and(|b| b.is_ascii_hexdigit()))
			{
				return Err(invalid("relay endpoint carries malformed percent encoding"));
			}
		}
		let url = Url::new(input).map_err(|_| invalid("relay endpoint must be an absolute WebSocket URL"))?;
		if !matches!(url.protocol().as_str(), "ws:" | "wss:")
			|| !url.username().is_empty()
			|| !url.password().is_empty()
			|| input.contains('#')
			|| url.port() == "0"
		{
			return Err(invalid(
				"relay endpoint requires ws or wss without credentials, fragments or port zero",
			));
		}
		let host = url.hostname();
		if !host.starts_with('[')
			&& !host.split('.').all(|label| {
				!label.is_empty()
					&& label.len() <= 63
					&& label.as_bytes()[0].is_ascii_alphanumeric()
					&& label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
					&& label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
			}) {
			return Err(invalid("relay endpoint carries an invalid host name"));
		}
		if let Some((_, query)) = input.split_once('?') {
			for field in query.split('&') {
				let name = field.split_once('=').map_or(field, |(name, _)| name);
				if encoded_equals(name, b"rendezvous") || encoded_equals(name, b"id") {
					return Err(invalid(
						"relay endpoint reserves the rendezvous and id query parameters",
					));
				}
			}
		}
		Ok(Self(input))
	}
	fn append(&self, name: &str, designator: &str) -> String {
		format!(
			"{}{}{name}={designator}",
			self.0,
			if self.0.contains('?') { '&' } else { '?' }
		)
	}
}

fn encoded_equals(input: &str, expected: &[u8]) -> bool {
	let mut bytes = input.bytes();
	for expected in expected {
		let byte = match bytes.next() {
			Some(b'%') => {
				let pair = [
					bytes.next().expect("validated escape"),
					bytes.next().expect("validated escape"),
				];
				u8::from_str_radix(std::str::from_utf8(&pair).expect("ASCII escape"), 16).expect("validated escape")
			}
			Some(byte) => byte,
			None => return false,
		};
		if byte != *expected {
			return false;
		}
	}
	bytes.next().is_none()
}
fn invalid(message: &str) -> Error {
	Error::with_detail(crate::sys::ERR_INVALID_ARGUMENT, message.into())
}
