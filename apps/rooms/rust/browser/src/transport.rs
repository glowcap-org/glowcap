//! Browser Runtime composition for the Rooms web front. The deployment owns
//! forwarding authority. Locator-authored relay routes stay with the relay
//! transport, and the directory owner selects WebRTC signaling.
use crate::{ice, signaling};
use glowcap::{Connector, DialOrigin, Host, Locator, Runtime, RuntimeConfig, Session, browser};
use rooms_application::web_relay;
use rooms_glowcap::client::{Deadline, Tasks, directory::signaling::Route};
use std::{io, time::Duration};
use web_sys::Url;

/// A trusted Rooms web deployment. In particular, its native iroh handshake
/// authenticates the remote node before forwarding opaque bytes to this page.
/// Never construct this from a peer-supplied locator hint. The ordinary page
/// uses deployment(). Explicit construction is for an embedding that chooses
/// its web front as part of application configuration.
pub struct WebFront(String);
impl WebFront {
	pub fn new(page_url: &str) -> Result<Self, io::Error> {
		let url = Url::new(page_url).map_err(|_| invalid("Rooms page URL is invalid"))?;
		let scheme = match url.protocol().as_str() {
			"http:" => "ws:",
			"https:" => "wss:",
			_ => return Err(invalid("Rooms web forwarding requires an HTTP or HTTPS page")),
		};
		if !url.username().is_empty() || !url.password().is_empty() {
			return Err(invalid("Rooms web forwarding does not accept URL credentials"));
		}
		url.set_protocol(scheme);
		url.set_pathname("/relay");
		url.set_search("");
		url.set_hash("");
		Ok(Self(url.href()))
	}
	pub fn deployment() -> Result<Self, io::Error> {
		Self::new(&page_url()?.href())
	}
	pub(crate) fn relay_route(&self, host: &Host) -> glowcap::Result<(Locator, String)> {
		let locator = Locator::bare(glowcap::TRANSPORT_NOISE_RELAY, &host.designator()?)
			.with_hint("rendezvous-relay", glowcap::HintValue::String(self.0.clone()));
		let register = Url::new(&self.0).map_err(|_| invalid("Rooms relay URL is invalid"))?;
		register.set_pathname("/register");
		Ok((locator, register.href()))
	}
	fn connector(self) -> glowcap::Result<Connector> {
		Connector::new(
			&[
				glowcap::TRANSPORT_TCP,
				glowcap::TRANSPORT_KEYED_TCP,
				glowcap::TRANSPORT_NOISE_TCP,
				glowcap::TRANSPORT_IROH,
				glowcap::TRANSPORT_ONION,
			],
			move |host, locator, _origin, options, timeout| {
				let endpoint = self.target(locator);
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
	fn target(&self, locator: &Locator) -> Result<String, io::Error> {
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
		let target = glowcap::format_locator_uri(locator).map_err(io::Error::other)?;
		if target.len() > web_relay::MAX_TARGET_BYTES {
			return Err(invalid("Rooms web forwarding target exceeds its byte limit"));
		}
		// The full locator carries profile and routing hints. The front's
		// admission policy is the authority for which native targets it serves.
		let encoded: String = js_sys::encode_uri_component(&target).into();
		Ok(format!("{}?target={encoded}", self.0))
	}
}

/// Create the page's one Runtime around its already selected Host identity.
/// Directory selection reads the application's held clients. ICE remains an
/// application-owned resource whose close is observed at page retirement.
pub async fn open<D, F>(host: &Host, front: WebFront, select: F, ice: ice::Source) -> glowcap::Result<Runtime>
where
	D: Deadline + Tasks + Clone + 'static,
	F: Fn(&glowcap::Locator, &DialOrigin) -> Result<Route<D>, String> + 'static,
{
	let connectors = [
		front.connector()?,
		browser::relay::connector()?,
		signaling::connector(select, ice)?,
	];
	Runtime::open(RuntimeConfig::connectors(connectors).adopt_host(host)).await
}
fn invalid(reason: &str) -> io::Error {
	io::Error::new(io::ErrorKind::InvalidInput, reason)
}

pub(crate) fn page_url() -> Result<Url, io::Error> {
	let location = js_sys::Reflect::get(&js_sys::global(), &"location".into())
		.map_err(|_| invalid("the browser has no page location"))?;
	let href = js_sys::Reflect::get(&location, &"href".into())
		.ok()
		.and_then(|value| value.as_string())
		.ok_or_else(|| invalid("the browser has no page URL"))?;
	Url::new(&href).map_err(|_| invalid("Rooms page URL is invalid"))
}
