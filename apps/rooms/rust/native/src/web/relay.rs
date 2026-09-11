//! Deployment admission precedes an opaque byte-channel dial. The permit
//! remains held through channel teardown, including a failed or cancelled dial.
use crate::{room_server::readiness::Announcement, serving::endpoint::Endpoint, websocket::WsBytes};
use bytes::Bytes;
use glowcap::{iroh, HintValue, Locator};
use http_body_util::Full;
use hyper::{body::Incoming, Request, Response, StatusCode};
use rooms_application::web_relay;

use std::{cell::Cell, future::Future, pin::Pin, rc::Rc, sync::Arc, time::Duration};
use tokio::{
	io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
	net::{TcpStream, UnixStream},
	sync::{mpsc, watch, Semaphore},
	time::Instant,
};

pub(super) type Job = Pin<Box<dyn Future<Output = Result<(), String>>>>;
#[derive(Clone)]
pub(super) struct Limits {
	pub sessions: usize,
	pub iroh: usize,
	pub starts: usize,
	pub tcp: Vec<(String, u16)>,
	pub registrations: usize,
	pub per_identity: usize,
}
impl Limits {
	pub fn read(env: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
		let cap = |name, fallback| match env(name).filter(|s| !s.is_empty()) {
			None => Ok(fallback),
			Some(value) => value
				.parse::<usize>()
				.ok()
				.filter(|n| *n > 0 && *n <= Semaphore::MAX_PERMITS)
				.ok_or_else(|| format!("{name} must be a positive capacity")),
		};
		let iroh = cap("GLOWCAP_RELAY_MAX_IROH_SESSIONS", 16)?;
		let tcp = env("GLOWCAP_RELAY_TCP_PEERS")
			.unwrap_or_default()
			.split(',')
			.map(str::trim)
			.filter(|s| !s.is_empty())
			.map(|s| glowcap::designator_host_port(s).map_err(|e| e.to_string()))
			.collect::<Result<_, _>>()?;
		Ok(Self {
			sessions: cap("GLOWCAP_RELAY_MAX_SESSIONS", 217)?,
			registrations: cap("GLOWCAP_RELAY_MAX_REGISTRATIONS", 435)?,
			per_identity: cap("GLOWCAP_RELAY_MAX_REGISTRATIONS_PER_IDENTITY", 4)?,
			iroh,
			starts: cap("GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE", iroh.saturating_mul(2))?,
			tcp,
		})
	}
}
pub(super) struct Relay {
	slots: Arc<Semaphore>,
	registry: Rc<super::rendezvous::Registry>,
	iroh: Arc<Semaphore>,
	starts: Cell<(f64, Instant)>,
	limits: Limits,
	location: watch::Receiver<Option<Announcement>>,
	jobs: mpsc::Sender<Job>,
	stop: watch::Receiver<bool>,
}
impl Relay {
	pub fn new(
		limits: Limits,
		location: watch::Receiver<Option<Announcement>>,
		jobs: mpsc::Sender<Job>,
		stop: watch::Receiver<bool>,
	) -> Rc<Self> {
		Rc::new(Self {
			slots: Arc::new(Semaphore::new(limits.sessions)),
			registry: super::rendezvous::Registry::new(limits.registrations, limits.per_identity),
			iroh: Arc::new(Semaphore::new(limits.iroh)),
			starts: Cell::new((limits.iroh as f64, Instant::now())),
			limits,
			location,
			jobs,
			stop,
		})
	}
	pub fn upgrade(&self, mut request: Request<Incoming>, target: &str, rendezvous: bool) -> super::http::Reply {
		if !rendezvous && !origin_allowed(&request) {
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
			Err(_) => return refusal(StatusCode::SERVICE_UNAVAILABLE, "rooms: relay admission unavailable\n"),
		};
		let (response, upgrading) = match super::upgrade::prepare(&mut request) {
			Ok(prepared) => prepared,
			Err(reason) => return refusal(StatusCode::BAD_REQUEST, reason),
		};
		if iroh_slot.is_some() {
			let (tokens, at) = self.starts.get();
			self.starts.set((tokens - 1.0, at));
		}
		let stop = self.stop.clone();
		let registry = self.registry.clone();
		queue.send(Box::pin(async move {
			let (_slot,_iroh_slot) = (slot,iroh_slot);
			let ws = super::upgrade::accept(upgrading, stop.clone()).await?;
			let mut ws = WsBytes::new(ws).bounded(glowcap::BINDING_RELAY_MAX_BYTES_PER_SESSION,Duration::from_secs(120));
			let mut stopping = stop.clone();
			let result = async {
			match target {
				Target::Local(Endpoint::Tcp {host, port}) => {
					let mut tcp = tokio::select! {
						_ = super::stopped(&mut stopping) => return Ok(()),
						result = tokio::time::timeout(Duration::from_millis(glowcap::BINDING_RELAY_TCP_DIAL_TIMEOUT_MS as u64),TcpStream::connect((host.as_str(),port))) => result.map_err(|_| "TCP relay dial timed out")?.map_err(|e| e.to_string())?,
					};
					pump(&mut ws,&mut tcp,stop).await
				}
                Target::Local(Endpoint::Unix { path }) => {
                    let mut socket = tokio::select! {
                        _ = super::stopped(&mut stopping) => return Ok(()),
                        result = tokio::time::timeout(Duration::from_millis(glowcap::BINDING_RELAY_TCP_DIAL_TIMEOUT_MS as u64), UnixStream::connect(path)) => result.map_err(|_| "local relay dial timed out")?.map_err(|e| e.to_string())?,
                    };
                    pump(&mut ws, &mut socket, stop).await
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
                    pump(&mut ws, &mut far, stop).await
                }
				Target::Iroh(locator) => {
					let address = locator.string_hint(glowcap::HINT_DIRECT_ADDRESSES).map_err(|e| e.to_string())?.unwrap_or("");
					let mut stream = tokio::select! {
						_ = super::stopped(&mut stopping) => return Ok(()),
						result = tokio::time::timeout(Duration::from_millis(web_relay::IROH_DIAL_TIMEOUT_MS.into()),iroh::Stream::connect(&locator.designator,address,iroh::Reachability::Discovery)) => result.map_err(|_| "iroh relay dial timed out")?.map_err(|e| e.to_string())?,
					};
					let result = pump(&mut ws,&mut stream,stop).await;
					crate::cleanup::combine(result,stream.close().await.map_err(|e| e.to_string()))
				}
			}
			}.await;
			// Even failure before a far stream exists owes the browser a Close.
			// A pump that already closed the pair only flushes its existing reply.
			let frame = result.as_ref().err().map(|_| tokio_tungstenite::tungstenite::protocol::CloseFrame {
				code: tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode::Error,
				reason: "Rooms relay could not complete the connection".into(),
			});
			let retired = tokio::time::timeout(Duration::from_secs(3), ws.close(frame)).await
				.map_err(|_| "relay WebSocket shutdown timed out".to_owned())
				.and_then(|r| r.map_err(|e| e.to_string()));
			crate::cleanup::combine(result, retired)
		}));
		response
	}
	pub fn proxy(&self, mut request: Request<Incoming>, target: String) -> super::http::Reply {
		if !origin_allowed(&request) {
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
			Err(_) => return refusal(StatusCode::SERVICE_UNAVAILABLE, "rooms: proxy admission unavailable\n"),
		};
		let (response, upgrading) = match super::upgrade::prepare(&mut request) {
			Ok(prepared) => prepared,
			Err(reason) => return refusal(StatusCode::BAD_REQUEST, reason),
		};
		let stop = self.stop.clone();
		queue.send(Box::pin(async move {
			let _slot = slot;
			let socket = super::upgrade::accept(upgrading, stop.clone()).await?;
			super::proxy::run(socket, target, stop).await
		}));
		response
	}

