//! Deployment admission precedes an opaque byte-channel dial. The permit
//! remains held through channel teardown, including a failed or cancelled dial.
use crate::server::readiness::Announcement;
use bytes::Bytes;
use glowcap::{HintValue, Locator, iroh};
use http_body_util::Full;
use hyper::{Request, Response, StatusCode, body::Incoming};
use rooms_application::web_relay;
use rooms_platform::{serving::endpoint::Endpoint, websocket::WsBytes};

use std::{
	cell::{Cell, RefCell},
	future::Future,
	pin::Pin,
	rc::Rc,
	sync::Arc,
	time::Duration,
};
use tokio::{
	io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
	net::{TcpStream, UnixStream},
	sync::{Semaphore, mpsc, watch},
	time::Instant,
};

mod limits;
pub(super) use limits::{Limits, exact_address, origin_allowed, site_page};

pub(super) type Job = Pin<Box<dyn Future<Output = Result<(), String>>>>;
/// How a browser reaches the shared session this server runs beside its
/// directory, read from the session's use link.
pub(super) enum SessionReach {
	/// By its key, or through the relay its link names: nothing for this
	/// relay to forward.
	Direct,
	/// At the TCP endpoint its link names, which this relay forwards to as it
	/// does a listed peer.
	Forwarded(Endpoint),
}
/// `None` is a door no browser reaches through this relay (onion), so no
/// page is offered the session.
pub(super) fn session_reach(link: &str) -> Option<SessionReach> {
	let locator = glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0)
		.ok()?
		.locator;
	match locator.transport.as_str() {
		glowcap::TRANSPORT_IROH | glowcap::TRANSPORT_KEYED_RELAY | glowcap::TRANSPORT_NOISE_RELAY => {
			Some(SessionReach::Direct)
		}
		_ => tcp_endpoint(&locator).map(|(host, port)| SessionReach::Forwarded(Endpoint::Tcp { host, port })),
	}
}

