//! Bounded HTTP connections run independently of directory supervision.
//! Hyper owns HTTP framing; handlers own only the Rooms resource contract.
use bytes::Bytes;
use http_body_util::Full;
use hyper::{body::Incoming, service::service_fn, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use std::{convert::Infallible, rc::Rc, time::Duration};
use tokio::{net::TcpListener, sync::watch, task::JoinSet};

pub(super) struct Environment {
	pub assets: Rc<super::assets::Assets>,
	pub ice: super::ice::Policy,
	pub location: watch::Receiver<Option<crate::room_server::readiness::Announcement>>,
	pub relay: Rc<super::relay::Relay>,
}
pub(super) type Reply = Response<Full<Bytes>>;
pub(super) async fn serve(
	listener: TcpListener,
	environment: Rc<Environment>,
	mut incoming: tokio::sync::mpsc::Receiver<super::relay::Job>,
	shutdown: watch::Sender<bool>,
	mut stop: watch::Receiver<bool>,
) -> Result<(), String> {
	let mut connections = JoinSet::new();
	let mut upgrades = JoinSet::new();
	let mut retry = None;
	let result = loop {
		if *stop.borrow() {
			break Ok(());
		}
		tokio::select! {
			_ = stop.changed() => break Ok(()),
			accepted = listener.accept(), if connections.len() < 256 && retry.is_none() => match accepted {
				Ok((socket,_)) => {
					let environment = environment.clone();
					let mut stopping = stop.clone();
					connections.spawn_local(async move {
						let service = service_fn(move |request| {
							let environment = environment.clone();
							async move { Ok::<_,Infallible>(reply(request, &environment).await) }
						});
						let mut builder = hyper::server::conn::http1::Builder::new();
						builder.timer(TokioTimer::new()).header_read_timeout(Duration::from_secs(15))
							.max_headers(64).max_buf_size(32 * 1024);
						let serving = builder.serve_connection(TokioIo::new(socket), service).with_upgrades();
						tokio::pin!(serving);
						tokio::select! {
							result = &mut serving => connection_result(result),
							_ = super::stopped(&mut stopping) => {
								serving.as_mut().graceful_shutdown();
								tokio::time::timeout(Duration::from_secs(5), serving).await
									.map_err(|_| "HTTP connection exceeded shutdown deadline".to_owned())
									.and_then(connection_result)
							}
						}
					});
				}
				Err(error) => {
					eprintln!("rooms web: HTTP accept refused, retrying: {error}");
					retry = Some(tokio::time::Instant::now() + crate::serving::ACCEPT_RETRY);
				}
			},
			_ = tokio::time::sleep_until(retry.unwrap_or_else(tokio::time::Instant::now)), if retry.is_some() => { retry = None; },
			Some(ended) = connections.join_next(), if !connections.is_empty() => {
				match ended {
					Ok(Err(error)) => eprintln!("rooms web: HTTP connection ended: {error}"),
					Err(error) => break Err(error.to_string()),
					Ok(Ok(())) => {},
				}
			}
			Some(job) = incoming.recv() => { upgrades.spawn_local(job); },
			Some(ended) = upgrades.join_next(), if !upgrades.is_empty() => {
				match ended {
					Ok(Err(error)) => eprintln!("rooms web: relay ended: {error}"),
					Err(error) => break Err(error.to_string()),
					Ok(Ok(())) => {},
				}
			}
		}
	};
	shutdown.send_replace(true);
	drop(listener);
	incoming.close();
	while let Ok(job) = incoming.try_recv() {
		upgrades.spawn_local(job);
	}
	let mut result = result;
	for tasks in [&mut connections, &mut upgrades] {
		while let Some(ended) = tasks.join_next().await {
			match ended {
				Ok(Err(error)) => eprintln!("rooms web: connection ended during shutdown: {error}"),
				Err(error) => result = crate::cleanup::combine(result, Err(error.to_string())),
				Ok(Ok(())) => {}
			}
		}
	}
	result
}
fn connection_result(result: Result<(), hyper::Error>) -> Result<(), String> {
	match result {
		// Browsers keep unused/preconnected sockets. The header deadline
		// retires those peers by policy; it is not a service failure to log.
		Err(error) if error.is_timeout() => Ok(()),
		result => result.map_err(|e| e.to_string()),
	}
}
async fn reply(request: Request<Incoming>, environment: &Environment) -> Reply {
	let head = request.method() == hyper::Method::HEAD;
	let mut reply = resource(request, environment).await;
	if head && reply.status() != StatusCode::SWITCHING_PROTOCOLS {
		use hyper::body::Body;
		if let Some(length) = reply.body().size_hint().exact() {
			if reply.status() != StatusCode::NO_CONTENT && reply.status() != StatusCode::NOT_MODIFIED {
				reply.headers_mut().insert("content-length", length.into());
			}
		}
		*reply.body_mut() = Full::new(Bytes::new());
	}
	reply
}
async fn resource(request: Request<Incoming>, environment: &Environment) -> Reply {
	if request.method() != hyper::Method::GET && request.method() != hyper::Method::HEAD {
		return response(
			StatusCode::METHOD_NOT_ALLOWED,
			"text/plain",
			"Rooms resources require GET or HEAD\n".into(),
		);
	}
	let path = request.uri().path();
	if path == "/relay" || path == "/register" {
		let query = url::form_urlencoded::parse(request.uri().query().unwrap_or("").as_bytes())
			.into_owned()
			.collect::<Vec<_>>();
		let parameter = |name| {
			query
				.iter()
				.find(|(key, _)| key == name)
				.map(|(_, value)| value.to_string())
		};
		if path == "/register" {
			return environment
				.relay
				.register(request, &parameter("id").unwrap_or_default());
		}
		let target = parameter("rendezvous")
			.map(|value| (value, true))
			.or_else(|| parameter("target").map(|value| (value, false)));
		return match target {
			Some((target, rendezvous)) => environment.relay.upgrade(request, &target, rendezvous),
			None => response(
				StatusCode::BAD_REQUEST,
				"text/plain",
				"rooms: relay requires a target or rendezvous identity\n".into(),
			),
		};
	}
	if path == "/locator" {
		return match environment.location.borrow().clone() {
			Some(locator) => response(
				StatusCode::OK,
				"text/plain; charset=utf-8",
				format!("{}\n", locator.location).into(),
			),
			None => response(
				StatusCode::SERVICE_UNAVAILABLE,
				"text/plain",
				"rooms: locator not ready\n".into(),
			),
		};
	}

	if path == "/ice" {
		return match environment.ice.servers().await {
			Ok(body) => response(StatusCode::OK, "application/json", body),
			Err(error) => {
				eprintln!("rooms web: {error}");
				response(
					StatusCode::SERVICE_UNAVAILABLE,
					"text/plain",
					"rooms: ICE policy unavailable\n".into(),
				)
			}
		};
	}
	if path == "/viz" || path == "/publish" {
		let current = environment.location.borrow().clone();
		let Some(current) = current else {
			return response(
				StatusCode::SERVICE_UNAVAILABLE,
				"text/plain",
				"rooms: directory not ready\n".into(),
			);
		};
		let Some(port) = current.viz_port else {
			return response(
				if path == "/viz" {
					StatusCode::NO_CONTENT
				} else {
					StatusCode::NOT_FOUND
				},
				"text/plain",
				Bytes::new(),
			);
		};
		if path == "/viz" && !request.headers().contains_key("upgrade") {
			return response(StatusCode::OK, "text/plain", format!("{port}\n").into());
		}
		let query = request.uri().query().map(|q| format!("?{q}")).unwrap_or_default();
		let endpoint = if path == "/publish" { "/publish" } else { "/" };
		return environment
			.relay
			.proxy(request, format!("ws://127.0.0.1:{port}{endpoint}{query}"));
	}
	match environment.assets.get(path).await {
		Ok(Some(asset)) => asset.response(&request),
		Ok(None) => response(StatusCode::NOT_FOUND, "text/plain", "rooms: asset not found\n".into()),
		Err(error) => {
			eprintln!("rooms web: asset unavailable: {error}");
			response(
				StatusCode::SERVICE_UNAVAILABLE,
				"text/plain",
				"rooms: asset unavailable\n".into(),
			)
		}
	}
}

pub(super) fn response(status: StatusCode, content_type: &'static str, body: Bytes) -> Reply {
	Response::builder()
		.status(status)
		.header("content-type", content_type)
		.header("cache-control", "no-store")
		.body(Full::new(body))
		.expect("fixed response headers")
}
