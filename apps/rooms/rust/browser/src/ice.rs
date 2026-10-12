//! Deployment-owned ICE configuration. One source coalesces concurrent reads
//! but never caches credentials across completed attempts. Own and close it
//! with the browser application, before retiring its LocalSet.
mod fetch;
mod request;

use rooms_application::ice::{Limits, Servers};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use web_sys::{RtcConfiguration, RtcIceServer};

const LIMITS: Limits = Limits {
	servers: glowcap::WEBRTC_MAX_ICE_SERVERS,
	urls: glowcap::WEBRTC_MAX_ICE_URLS_PER_SERVER,
	url_bytes: glowcap::WEBRTC_MAX_ICE_URL_BYTES,
	credential_bytes: glowcap::WEBRTC_MAX_ICE_CREDENTIAL_BYTES,
};
// This HTTP request precedes transport signaling and has its own lifetime and
// admission budget. Directory exchange capacity does not govern HTTP readers.
const FETCH_TIMEOUT_MS: u32 = 30_000;
const MAX_OBSERVERS: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	Closed,
	Busy,
	Timeout,
	Http(u16),
	Invalid(&'static str),
	Platform(&'static str),
}
impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::Closed => f.write_str("Rooms ICE source is closed"),
			Self::Busy => f.write_str("too many pending Rooms ICE observers"),
			Self::Timeout => f.write_str("Rooms ICE request timed out"),
			Self::Http(status) => write!(f, "Rooms ICE request failed ({status})"),
			Self::Invalid(reason) | Self::Platform(reason) => f.write_str(reason),
		}
	}
}
impl std::error::Error for Error {}

struct Inner {
	url: String,
	closed: Cell<bool>,
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
	pub fn new(url: impl Into<String>) -> Self {
		Self(Rc::new(Inner {
			url: url.into(),
			closed: Cell::new(false),
			current: RefCell::new(None),
		}))
	}
	pub fn deployment() -> Self {
		Self::new("/ice")
	}
	/// Cancellation drops only this observation. A concurrent caller shares
	/// the same admitted request. The source owns it through fetch retirement.
	pub async fn configuration(&self) -> Result<RtcConfiguration, Error> {
		if self.0.closed.get() {
			return Err(Error::Closed);
		}
		let attempt = {
			let mut current = self.0.current.borrow_mut();
			if current.as_ref().is_none_or(|attempt| !attempt.running()) {
				*current = Some(request::Attempt::start(&self.0.url)?);
			}
			current.as_ref().expect("admitted ICE request").clone()
		};
		let servers = attempt.observe().await?;
		if self.0.closed.get() {
			return Err(Error::Closed);
		}
		Ok(configuration(&servers))
	}
	/// Abort and observe the current request, including a pending body read.
	/// Dropping this close observation cannot cancel the retirement worker.
	pub async fn close(&self) -> Result<(), Error> {
		self.0.closed.set(true);
		let attempt = self.0.current.borrow().clone();
		if let Some(attempt) = attempt {
			attempt.abort(Error::Closed);
			attempt.retired().await?;
		}
		// A closed source has no future readers. Release any completed response
		// (including its credentials) after the retirement barrier succeeds.
		self.0.current.borrow_mut().take();
		Ok(())
	}
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