pub(super) struct Relay {
	admission: Rc<super::admission::Admission>,
	slots: Arc<Semaphore>,
	registry: Rc<super::rendezvous::Registry>,
	iroh: Arc<Semaphore>,
	starts: Cell<(f64, Instant)>,
	limits: Limits,
	location: watch::Receiver<Option<Announcement>>,
	/// The shared session's TCP endpoint once the session is open, forwarded
	/// to as a listed peer is.
	session: watch::Receiver<Option<Endpoint>>,
	jobs: mpsc::Sender<Job>,
	stop: watch::Receiver<bool>,
	report: super::Report,
	refusals: RefCell<super::notice::Repeats>,
}
impl Relay {
	/// The request's `Origin`, when it names a page origin the operator listed,
	/// for a read such as `locator` to answer it by name.
	pub(super) fn listed_origin<B>(&self, request: &Request<B>) -> Option<hyper::header::HeaderValue> {
		let origin = request.headers().get("origin")?;
		let parsed = url::Url::parse(origin.to_str().ok()?).ok()?;
		self.limits.origins.contains(&parsed.origin()).then(|| origin.clone())
	}
	/// Whether this page origin may use the relay. A browser cannot say why its
	/// socket closed, so a refused origin is told to the operator, with the
	/// option that admits it.
	pub(super) fn admits<B>(&self, request: &Request<B>) -> bool {
		if origin_allowed(request, &self.limits.origins) {
			return true;
		}
		let origin = request.headers().get("origin").map_or_else(String::new, |origin| {
			String::from_utf8_lossy(origin.as_bytes()).into_owned()
		});
		if let Some(times) = self.refusals.borrow_mut().observe(&origin) {
			// The option is suggested only for a value that is exactly an origin,
			// one `page_entry` takes, and it carries what is listed already,
			// because the option replaces the default.
			let exact = url::Url::parse(&origin).is_ok_and(|url| url.origin().ascii_serialization() == origin);
			let admitting = exact.then(|| {
				let entries: Vec<&str> = self
					.limits
					.listed
					.iter()
					.map(String::as_str)
					.chain([origin.as_str()])
					.collect();
				entries.join(",")
			});
			(self.report)(super::Notice::OriginRefused {
				origin,
				admitting,
				times,
			});
		}
		false
	}
	#[cfg(test)]
	pub fn new(
		limits: Limits,
		location: watch::Receiver<Option<Announcement>>,
		session: watch::Receiver<Option<Endpoint>>,
		jobs: mpsc::Sender<Job>,
		stop: watch::Receiver<bool>,
		report: super::Report,
	) -> Rc<Self> {
		Self::with_admission(
			limits,
			location,
			session,
			jobs,
			stop,
			report,
			super::admission::Admission::new(super::admission::Config {
				settings: rooms_application::admission::Settings::defaults(
					rooms_application::admission::HTTP_ROWS,
					rooms_application::admission::POOLED_AGGREGATE_SCALE,
				),
				per_address: false,
				trusted_proxies: Default::default(),
			}),
		)
	}
	pub fn with_admission(
		limits: Limits,
		location: watch::Receiver<Option<Announcement>>,
		session: watch::Receiver<Option<Endpoint>>,
		jobs: mpsc::Sender<Job>,
		stop: watch::Receiver<bool>,
		report: super::Report,
		admission: Rc<super::admission::Admission>,
	) -> Rc<Self> {
		Rc::new(Self {
			admission: admission.clone(),
			slots: Arc::new(Semaphore::new(limits.sessions)),
			registry: super::rendezvous::Registry::with_profile(
				limits.registrations,
				limits.per_identity,
				admission.settings().profile(),
			),
			iroh: Arc::new(Semaphore::new(limits.iroh)),
			starts: Cell::new((limits.iroh as f64, Instant::now())),
			limits,
			location,
			session,
			jobs,
			stop,
			report,
			refusals: RefCell::default(),
		})
	}
	pub fn upgrade(&self, mut request: Request<Incoming>, target: &str, rendezvous: bool) -> super::http::Reply {
		// A rendezvous dial is the one path a page from another deployment may
		// take: a `keyed-relay` locator carries its relay route in
		// its `rendezvous-relay` hint, and the redeemer follows that hint, so
		// the Origin rule cannot apply. What bounds it instead is the registry's
		// own per-identity claim rate.
		if !rendezvous && !self.admits(&request) {
			return refusal(StatusCode::FORBIDDEN, "rooms: cross-origin relay refused\n");
		}
		let target = match if rendezvous {
			if super::rendezvous::designator(target) {
				Ok(Target::Rendezvous(target.to_owned()))
			} else {
				Err((StatusCode::BAD_REQUEST, "rooms: invalid rendezvous identity\n"))
			}
		} else {
			self.target(target)
		} {
			Ok(target) => target,
			Err((code, reason)) => return refusal(code, reason),
		};
		let slot = match self.slots.clone().try_acquire_owned() {
			Ok(slot) => slot,
			Err(_) => return refusal(StatusCode::SERVICE_UNAVAILABLE, "rooms: relay capacity exceeded\n"),
		};
		let iroh_slot = if matches!(target, Target::Iroh(_)) {
			let slot = match self.iroh.clone().try_acquire_owned() {
				Ok(slot) => slot,
				Err(_) => return refusal(StatusCode::SERVICE_UNAVAILABLE, "rooms: iroh relay capacity exceeded\n"),
			};
			let (tokens, at) = self.starts.get();
			let now = Instant::now();
			let tokens = (tokens + now.duration_since(at).as_secs_f64() * self.limits.starts as f64 / 60.0)
				.min(self.limits.iroh as f64);
			self.starts.set((tokens, now));
			if tokens < 1.0 {
				return refusal(StatusCode::SERVICE_UNAVAILABLE, "rooms: iroh relay rate exceeded\n");
			}
			Some(slot)
		} else {
			None
		};
		let queue = match self.jobs.try_reserve() {
			Ok(queue) => queue,
			Err(_) => {
				return refusal(
					StatusCode::SERVICE_UNAVAILABLE,
					"rooms: the relay is busy; try again in a moment\n",
				);
			}
		};
		let (response, upgrading) = match super::upgrade::prepare(&mut request) {
			Ok(prepared) => prepared,
			Err(reason) => return refusal(StatusCode::BAD_REQUEST, reason),
		};
		if let Err(refusal) = self.admission.start(
			rooms_application::admission::Class::HttpStart,
			request.extensions().get::<std::net::IpAddr>().copied(),
		) {
			return super::admission::reply(refusal);
		}
		if iroh_slot.is_some() {
			let (tokens, at) = self.starts.get();
			self.starts.set((tokens - 1.0, at));
		}
		let stop = self.stop.clone();
		let registry = self.registry.clone();
		queue.send(Box::pin(async move {
			let _permits = (slot, iroh_slot);
			run_relay(upgrading, target, stop, registry).await
		}));
		response
	}
	pub fn proxy(&self, mut request: Request<Incoming>, target: String) -> super::http::Reply {
		if !origin_allowed(&request, &[]) {
			return refusal(
				StatusCode::FORBIDDEN,
				"rooms: cross-origin timeline connection refused\n",
			);
		}
		let slot = match self.slots.clone().try_acquire_owned() {
			Ok(slot) => slot,
			Err(_) => return refusal(StatusCode::SERVICE_UNAVAILABLE, "rooms: relay capacity exceeded\n"),
		};
		let queue = match self.jobs.try_reserve() {
			Ok(queue) => queue,
			Err(_) => {
				return refusal(
					StatusCode::SERVICE_UNAVAILABLE,
					"rooms: the relay is busy; try again in a moment\n",
				);
			}
		};
		let (response, upgrading) = match super::upgrade::prepare(&mut request) {
			Ok(prepared) => prepared,
			Err(reason) => return refusal(StatusCode::BAD_REQUEST, reason),
		};
		if let Err(refusal) = self.admission.start(
			rooms_application::admission::Class::HttpStart,
			request.extensions().get::<std::net::IpAddr>().copied(),
		) {
			return super::admission::reply(refusal);
		}
		let stop = self.stop.clone();
		queue.send(Box::pin(async move {
			let _slot = slot;
			let socket = super::upgrade::accept(upgrading, stop.clone()).await?;
			super::proxy::run(socket, target, stop).await
		}));
		response
	}

