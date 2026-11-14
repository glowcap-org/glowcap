//! One HTTP upgrade boundary for byte relays and frame-preserving proxies.
use super::http::Reply;
use bytes::Bytes;
use http_body_util::Full;
use hyper::{Request, body::Incoming};
use hyper_util::rt::TokioIo;
use std::time::Duration;
use tokio::sync::watch;
use tokio_tungstenite::{WebSocketStream, tungstenite::protocol::Role};

pub(super) type Socket = WebSocketStream<TokioIo<hyper::upgrade::Upgraded>>;

pub(super) fn prepare(request: &mut Request<Incoming>) -> Result<(Reply, hyper::upgrade::OnUpgrade), &'static str> {
	let mut handshake = Request::new(());
	*handshake.method_mut() = request.method().clone();
	*handshake.uri_mut() = request.uri().clone();
	*handshake.version_mut() = request.version();
	*handshake.headers_mut() = request.headers().clone();
	let response = tokio_tungstenite::tungstenite::handshake::server::create_response(&handshake)
		.map_err(|_| "rooms: a WebSocket upgrade is required\n")?
		.map(|_| Full::new(Bytes::new()));
	Ok((response, hyper::upgrade::on(request)))
}
/// Take the upgraded socket, which reads no message larger than `largest`. A
/// socket holds one arriving message of that size before any byte budget
/// sees it.
pub(super) async fn accept(
	upgrading: hyper::upgrade::OnUpgrade,
	mut stop: watch::Receiver<bool>,
	largest: usize,
) -> Result<Socket, String> {
	let upgraded = tokio::select! {
		biased;
		_ = super::stopped(&mut stop) => return Err("web service is stopping".into()),
		result = tokio::time::timeout(Duration::from_secs(10), upgrading) => result
			.map_err(|_| "WebSocket upgrade timed out")?.map_err(|e| e.to_string())?,
	};
	let config = rooms_platform::websocket::config(largest);
	Ok(WebSocketStream::from_raw_socket(TokioIo::new(upgraded), Role::Server, Some(config)).await)
}
