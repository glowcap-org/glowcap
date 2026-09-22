//! Resolve an explicitly chosen directory URL. Unlike link previews, the user
//! may select private hosts. TLS is verified; redirects never downgrade HTTPS.
use super::Failure;
use bytes::Bytes;
use http_body_util::{BodyExt, Empty, LengthLimitError, Limited};
use hyper_util::rt::TokioIo;
use std::{sync::Arc, time::Duration};
use tokio::{
	io::{AsyncRead, AsyncWrite},
	net::TcpStream,
};

const MAX_LOCATOR_BYTES: usize = 4096;

pub async fn resolve(locator: &str) -> Result<String, Failure> {
	if !locator.starts_with("http://") && !locator.starts_with("https://") {
		return Ok(locator.into());
	}
	let origin = url::Url::parse(locator)
		.map_err(Failure::invalid)?
		.origin()
		.ascii_serialization();
	tokio::time::timeout(Duration::from_secs(10), fetch(locator))
		.await
		.unwrap_or_else(|_| {
			Err(Failure::new(
				"timeout",
				"after-state-change",
				"request timed out after 10 seconds",
			))
		})
		.map_err(|mut error| {
			// Query strings and redirect locations may contain authentication tokens.
			error.message = format!("directory bootstrap at {origin}: {}", error.message);
			error
		})
}
async fn fetch(locator: &str) -> Result<String, Failure> {
	let mut url = url::Url::parse(locator).map_err(Failure::invalid)?;
	for _ in 0..5 {
		if !["http", "https"].contains(&url.scheme()) {
			return Err(Failure::invalid("bootstrap requires HTTP or HTTPS"));
		}
		if !url.username().is_empty() || url.password().is_some() {
			return Err(Failure::invalid("bootstrap URL must not contain credentials"));
		}
		let host = url
			.host_str()
			.ok_or_else(|| Failure::invalid("bootstrap needs a host"))?
			.to_owned();
		let port = url
			.port_or_known_default()
			.ok_or_else(|| Failure::invalid("bootstrap requires HTTP or HTTPS"))?;
		let socket = TcpStream::connect((host.as_str(), port)).await?;
		let (status, location, bytes) = if url.scheme() == "https" {
			let config = rooms_platform::tls::system_config()
				.await
				.map_err(|e| Failure::new("tls", "after-state-change", e))?;
			let name = tokio_rustls::rustls::pki_types::ServerName::try_from(host).map_err(Failure::invalid)?;
			let socket = tokio_rustls::TlsConnector::from(Arc::new(config))
				.connect(name, socket)
				.await?;
			exchange(socket, &url).await?
		} else if url.scheme() == "http" {
			exchange(socket, &url).await?
		} else {
			return Err(Failure::invalid("bootstrap requires HTTP or HTTPS"));
		};
		if status.is_redirection() {
			let next = url
				.join(
					location
						.as_deref()
						.ok_or_else(|| Failure::invalid("redirect lacks a location"))?,
				)
				.map_err(Failure::invalid)?;
			if url.scheme() == "https" && next.scheme() != "https" {
				return Err(Failure::invalid("bootstrap redirect would downgrade HTTPS"));
			}
			url = next;
			continue;
		}
		let text = std::str::from_utf8(&bytes)
			.map_err(|_| Failure::new("bootstrap", "after-state-change", "response is not UTF-8 locator text"))?
			.trim();
		if !text.starts_with("ocapn://") || text.chars().any(char::is_whitespace) {
			return Err(Failure::new(
				"bootstrap",
				"after-state-change",
				"response must contain one plain ocapn:// locator; check the /locator endpoint and its access policy",
			));
		}
		return Ok(text.into());
	}
	Err(Failure::invalid("too many bootstrap redirects"))
}
async fn exchange<S: AsyncRead + AsyncWrite + Unpin>(
	socket: S,
	url: &url::Url,
) -> Result<(hyper::StatusCode, Option<String>, Bytes), Failure> {
	let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(socket))
		.await
		.map_err(|e| Failure::new("http", "after-state-change", e))?;
	let request = hyper::Request::builder()
		.uri(&url[url::Position::BeforePath..])
		.header("host", &url[url::Position::BeforeHost..url::Position::AfterPort])
		.header("connection", "close")
		.body(Empty::<Bytes>::new())
		.map_err(Failure::invalid)?;
	let exchange = async {
		let response = sender
			.send_request(request)
			.await
			.map_err(|e| Failure::new("http", "after-state-change", e))?;
		let status = response.status();
		// Classify the response before reading its body: an error/login page or
		// redirect document is not a locator and must not mask its status with a
		// body limit error. Do not print remote HTML or authentication tokens.
		if !status.is_success() && !status.is_redirection() {
			return Err(Failure::new(
				"http",
				"after-state-change",
				format!("HTTP {status}; check endpoint access (browser login is not shared with this session)"),
			));
		}
		let location = response
			.headers()
			.get("location")
			.and_then(|v| v.to_str().ok())
			.map(str::to_owned);
		if status.is_redirection() {
			return Ok((status, location, Bytes::new()));
		}
		if response
			.headers()
			.get("content-type")
			.and_then(|v| v.to_str().ok())
			.is_some_and(|kind| {
				let mime = kind.split(';').next().unwrap_or("").trim();
				mime.eq_ignore_ascii_case("text/html") || mime.eq_ignore_ascii_case("application/xhtml+xml")
			}) {
			return Err(Failure::new(
				"bootstrap",
				"after-state-change",
				"received HTML instead of a locator, possibly an access-gateway login page; browser login is not shared with this session. Supply an agent-accessible /locator URL or a directory ocapn:// locator; do not disable access controls",
			));
		}
		let body = Limited::new(response.into_body(), MAX_LOCATOR_BYTES)
			.collect()
			.await
			.map_err(|error| {
				if error.is::<LengthLimitError>() {
					Failure::new("bootstrap", "after-state-change", format!("response exceeds the {MAX_LOCATOR_BYTES}-byte locator limit; check that /locator returns locator text, not a login or error page"))
				} else {
					Failure::new("http", "after-state-change", format!("could not read locator response: {error}"))
				}
			})?
			.to_bytes();
		Ok((status, location, body))
	};
	// The request owns the connection. Once the response is accepted or refused,
	// drop it without waiting for an unused body or a server to close its socket.
	tokio::pin!(exchange);
	tokio::select! {
		biased;
		result = &mut exchange => result,
		result = connection => {
			result.map_err(|e| Failure::new("http", "after-state-change", e))?;
			exchange.await
		}
	}
}

#[cfg(test)]
#[path = "bootstrap_tests.rs"]
mod tests;