	pub fn register(&self, mut request: Request<Incoming>, identity: &str) -> super::http::Reply {
		if !self.admits(&request) {
			return refusal(StatusCode::FORBIDDEN, "rooms: cross-origin registration refused\n");
		}
		if !super::rendezvous::designator(identity) {
			return refusal(StatusCode::BAD_REQUEST, "rooms: invalid rendezvous identity\n");
		}
		let queue = match self.jobs.try_reserve() {
			Ok(queue) => queue,
			Err(_) => {
				return refusal(
					StatusCode::SERVICE_UNAVAILABLE,
					"rooms: the relay is busy; try again in a moment\n",
				);
			}
		};
		let (response, upgrading) = match super::upgrade::prepare(&mut request) {
			Ok(prepared) => prepared,
			Err(reason) => return refusal(StatusCode::BAD_REQUEST, reason),
		};
		if let Err(refusal) = self.admission.start(
			rooms_application::admission::Class::Registration,
			request.extensions().get::<std::net::IpAddr>().copied(),
		) {
			return super::admission::reply(refusal);
		}
		let registration = match self.registry.register(identity) {
			Ok(registration) => registration,
			Err(reason) => return refusal(StatusCode::SERVICE_UNAVAILABLE, reason),
		};
		let stop = self.stop.clone();
		queue.send(Box::pin(async move {
			let socket = super::upgrade::accept(upgrading, stop.clone()).await?;
			let socket =
				WsBytes::new(socket).bounded(glowcap::BINDING_RELAY_MAX_BYTES_PER_SESSION, Duration::from_secs(30));
			registration.hold(socket, stop).await
		}));
		response
	}

