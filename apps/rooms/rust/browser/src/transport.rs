//! Browser Runtime composition for the Rooms web front. The deployment owns
//! forwarding authority. Locator-authored relay routes stay with the relay
//! transport, and the directory owner selects WebRTC signaling.
use crate::{ice, signaling};
use glowcap::{Connector, DialOrigin, Host, Locator, Runtime, RuntimeConfig, Session, browser};
use rooms_application::web_relay;
use rooms_glowcap::client::{Deadline, Tasks, directory::signaling::Route};
use std::{io, time::Duration};
use web_sys::Url;

/// A trusted Rooms web deployment. In particular, its host iroh handshake
/// authenticates the remote node before forwarding opaque bytes to this page.
/// Never construct this from a peer-supplied locator hint. The page builds it
/// from the Rooms server in use: the one this device chose, else the one that
/// served the page.
///
/// Its routes sit under `base`, a URL ending in `/`: the base the page's files
/// are served from, or the base of a Rooms server this device chose. A page
/// from a static host with none chosen has no front: only an address that
/// carries its own WebSocket route dials, and nothing reaches this browser
/// through a relay.
#[derive(Clone)]
pub struct WebFront {
	/// The WebSocket this front dials through: `relay` under the server's base.
	relay: String,
	/// The WebSocket a browser registers at to be reached: `register`, beside
	/// `relay` under the same base.
	register: String,
	/// The ICE policy for WebRTC direct messages: `ice` under the same base,
	/// read over HTTP.
	ice: String,
}
impl WebFront {
	pub fn new(base: &str) -> Result<Self, io::Error> {
		if !Url::new(base).is_ok_and(|base| base.pathname().ends_with('/')) {
			return Err(invalid("Rooms relay base must be a URL ending in /"));
		}
		// Resolving a relative path drops the base's query and fragment.
		let url = Url::new_with_base("relay", base).map_err(|_| invalid("Rooms relay URL is invalid"))?;
		let scheme = match url.protocol().as_str() {
			"http:" => "ws:",
			"https:" => "wss:",
			_ => return Err(invalid("Rooms web forwarding requires an HTTP or HTTPS relay")),
		};
		if !url.username().is_empty() || !url.password().is_empty() {
			return Err(invalid("Rooms web forwarding does not accept URL credentials"));
		}
		url.set_protocol(scheme);
		// Both sit under the base beside `relay`, so a base this constructor
		// accepted resolves them, and no reader of them can fail.
		let register = Url::new_with_base("register", &url.href())
			.map_err(|_| invalid("Rooms relay URL is invalid"))?
			.href();
		let ice = Url::new_with_base("ice", base)
			.map_err(|_| invalid("Rooms server URL is invalid"))?
			.href();
		Ok(Self {
			relay: url.href(),
			register,
			ice,
		})
	}
	pub(crate) fn ice(&self) -> &str {
		&self.ice
	}
	pub(crate) fn relay_route(&self, host: &Host) -> glowcap::Result<(Locator, String)> {
		let locator = Locator::bare(glowcap::TRANSPORT_NOISE_RELAY, &host.designator()?)
			.with_hint("rendezvous-relay", glowcap::HintValue::String(self.relay.clone()));
		Ok((locator, self.register.clone()))
	}
	fn relay_target(&self, target: &str) -> String {
		// The full locator carries profile and routing hints. The front's
		// admission policy is the authority for which host targets it serves.
		let encoded: String = js_sys::encode_uri_component(target).into();
		format!("{}?target={encoded}", self.relay)
	}
}

/// The refusal for a reach that needs a relay on a page with no Rooms server:
/// a typed line, so the page can ask for a server instead of showing it.
pub(crate) fn no_server() -> String {
	rooms_application::failure::FailureCode::NoServer.line("no server is chosen and none sent this page")
}

fn connector(front: Option<WebFront>) -> glowcap::Result<Connector> {
	Connector::new(
		&[
			glowcap::TRANSPORT_TCP,
			glowcap::TRANSPORT_KEYED_TCP,
			glowcap::TRANSPORT_NOISE_TCP,
			glowcap::TRANSPORT_IROH,
			glowcap::TRANSPORT_ONION,
		],
		move |host, locator, _origin, options, timeout| {
			let endpoint = target(front.as_ref(), locator);
			Box::pin(async move {
				if options.is_some() {
					return Err(invalid("Rooms web forwarding has no per-operation byte options").into());
				}
				let timeout = timeout
					.filter(|budget| !budget.is_zero())
					.ok_or_else(|| invalid("Rooms web forwarding requires a finite handshake budget"))?;
				let iroh = locator.transport == glowcap::TRANSPORT_IROH;
				let timeout = if iroh {
					timeout
						.checked_add(Duration::from_millis(web_relay::IROH_DIAL_TIMEOUT_MS.into()))
						.ok_or_else(|| invalid("Rooms web forwarding deadline overflow"))?
				} else {
					timeout
				};
				let channel = browser::open_websocket(&endpoint?)?;
				// Only the explicitly trusted front's iroh QUIC leg proves a key.
				// Onion names an address; TCP and relay bytes supply no such proof.
				Session::dial_channel(
					&host,
					locator,
					channel,
					Some(timeout),
					iroh.then_some(locator.designator.as_str()),
				)
				.await
			})
		},
	)
}
fn target(front: Option<&WebFront>, locator: &Locator) -> Result<String, io::Error> {
	if let Some(advice) = locator.hints.get(rooms_application::web_channel::HINT) {
		if locator.transport != glowcap::TRANSPORT_TCP {
			return Err(invalid("WebSocket byte-channel advice requires cleartext TCP"));
		}
		let glowcap::HintValue::String(endpoint) = advice else {
			return Err(invalid("WebSocket byte-channel advice must be a URL string"));
		};
		rooms_application::web_channel::endpoint(endpoint).map_err(invalid)?;
		return Ok(endpoint.clone());
	}
	let front = front.ok_or_else(|| invalid(&no_server()))?;
	let target = glowcap::format_locator_uri(locator).map_err(io::Error::other)?;
	if target.len() > web_relay::MAX_TARGET_BYTES {
		return Err(invalid("Rooms web forwarding target exceeds its byte limit"));
	}
	Ok(front.relay_target(&target))
}

/// Create the page's one Runtime around its already selected Host identity.
/// Directory selection reads the application's held clients. ICE remains an
/// application-owned resource whose close is observed at page retirement.
pub async fn open<D, F>(host: &Host, front: Option<WebFront>, select: F, ice: ice::Source) -> glowcap::Result<Runtime>
where
	D: Deadline + Tasks + Clone + 'static,
	F: Fn(&glowcap::Locator, &DialOrigin) -> Result<Route<D>, String> + 'static,
{
	let connectors = [
		connector(front)?,
		browser::relay::connector()?,
		signaling::connector(select, ice)?,
	];
	Runtime::open(RuntimeConfig::connectors(connectors).adopt_host(host)).await
}
fn invalid(reason: &str) -> io::Error {
	io::Error::new(io::ErrorKind::InvalidInput, reason)
}
