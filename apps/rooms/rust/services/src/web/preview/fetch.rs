use bytes::Bytes;
use http_body_util::{BodyExt, Empty, LengthLimitError, Limited};
use hyper::{Request, StatusCode, header::HeaderMap};
use hyper_util::rt::TokioIo;
use rooms_application::open_graph::normalize_url;
use std::{
	net::{IpAddr, SocketAddr},
	time::Duration,
};
use tokio::{
	io::{AsyncRead, AsyncWrite},
	net::TcpStream,
};
use tokio_rustls::{TlsConnector, rustls::pki_types::ServerName};

const REDIRECTS: usize = 5;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Error {
	InvalidUrl,
	AddressBlocked,
	Dns,
	Connect,
	Tls,
	Http,
	Status,
	Redirect,
	Content,
	TooLarge,
}

pub(super) struct Fetched {
	pub final_url: String,
	pub content_type: String,
	pub body: Bytes,
}

pub(super) async fn get(tls: &TlsConnector, requested: &str, limit: usize, kind: Kind) -> Result<Fetched, Error> {
	let mut current = normalize_url(requested).ok_or(Error::InvalidUrl)?;
	for at in 0..=REDIRECTS {
		let response = one(tls, &current, limit, kind).await?;
		if response.status.is_redirection() {
			if at == REDIRECTS {
				return Err(Error::Redirect);
			}
			let location = response
				.headers
				.get("location")
				.and_then(|value| value.to_str().ok())
				.ok_or(Error::Redirect)?;
			let next = redirect(&current, location)?;
			current = next;
			continue;
		}
		if !response.status.is_success() {
			return Err(Error::Status);
		}
		let content_type = response
			.headers
			.get("content-type")
			.and_then(|value| value.to_str().ok())
			.unwrap_or("")
			.to_ascii_lowercase();
		if !kind.accepts(&content_type) {
			return Err(Error::Content);
		}
		return Ok(Fetched {
			final_url: current,
			content_type,
			body: response.body,
		});
	}
	Err(Error::Redirect)
}

fn redirect(current: &str, location: &str) -> Result<String, Error> {
	let base = url::Url::parse(current).map_err(|_| Error::Redirect)?;
	let next = base.join(location).map_err(|_| Error::Redirect)?;
	if base.scheme() == "https" && next.scheme() != "https" {
		return Err(Error::Redirect);
	}
	normalize_url(next.as_str()).ok_or(Error::Redirect)
}

#[derive(Clone, Copy)]
pub(super) enum Kind {
	Html,
	Image,
	Json,
}

impl Kind {
	fn accept(self) -> &'static str {
		match self {
			Self::Html => "text/html, application/xhtml+xml",
			Self::Image => "image/avif, image/gif, image/jpeg, image/png, image/webp",
			Self::Json => "application/json",
		}
	}

	fn accepts(self, value: &str) -> bool {
		let essence = value.split(';').next().unwrap_or("").trim();
		match self {
			Self::Html => matches!(essence, "text/html" | "application/xhtml+xml"),
			Self::Image => matches!(
				essence,
				"image/avif" | "image/gif" | "image/jpeg" | "image/png" | "image/webp"
			),
			Self::Json => essence == "application/json" || essence.ends_with("+json"),
		}
	}
}

struct Response {
	status: StatusCode,
	headers: HeaderMap,
	body: Bytes,
}

async fn one(tls: &TlsConnector, target: &str, limit: usize, kind: Kind) -> Result<Response, Error> {
	let url = url::Url::parse(target).map_err(|_| Error::InvalidUrl)?;
	let host = url.host_str().ok_or(Error::InvalidUrl)?;
	let port = url.port_or_known_default().ok_or(Error::InvalidUrl)?;
	let addresses = tokio::time::timeout(CONNECT_TIMEOUT, tokio::net::lookup_host((host, port)))
		.await
		.map_err(|_| Error::Dns)?
		.map_err(|_| Error::Dns)?
		.collect::<Vec<_>>();
	if addresses.is_empty() {
		return Err(Error::Dns);
	}
	if addresses.iter().any(|address| !public_preview_address(address.ip())) {
		return Err(Error::AddressBlocked);
	}
	let socket = connect(&addresses).await?;
	match url.scheme() {
		"http" => exchange(socket, &url, limit, kind).await,
		"https" => {
			let name = ServerName::try_from(host.to_owned()).map_err(|_| Error::Tls)?;
			let socket = tls.connect(name, socket).await.map_err(|_| Error::Tls)?;
			exchange(socket, &url, limit, kind).await
		}
		_ => Err(Error::InvalidUrl),
	}
}