	fn target(&self, input: &str) -> Result<Target, (StatusCode, &'static str)> {
		let invalid = (StatusCode::BAD_REQUEST, "rooms: unparseable relay target locator\n");
		if input.len() > web_relay::MAX_TARGET_BYTES {
			return Err(invalid);
		}
		let current = self.location.borrow().clone();
		// The directory's own doors: its one locator, or every route and
		// fallback inside the identity route it advertises.
		let own: Vec<Locator> = current
			.as_ref()
			.and_then(|s| glowcap::parse_locator(&s.location).ok())
			.map(|location| rooms_glowcap::routes::doors(&location))
			.unwrap_or_default();
		let local = current.and_then(|s| s.local_endpoint);
		let target = if input.contains("://") {
			let locator = glowcap::parse_locator(input).map_err(|_| invalid)?;
			match locator.transport.as_str() {
				glowcap::TRANSPORT_IROH => {
					if locator.designator.len() != 64
						|| !locator
							.designator
							.bytes()
							.all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
					{
						return Err(invalid);
					}
					return Ok(Target::Iroh(locator));
				}
				glowcap::TRANSPORT_ONION => {
					if !own
						.iter()
						.any(|door| door.transport == glowcap::TRANSPORT_ONION && door.designator == locator.designator)
					{
						return Err((StatusCode::FORBIDDEN, "rooms: foreign onion relay refused\n"));
					}
					return local.map(Target::Local).ok_or((
						StatusCode::SERVICE_UNAVAILABLE,
						"rooms: directory forwarding unavailable\n",
					));
				}
				_ => tcp_endpoint(&locator).ok_or(invalid)?,
			}
		} else {
			glowcap::designator_host_port(input).map_err(|_| invalid)?
		};
		if own.iter().filter_map(tcp_endpoint).any(|door| door == target) {
			return local.map(Target::Local).ok_or((
				StatusCode::SERVICE_UNAVAILABLE,
				"rooms: directory forwarding unavailable\n",
			));
		}
		let allowed = self.limits.tcp.contains(&target);
		let endpoint = Endpoint::Tcp {
			host: target.0,
			port: target.1,
		};
		if allowed || local.as_ref() == Some(&endpoint) || self.session.borrow().as_ref() == Some(&endpoint) {
			Ok(Target::Local(endpoint))
		} else {
			Err((StatusCode::FORBIDDEN, "rooms: relay target not allowed\n"))
		}
	}
}

