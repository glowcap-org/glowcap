//! Deployment-owned ICE configuration. One source coalesces concurrent reads
//! but never caches credentials across completed attempts. Own and close it
//! with the browser application, before retiring its LocalSet.
mod fetch;
mod request;

use rooms_application::{
	ice::{Limits, Servers},
	signaling as policy,
};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	sync::Arc,
};
use tokio::sync::{Semaphore, watch};
use wasm_bindgen::{JsCast, JsValue};
use wasm_bindgen_futures::{JsFuture, future_to_promise};
use web_sys::{EcKeyGenParams, RtcConfiguration, RtcIceServer, RtcPeerConnection};

const LIMITS: Limits = Limits {
	servers: glowcap::WEBRTC_MAX_ICE_SERVERS,
	urls: glowcap::WEBRTC_MAX_ICE_URLS_PER_SERVER,
	url_bytes: glowcap::WEBRTC_MAX_ICE_URL_BYTES,
	credential_bytes: glowcap::WEBRTC_MAX_ICE_CREDENTIAL_BYTES,
};
// The read runs inside a signaling exchange's budget on both sides. It gets
// what that budget leaves beyond the offerer's connect bound, so a hung
// endpoint reports in this source's own words before the exchange times out.
// Directory exchange capacity does not govern HTTP readers.
const FETCH_TIMEOUT_MS: u32 = (policy::TIMEOUT_MS - policy::CONNECT_TIMEOUT_MS) as u32;
const MAX_OBSERVERS: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	Closed,
	Busy,
	Timeout,
	Http(u16),
	Invalid(&'static str),
	Platform(&'static str),
	Certificate(String),
}
impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::Closed => f.write_str("Rooms ICE source is closed"),
			Self::Busy => f.write_str("too many pending Rooms WebRTC configurations"),
			Self::Timeout => f.write_str("Rooms ICE request timed out"),
			Self::Http(status) => write!(f, "Rooms ICE request failed ({status})"),
			Self::Certificate(reason) => write!(f, "generating the WebRTC certificate failed: {reason}"),
			Self::Invalid(reason) | Self::Platform(reason) => f.write_str(reason),
		}
	}
}
impl std::error::Error for Error {}

/// Where a configuration comes from: the Rooms server's policy, fetched for
/// each read so credentials stay fresh, or a fixed list held by the page.
enum Policy {
	Fetched(String),
	Fixed(Servers),
}
struct Inner {
	policy: Policy,
	closed: watch::Sender<bool>,
	// Bound native key generation to one directory's allowance of exchanges,
	// including operations whose signaling observers have already gone.
	certificates: Arc<Semaphore>,
	current: RefCell<Option<Rc<request::Attempt>>>,
}
impl Drop for Inner {
	fn drop(&mut self) {
		if let Some(attempt) = self.current.get_mut() {
			attempt.abort(Error::Closed);
		}
	}
}