async fn connect(addresses: &[SocketAddr]) -> Result<TcpStream, Error> {
	for address in addresses {
		if let Ok(Ok(socket)) = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(address)).await {
			return Ok(socket);
		}
	}
	Err(Error::Connect)
}

fn public_preview_address(address: IpAddr) -> bool {
	match address {
		IpAddr::V4(address) => public_preview_v4(address),
		IpAddr::V6(address) => {
			if let Some(mapped) = address.to_ipv4_mapped() {
				return public_preview_v4(mapped);
			}
			public_preview_v6(address)
		}
	}
}

/// Preview requests are an SSRF boundary, so Rooms explicitly defines which
/// public destinations they may contact. The standard library's equivalent
/// remains unstable on the pinned toolchain.
///
/// Range checks and the `192.0.0.9`/`.10` exceptions are adapted from
/// `ip_rfc` 0.1.0 (MIT OR Apache-2.0):
/// <https://github.com/pondurance/ip_rfc>. Rooms additionally refuses all
/// multicast, IPv4-mapped private addresses, and deprecated IPv6 site-local
/// destinations at this boundary.
fn public_preview_v4(address: std::net::Ipv4Addr) -> bool {
	let [a, b, c, _] = address.octets();
	if address == std::net::Ipv4Addr::new(192, 0, 0, 9) || address == std::net::Ipv4Addr::new(192, 0, 0, 10) {
		return true;
	}
	!(a == 0
		|| a == 10
		|| a == 127
		|| (a == 100 && (64..=127).contains(&b))
		|| (a == 169 && b == 254)
		|| (a == 172 && (16..=31).contains(&b))
		|| (a == 192 && b == 0 && c == 0)
		|| (a == 192 && b == 0 && c == 2)
		|| (a == 192 && b == 168)
		|| (a == 198 && matches!(b, 18 | 19))
		|| (a == 198 && b == 51 && c == 100)
		|| (a == 203 && b == 0 && c == 113)
		|| a >= 224)
}

fn public_preview_v6(address: std::net::Ipv6Addr) -> bool {
	let segments = address.segments();
	let [first, second, third, ..] = segments;
	// NAT64 (64:ff9b::/96) and its local-use sibling (64:ff9b:1::/48) carry an
	// IPv4 address in their low bits, so a private IPv4 destination has to be
	// refused through them as well as directly.
	let nat64 =
		(first == 0x0064 && second == 0xff9b && third == 0) || (first == 0x0064 && second == 0xff9b && third == 1);
	if nat64 {
		let [.., seventh, eighth] = segments;
		return public_preview_v4(std::net::Ipv4Addr::from(((seventh as u32) << 16) | eighth as u32));
	}
	!address.is_unspecified()
		&& !address.is_loopback()
		&& !address.is_multicast()
		&& first & 0xfe00 != 0xfc00 // fc00::/7 unique local
		&& first & 0xffc0 != 0xfe80 // fe80::/10 link local
		&& first & 0xffc0 != 0xfec0 // fec0::/10 deprecated site local
		&& !(first == 0x2001 && second == 0x0db8) // 2001:db8::/32 documentation
		&& !(first == 0x3fff && second & 0xf000 == 0) // 3fff::/20 documentation
		&& !(first == 0x2001 && second == 0) // 2001::/32 Teredo, embeds an IPv4 address
		&& !(first == 0x0100 && second == 0 && third == 0 && segments[3] == 0) // 100::/64 discard
}

async fn exchange<S>(stream: S, url: &url::Url, limit: usize, kind: Kind) -> Result<Response, Error>
where
	S: AsyncRead + AsyncWrite + Unpin,
{
	let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
		.await
		.map_err(|_| Error::Http)?;
	let request = Request::builder()
		.method("GET")
		.uri(&url[url::Position::BeforePath..])
		.header("host", &url[url::Position::BeforeHost..url::Position::AfterPort])
		.header("accept", kind.accept())
		.header("accept-encoding", "identity")
		.header("user-agent", "glowcap-rooms-link-preview/1")
		.header("connection", "close")
		.body(Empty::<Bytes>::new())
		.map_err(|_| Error::Http)?;
	let exchange = async {
		let response = sender.send_request(request).await.map_err(|_| Error::Http)?;
		if let Some(length) = response
			.headers()
			.get("content-length")
			.and_then(|value| value.to_str().ok())
			.and_then(|value| value.parse::<usize>().ok())
			&& length > limit
		{
			return Err(Error::TooLarge);
		}
		let status = response.status();
		let headers = response.headers().clone();
		let body = Limited::new(response.into_body(), limit)
			.collect()
			.await
			.map_err(|error| {
				if error.downcast_ref::<LengthLimitError>().is_some() {
					Error::TooLarge
				} else {
					Error::Http
				}
			})?
			.to_bytes();
		Ok(Response { status, headers, body })
	};
	let connection = async { connection.await.map_err(|_| Error::Http) };
	tokio::try_join!(exchange, connection).map(|(response, ())| response)
}

