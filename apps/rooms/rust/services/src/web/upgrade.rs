//! One HTTP upgrade boundary for byte relays and frame-preserving proxies.
use super::http::Reply;
use bytes::Bytes;
use http_body_util::Full;
use hyper::{Request, body::Incoming};
use hyper_util::rt::TokioIo;
use std::time::Duration;
use tokio::sync::watch;
use tokio_tungstenite::{
	WebSocketStream,
	tungstenite::protocol::{Role, WebSocketConfig},
};

pub(super) type Socket = WebSocketStream<TokioIo<hyper::upgrade::Upgraded>>;
pub(super) const MAX_MESSAGE: usize = 8 * 1024 * 1024;

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
pub(super) async fn accept(
	upgrading: hyper::upgrade::OnUpgrade,
	mut stop: watch::Receiver<bool>,
) -> Result<Socket, String> {
	let upgraded = tokio::select! {
		biased;
		_ = super::stopped(&mut stop) => return Err("web service is stopping".into()),
		result = tokio::time::timeout(Duration::from_secs(10), upgrading) => result
			.map_err(|_| "WebSocket upgrade timed out")?.map_err(|e| e.to_string())?,
	};
	Ok(WebSocketStream::from_raw_socket(TokioIo::new(upgraded), Role::Server, Some(config())).await)
}

pub(super) fn config() -> WebSocketConfig {
	WebSocketConfig::default()
		.max_message_size(Some(MAX_MESSAGE))
		.max_frame_size(Some(MAX_MESSAGE))
		.max_write_buffer_size(MAX_MESSAGE + 256 * 1024)
}