#[derive(Clone)]
pub struct Source(Rc<Inner>);
impl Source {
	/// A source that reads the policy at `url` on each configuration.
	pub fn new(url: impl Into<String>) -> Self {
		Self::with(Policy::Fetched(url.into()))
	}
	/// The default STUN policy, for a page with no Rooms server to ask. Public
	/// STUN finds a path between most peers; TURN needs a server's issuer.
	pub fn stun_default() -> Result<Self, Error> {
		Servers::stun(None, LIMITS)
			.map(|servers| Self::with(Policy::Fixed(servers)))
			.map_err(Error::Invalid)
	}
	fn with(policy: Policy) -> Self {
		Self(Rc::new(Inner {
			policy,
			closed: watch::Sender::new(false),
			certificates: Arc::new(Semaphore::new(policy::MAX_EXCHANGES)),
			current: RefCell::new(None),
		}))
	}
	/// Each configuration carries a fresh DTLS certificate. Dropping the caller
	/// drops its observation. The source owns a shared ICE fetch through retirement.
	/// Signaling callers include this preparation in their exchange budget.
	pub async fn configuration(&self) -> Result<RtcConfiguration, Error> {
		let mut closed = self.0.closed.subscribe();
		if *closed.borrow() {
			return Err(Error::Closed);
		}
		let config = match &self.0.policy {
			Policy::Fixed(servers) => configuration(servers),
			Policy::Fetched(url) => configuration(self.servers(url).await?.as_ref()),
		};
		// Native key generation has no abort API. Closing the source or dropping
		// the attempt releases its observer. Only a live caller can use the result.
		let certificate = tokio::select! {
			biased;
			_ = closed.changed() => return Err(Error::Closed),
			certificate = certificate(&self.0.certificates) => certificate?,
		};
		config.set_certificates(&js_sys::Array::of1(&certificate));
		Ok(config)
	}
	async fn servers(&self, url: &str) -> Result<Rc<Servers>, Error> {
		let attempt = {
			let mut current = self.0.current.borrow_mut();
			match current.as_ref() {
				Some(attempt) if attempt.running() => attempt.clone(),
				_ => {
					let attempt = request::Attempt::start(url)?;
					*current = Some(attempt.clone());
					attempt
				}
			}
		};
		attempt.observe().await
	}
	/// Abort the current fetch and observe both the body read and all admitted
	/// browser certificate operations, including ones whose callers have gone.
	pub async fn close(&self) -> Result<(), Error> {
		self.0.closed.send_replace(true);
		let attempt = self.0.current.borrow().clone();
		if let Some(attempt) = &attempt {
			attempt.abort(Error::Closed);
		}
		let _certificates = self
			.0
			.certificates
			.acquire_many(policy::MAX_EXCHANGES as u32)
			.await
			.map_err(|_| Error::Platform("WebRTC certificate admission ended"))?;
		if let Some(attempt) = attempt {
			attempt.retired().await?;
		}
		// A closed source has no future readers. Release any completed response
		// (including its credentials) after the retirement barrier succeeds.
		self.0.current.borrow_mut().take();
		Ok(())
	}
}

async fn certificate(capacity: &Arc<Semaphore>) -> Result<JsValue, Error> {
	let permit = capacity.clone().try_acquire_owned().map_err(|_| Error::Busy)?;
	let refused = |cause: JsValue| {
		let detail = cause
			.dyn_ref::<js_sys::Error>()
			.map(|error| error.to_string())
			.or_else(|| cause.dyn_ref::<js_sys::JsString>().cloned())
			.map(|text| String::from(text.slice(0, rooms_application::failure::MAX_REASON_BYTES as u32)))
			.unwrap_or_else(|| "unknown browser error".into());
		Error::Certificate(rooms_application::failure::reason_prefix(&detail).into())
	};
	let algorithm = EcKeyGenParams::new("ECDSA", "P-256");
	let promise = RtcPeerConnection::generate_certificate_with_object(&algorithm).map_err(refused)?;
	// Native generation outlives a cancelled signaling attempt. The browser
	// promise owns its slot until settlement, independently of the observer.
	let settled = future_to_promise(async move {
		let result = JsFuture::from(promise).await;
		drop(permit);
		result
	});
	JsFuture::from(settled).await.map_err(refused)
}

fn configuration(servers: &Servers) -> RtcConfiguration {
	let records = js_sys::Array::new();
	for server in servers.iter() {
		let record = RtcIceServer::new();
		let urls = js_sys::Array::new();
		for url in server.urls() {
			urls.push(&url.as_str().into());
		}
		record.set_urls(&urls);
		if let Some(username) = server.username() {
			record.set_username(username);
		}
		if let Some(credential) = server.credential() {
			record.set_credential(credential);
		}
		records.push(&record);
	}
	let configuration = RtcConfiguration::new();
	configuration.set_ice_servers(&records);
	configuration
}