enum Target {
	Rendezvous(String),
	Local(Endpoint),
	Iroh(Locator),
}
impl std::fmt::Display for Target {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::Rendezvous(identity) => write!(f, "rendezvous peer {identity}"),
			Self::Local(Endpoint::Tcp { host, port }) => write!(f, "{host}:{port}"),
			Self::Local(Endpoint::Unix { path }) => write!(f, "{}", path.display()),
			Self::Iroh(locator) => write!(f, "{}.iroh", locator.designator),
		}
	}
}
async fn run_relay(
	upgrading: hyper::upgrade::OnUpgrade,
	target: Target,
	stop: watch::Receiver<bool>,
	registry: Rc<super::rendezvous::Registry>,
) -> Result<(), String> {
	let ws = super::upgrade::accept(upgrading, stop.clone()).await?;
	let mut ws = WsBytes::new(ws).bounded(glowcap::BINDING_RELAY_MAX_BYTES_PER_SESSION, Duration::from_secs(120));
	let destination = target.to_string();
	let result = connect_and_pump(&mut ws, target, stop, registry).await;
	retire_websocket(&mut ws, result)
		.await
		.map_err(|cause| format!("{destination}: {cause}"))
}
async fn connect_and_pump(
	ws: &mut (impl AsyncRead + AsyncWrite + Unpin),
	target: Target,
	stop: watch::Receiver<bool>,
	registry: Rc<super::rendezvous::Registry>,
) -> Result<(), String> {
	let mut stopping = stop.clone();
	match target {
		Target::Local(Endpoint::Tcp { host, port }) => {
			let mut tcp = tokio::select! {
				_ = super::stopped(&mut stopping) => return Ok(()),
				result = tokio::time::timeout(Duration::from_millis(glowcap::BINDING_RELAY_TCP_DIAL_TIMEOUT_MS as u64), TcpStream::connect((host.as_str(), port))) => result.map_err(|_| "TCP relay dial timed out")?.map_err(|e| e.to_string())?,
			};
			pump(ws, &mut tcp, stop).await
		}
		Target::Local(Endpoint::Unix { path }) => {
			let mut socket = tokio::select! {
				_ = super::stopped(&mut stopping) => return Ok(()),
				result = tokio::time::timeout(Duration::from_millis(glowcap::BINDING_RELAY_TCP_DIAL_TIMEOUT_MS as u64), UnixStream::connect(path)) => result.map_err(|_| "local relay dial timed out")?.map_err(|e| e.to_string())?,
			};
			pump(ws, &mut socket, stop).await
		}
		Target::Rendezvous(identity) => {
			let claimed = registry.take(&identity)?;
			let held = tokio::select! {
				_ = super::stopped(&mut stopping) => return Ok(()),
				result = tokio::time::timeout(Duration::from_secs(10), claimed) => result
					.map_err(|_| "rendezvous claim timed out")?.map_err(|_| "registered peer went away")?,
			};
			let (read, write) = tokio::io::split(held.socket);
			let mut far = tokio::io::join(held.early.chain(read), write);
			pump(ws, &mut far, stop).await
		}
		Target::Iroh(locator) => {
			let address = locator
				.string_hint(glowcap::HINT_DIRECT_ADDRESSES)
				.map_err(|e| e.to_string())?
				.unwrap_or("");
			let mut stream = tokio::select! {
				_ = super::stopped(&mut stopping) => return Ok(()),
				result = tokio::time::timeout(Duration::from_millis(web_relay::IROH_DIAL_TIMEOUT_MS.into()), iroh::Stream::connect(&locator.designator, address, iroh::Reachability::Discovery)) => result.map_err(|_| "iroh relay dial timed out")?.map_err(|e| e.to_string())?,
			};
			let result = pump(ws, &mut stream, stop).await;
			crate::cleanup::combine(result, stream.close().await.map_err(|e| e.to_string()))
		}
	}
}
/// A WebSocket control frame holds 125 payload bytes, two of them the code.
const CLOSE_REASON_MAX_BYTES: usize = 123;
async fn retire_websocket(
	ws: &mut WsBytes<hyper_util::rt::TokioIo<hyper::upgrade::Upgraded>>,
	result: Result<(), String>,
) -> Result<(), String> {
	// Even failure before a far stream exists owes the browser a Close carrying
	// the cause: the page learns nothing else about why its socket ended. A
	// pump that already closed the pair only flushes its existing reply.
	let frame = result.as_ref().err().map(|cause| {
		let end = cause.floor_char_boundary(CLOSE_REASON_MAX_BYTES);
		tokio_tungstenite::tungstenite::protocol::CloseFrame {
			code: tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode::Error,
			reason: cause.get(..end).unwrap_or_default().to_owned().into(),
		}
	});
	let retired = tokio::time::timeout(Duration::from_secs(3), ws.close(frame))
		.await
		.map_err(|_| "relay WebSocket shutdown timed out".to_owned())
		.and_then(|result| result.map_err(|e| e.to_string()));
	crate::cleanup::combine(result, retired)
}
pub(super) fn refusal(status: StatusCode, text: &'static str) -> super::http::Reply {
	let mut reply = Response::new(Full::new(Bytes::from_static(text.as_bytes())));
	*reply.status_mut() = status;
	reply
}
async fn pump<A: AsyncRead + AsyncWrite + Unpin, B: AsyncRead + AsyncWrite + Unpin>(
	near: &mut A,
	far: &mut B,
	mut stop: watch::Receiver<bool>,
) -> Result<(), String> {
	// A relay pair is one lifetime. EOF on either leg retires both; stream
	// half-close semantics would leave the other WebSocket and permit waiting
	// for an unrelated idle deadline.
	let result = {
		let (mut near_read, mut near_write) = tokio::io::split(&mut *near);
		let (mut far_read, mut far_write) = tokio::io::split(&mut *far);
		tokio::select! {
			biased;
			_ = super::stopped(&mut stop) => Ok(()),
			result = tokio::io::copy(&mut near_read, &mut far_write) => result.map(|_| ()).map_err(|e| e.to_string()),
			result = tokio::io::copy(&mut far_read, &mut near_write) => result.map(|_| ()).map_err(|e| e.to_string()),
		}
	};
	let closing = async {
		let (near, far) = tokio::join!(near.shutdown(), far.shutdown());
		crate::cleanup::combine(near.map_err(|e| e.to_string()), far.map_err(|e| e.to_string()))
	};
	crate::cleanup::combine(
		result,
		tokio::time::timeout(Duration::from_secs(3), closing)
			.await
			.map_err(|_| "relay shutdown timed out".to_owned())
			.and_then(|r| r),
	)
}

/// The TCP endpoint a locator names outright: a cleartext tcp designator, or
/// the direct address a noise-tcp or keyed-tcp locator carries. Keyed
/// transports the relay reaches another way (iroh, onion) name none.
fn tcp_endpoint(locator: &Locator) -> Option<(String, u16)> {
	match locator.transport.as_str() {
		glowcap::TRANSPORT_TCP => glowcap::designator_host_port(&locator.designator).ok(),
		glowcap::TRANSPORT_NOISE_TCP | glowcap::TRANSPORT_KEYED_TCP => {
			match locator.hints.get(glowcap::HINT_DIRECT_ADDRESSES) {
				Some(HintValue::String(address)) => glowcap::designator_host_port(address).ok(),
				_ => None,
			}
		}
		_ => None,
	}
}

#[cfg(test)]
mod tests;