#[cfg(test)]
mod tests {
	use super::*;
	use http_body_util::Full;
	use hyper::{Response as HyperResponse, service::service_fn};

	async fn local_response(
		status: StatusCode,
		content_type: &'static str,
		body: &'static [u8],
		limit: usize,
	) -> Result<Response, Error> {
		let (client, server) = tokio::io::duplex(4096);
		let serving = hyper::server::conn::http1::Builder::new().serve_connection(
			TokioIo::new(server),
			service_fn(move |_| async move {
				Ok::<_, core::convert::Infallible>(
					HyperResponse::builder()
						.status(status)
						.header("content-type", content_type)
						.body(Full::new(Bytes::from_static(body)))
						.expect("fixed test response"),
				)
			}),
		);
		let url = url::Url::parse("http://example.com/").unwrap();
		let fetching = exchange(client, &url, limit, Kind::Html);
		let (fetched, served) = tokio::join!(fetching, serving);
		served.unwrap();
		fetched
	}

	#[test]
	fn public_preview_destinations_cover_non_public_ranges_and_their_boundaries() {
		for (address, expected) in [
			("0.255.255.255", false),
			("1.0.0.0", true),
			("9.255.255.255", true),
			("10.0.0.0", false),
			("10.255.255.255", false),
			("11.0.0.0", true),
			("100.63.255.255", true),
			("100.64.0.0", false),
			("100.127.255.255", false),
			("100.128.0.0", true),
			("127.255.255.255", false),
			("169.254.169.254", false),
			("172.15.255.255", true),
			("172.16.0.0", false),
			("172.31.255.255", false),
			("172.32.0.0", true),
			("192.0.0.8", false),
			("192.0.0.9", true),
			("192.0.0.10", true),
			("192.0.0.11", false),
			("192.0.2.1", false),
			("192.168.255.255", false),
			("198.17.255.255", true),
			("198.18.0.0", false),
			("198.19.255.255", false),
			("198.20.0.0", true),
			("198.51.100.1", false),
			("203.0.113.1", false),
			("223.255.255.255", true),
			("224.0.0.0", false),
			("255.255.255.255", false),
			("::", false),
			("::1", false),
			("fc00::1", false),
			("fdff:ffff::1", false),
			("fe80::1", false),
			("febf:ffff::1", false),
			("fec0::1", false),
			("feff:ffff::1", false),
			("ff0e::1", false),
			("2001:db8::1", false),
			("3fff::1", false),
			("3fff:fff:ffff::1", false),
			("2001::1", false),
			("2001:1::1", true),
			("100::1", false),
			("100:0:0:1::1", true),
			("64:ff9b::10.0.0.1", false),
			("64:ff9b::1.1.1.1", true),
			("64:ff9b:1::192.168.1.1", false),
			("::ffff:127.0.0.1", false),
			("::ffff:1.1.1.1", true),
			("1.1.1.1", true),
			("2606:4700:4700::1111", true),
		] {
			assert_eq!(public_preview_address(address.parse().unwrap()), expected, "{address}");
		}
	}

	#[test]
	fn redirects_preserve_https_and_normalize_the_next_identity() {
		assert_eq!(
			redirect("https://example.com/one", "/two#tracking").unwrap(),
			"https://example.com/two"
		);
		assert_eq!(
			redirect("https://example.com/", "http://example.com/"),
			Err(Error::Redirect)
		);
		assert_eq!(
			redirect("http://example.com/", "https://example.com/").unwrap(),
			"https://example.com/"
		);
	}

	#[tokio::test(flavor = "current_thread")]
	async fn exchange_distinguishes_status_content_and_body_limits() {
		assert_eq!(
			local_response(StatusCode::NOT_FOUND, "text/html", b"missing", 64)
				.await
				.unwrap()
				.status,
			StatusCode::NOT_FOUND
		);
		assert!(matches!(
			local_response(StatusCode::OK, "application/json", b"{}", 64)
				.await
				.and_then(|response| {
					Kind::Html
						.accepts(response.headers["content-type"].to_str().unwrap())
						.then_some(response)
						.ok_or(Error::Content)
				}),
			Err(Error::Content)
		));
		assert!(matches!(
			local_response(StatusCode::OK, "text/html", b"12345", 4).await,
			Err(Error::TooLarge)
		));
	}
}