	pub fn register(&self, mut request: Request<Incoming>, identity: &str) -> super::http::Reply {
		if !origin_allowed(&request) {
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
					"rooms: registration admission unavailable\n",
				)
			}
		};
		let (response, upgrading) = match super::upgrade::prepare(&mut request) {
			Ok(prepared) => prepared,
			Err(reason) => return refusal(StatusCode::BAD_REQUEST, reason),
		};
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
		let own = current.as_ref().and_then(|s| glowcap::parse_locator(&s.location).ok());
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
					if !own.as_ref().is_some_and(|own| {
						own.transport == glowcap::TRANSPORT_ONION && own.designator == locator.designator
					}) {
						return Err((StatusCode::FORBIDDEN, "rooms: foreign onion relay refused\n"));
					}
					return local.map(Target::Local).ok_or((
						StatusCode::SERVICE_UNAVAILABLE,
						"rooms: directory forwarding unavailable\n",
					));
				}
				glowcap::TRANSPORT_TCP => glowcap::designator_host_port(&locator.designator).map_err(|_| invalid)?,
				glowcap::TRANSPORT_NOISE_TCP | glowcap::TRANSPORT_KEYED_TCP => {
					let Some(HintValue::String(address)) = locator.hints.get(glowcap::HINT_DIRECT_ADDRESSES) else {
						return Err(invalid);
					};
					glowcap::designator_host_port(address).map_err(|_| invalid)?
				}
				_ => return Err(invalid),
			}
		} else {
			glowcap::designator_host_port(input).map_err(|_| invalid)?
		};
		let advertised = own
			.filter(|s| s.transport == glowcap::TRANSPORT_TCP)
			.and_then(|s| glowcap::designator_host_port(&s.designator).ok());
		if advertised.as_ref() == Some(&target) {
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
		if allowed || local.as_ref() == Some(&endpoint) {
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
pub(super) fn origin_allowed<B>(request: &Request<B>) -> bool {
	let Some(origin) = request.headers().get("origin") else {
		return true;
	};
	let Some(host) = request.headers().get("host").and_then(|v| v.to_str().ok()) else {
		return false;
	};
	let Ok(origin) = origin.to_str().ok().and_then(|s| url::Url::parse(s).ok()).ok_or(()) else {
		return false;
	};
	matches!(origin.scheme(), "http" | "https") && &origin[url::Position::BeforeHost..url::Position::AfterPort] == host
}
pub(super) fn refusal(status: StatusCode, text: &'static str) -> super::http::Reply {
	Response::builder()
		.status(status)
		.body(Full::new(Bytes::from_static(text.as_bytes())))
		.expect("fixed status")
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

#[cfg(test)]
mod tests;
