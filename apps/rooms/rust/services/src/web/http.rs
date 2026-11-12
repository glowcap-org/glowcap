//! Bounded HTTP connections run independently of directory supervision.
//! Hyper owns HTTP framing. Handlers own only the Rooms resource contract.
use bytes::Bytes;
use http_body_util::Full;
use hyper::{Request, Response, StatusCode, body::Incoming, service::service_fn};
use hyper_util::rt::{TokioIo, TokioTimer};
use std::{convert::Infallible, rc::Rc, time::Duration};
use tokio::{net::TcpListener, sync::watch, task::JoinSet};

pub(super) struct Environment {
	pub assets: Option<Rc<super::assets::Assets>>,
	pub ice: super::ice::Policy,
	pub location: watch::Receiver<Option<crate::server::readiness::Announcement>>,
	/// The link that opens the first allowed Rooms page with this server, which
	/// `/page` answers and the startup banner prints. None allows no page.
	pub page: Option<String>,
	pub previews: Rc<super::preview::Preview>,
	pub relay: Rc<super::relay::Relay>,
	pub report: super::Report,
	pub trusted_proxies: super::client_address::TrustedProxies,
}
pub(super) type Reply = Response<Full<Bytes>>;
pub(super) const MAX_CONNECTIONS: usize = 256;
/// How long a route that needs the announced directory waits for it. HTTP
/// serves before the directory comes up, so its relay listeners can register
/// here on their way, and a page asking in that moment would otherwise read
/// "not ready" as a server with no directory. Shorter than the page's own
/// 5 s read deadline, so the page sees either the address or a plain refusal.
const LOCATION_WAIT: Duration = Duration::from_secs(4);
pub(super) async fn serve(
	listener: TcpListener,
	environment: Rc<Environment>,
	mut incoming: tokio::sync::mpsc::Receiver<super::relay::Job>,
	shutdown: watch::Sender<bool>,
	mut stop: watch::Receiver<bool>,
) -> Result<(), String> {
	let mut connections = JoinSet::new();
	let mut upgrades = JoinSet::new();
	let mut retry = rooms_platform::serving::Retry::default();
	let mut relay_failures = super::notice::Repeats::default();
	let result = loop {
		if *stop.borrow() {
			break Ok(());
		}
		tokio::select! {
			_ = stop.changed() => break Ok(()),
			accepted = listener.accept(), if connections.len() < MAX_CONNECTIONS && retry.ready() => match accepted {
				Ok((socket,address)) => {
					let environment = environment.clone();
					let mut stopping = stop.clone();
					connections.spawn_local(async move {
						let service = service_fn(move |mut request| {
							let source = super::client_address::source_address(address.ip(), request.headers(), &environment.trusted_proxies);
							request.extensions_mut().insert(source);
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
					(environment.report)(super::Notice::HttpAcceptRefused(error.to_string()));
					retry.refused();
				}
			},
			_ = retry.wait() => {},
			Some(ended) = connections.join_next(), if !connections.is_empty() => {
				match ended {
					Ok(Err(error)) => (environment.report)(super::Notice::HttpConnectionEnded(error)),
					Err(error) => break Err(error.to_string()),
					Ok(Ok(())) => {},
				}
			}
			Some(job) = incoming.recv() => { upgrades.spawn_local(job); },
			Some(ended) = upgrades.join_next(), if !upgrades.is_empty() => {
				match ended {
					Ok(Err(cause)) => if let Some(times) = relay_failures.observe(&cause) {
						(environment.report)(super::Notice::RelayEnded { cause, times });
					},
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
				Ok(Err(error)) => (environment.report)(super::Notice::ShutdownConnectionEnded(error)),
				Err(error) => crate::cleanup::retain(&mut result, Err(error.to_string())),
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
		if let Some(length) = reply.body().size_hint().exact()
			&& reply.status() != StatusCode::NO_CONTENT
			&& reply.status() != StatusCode::NOT_MODIFIED
		{
			reply.headers_mut().insert("content-length", length.into());
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
			Some((target, rendezvous)) => {
				// A target is judged against the directory's own doors, so it
				// waits for the directory the way `/locator` does. A rendezvous
				// names a registered key and needs no directory.
				if !rendezvous {
					located(environment).await;
				}
				environment.relay.upgrade(request, &target, rendezvous)
			}
			None => response(
				StatusCode::BAD_REQUEST,
				"text/plain",
				"rooms: relay requires a target or rendezvous identity\n".into(),
			),
		};
	}
	// What this deployment is, for a program reading it: the llms.txt shape
	// (https://llmstxt.org/), so an agent handed this address learns how to
	// join and where the protocol is written down without scraping the page.
	if path == "/llms.txt" {
		return response(
			StatusCode::OK,
			"text/markdown; charset=utf-8",
			include_str!("../../../../web/llms.txt").into(),
		);
	}
	if path == "/locator" {
		let reply = match located(environment).await {
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
		// A page origin the operator listed reads the address from its own
		// page, such as a hosted Rooms page finding this server's directory.
		return for_listed_origin(reply, environment, &request);
	}

	// The same link the banner prints, for `rooms-web --page-link` and the
	// deployment's `up`, which read it from the running service.
	if path == "/page" {
		return match &environment.page {
			Some(link) => response(StatusCode::OK, "text/plain; charset=utf-8", format!("{link}\n").into()),
			None => response(StatusCode::NO_CONTENT, "text/plain", Bytes::new()),
		};
	}

	if path == "/ice" {
		let reply = match environment.ice.servers().await {
			Ok(body) => response(StatusCode::OK, "application/json", body),
			Err(error) => {
				(environment.report)(super::Notice::IceUnavailable(error));
				response(
					StatusCode::SERVICE_UNAVAILABLE,
					"text/plain",
					"rooms: ICE policy unavailable\n".into(),
				)
			}
		};
		return for_listed_origin(reply, environment, &request);
	}
	if path == "/link-preview" || path == "/link-preview/image" {
		if !environment.relay.admits(&request) {
			return response(
				StatusCode::FORBIDDEN,
				"text/plain",
				"rooms: cross-origin link preview refused\n".into(),
			);
		}
		let query = url::form_urlencoded::parse(request.uri().query().unwrap_or("").as_bytes())
			.into_owned()
			.collect::<Vec<_>>();
		let url = query
			.iter()
			.find(|(key, _)| key == "url")
			.map_or_else(String::new, |(_, value)| value.clone());
		let refresh = query.iter().any(|(key, value)| key == "refresh" && value == "1");
		return if path == "/link-preview/image" {
			environment
				.previews
				.image(&url, request.extensions().get::<std::net::IpAddr>().copied())
				.await
		} else {
			let reply = environment
				.previews
				.metadata(&url, refresh, request.extensions().get::<std::net::IpAddr>().copied())
				.await;
			for_listed_origin(reply, environment, &request)
		};
	}
	if matches!(path, "/trace" | "/trace/locator" | "/trace/captp" | "/publish") {
		let Some(current) = located(environment).await else {
			return response(
				StatusCode::SERVICE_UNAVAILABLE,
				"text/plain",
				"rooms: directory not ready\n".into(),
			);
		};
		let Some(address) = current.trace_address else {
			return response(
				if path == "/trace" || path == "/trace/locator" {
					StatusCode::NO_CONTENT
				} else {
					StatusCode::NOT_FOUND
				},
				"text/plain",
				Bytes::new(),
			);
		};
		if path == "/trace" {
			// The port, for a reader that dials the endpoint itself. A viewer's
			// socket goes to `/trace/captp`, so no socket is carried here.
			if request.headers().contains_key("upgrade") {
				return response(
					StatusCode::NOT_FOUND,
					"text/plain",
					"rooms: trace viewers connect at /trace/captp\n".into(),
				);
			}
			return response(StatusCode::OK, "text/plain", format!("{}\n", address.port()).into());
		}
		if path == "/trace/locator" {
			return match current.trace_locator {
				Some(locator) => response(StatusCode::OK, "text/plain", format!("{locator}\n").into()),
				None => response(
					StatusCode::SERVICE_UNAVAILABLE,
					"text/plain",
					"rooms: trace routing unavailable\n".into(),
				),
			};
		}
		// The query is carried so the endpoint, which refuses any, judges it.
		let query = request.uri().query().map(|q| format!("?{q}")).unwrap_or_default();
		let endpoint = if path == "/publish" { "/publish" } else { "/captp" };
		let address = crate::local_address(address);
		return environment
			.relay
			.proxy(request, format!("ws://{address}{endpoint}{query}"));
	}
	let Some(assets) = &environment.assets else {
		return response(
			StatusCode::NOT_FOUND,
			"text/plain",
			"rooms: browser assets disabled\n".into(),
		);
	};
	match assets.get(path).await {
		Ok(Some(asset)) => asset.response(&request),
		Ok(None) => response(StatusCode::NOT_FOUND, "text/plain", "rooms: asset not found\n".into()),
		Err(error) => {
			(environment.report)(super::Notice::AssetUnavailable(error));
			response(
				StatusCode::SERVICE_UNAVAILABLE,
				"text/plain",
				"rooms: asset unavailable\n".into(),
			)
		}
	}
}

/// Let a page origin the operator listed read this reply from its own page.
fn for_listed_origin<B>(mut reply: Reply, environment: &Environment, request: &Request<B>) -> Reply {
	reply
		.headers_mut()
		.insert("vary", hyper::header::HeaderValue::from_static("origin"));
	if let Some(origin) = environment.relay.listed_origin(request) {
		reply.headers_mut().insert("access-control-allow-origin", origin);
	}
	reply
}

/// The announced directory, waited for up to `LOCATION_WAIT` while it comes
/// up, and `None` once that passes or the front is stopping.
async fn located(environment: &Environment) -> Option<crate::server::readiness::Announcement> {
	let mut location = environment.location.clone();
	match tokio::time::timeout(LOCATION_WAIT, location.wait_for(Option::is_some)).await {
		Ok(Ok(current)) => current.clone(),
		_ => None,
	}
}

pub(super) fn response(status: StatusCode, content_type: &'static str, body: Bytes) -> Reply {
	let mut reply = Response::new(Full::new(body));
	*reply.status_mut() = status;
	let headers = reply.headers_mut();
	headers.insert("content-type", hyper::header::HeaderValue::from_static(content_type));
	headers.insert("cache-control", hyper::header::HeaderValue::from_static("no-store"));
	reply
}
