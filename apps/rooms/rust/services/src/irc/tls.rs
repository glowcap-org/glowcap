use std::sync::Arc;
use tokio::{
	io::{AsyncRead, AsyncWrite},
	net::{TcpStream, lookup_host},
};
use tokio_rustls::{TlsConnector, rustls::pki_types::ServerName};

const TEST_LOOPBACK_ONLY: &str = "GLOWCAP_TEST_IRC_LOOPBACK_ONLY";

/// Validated dial inputs, without registration credentials.
#[derive(Clone)]
pub struct Endpoint {
	host: String,
	port: u16,
	tls: bool,
	loopback_only: bool,
}
impl Endpoint {
	pub fn new(host: &str, port: u16, tls: bool) -> Result<Self, String> {
		if host.is_empty() || host.len() > 255 || host.chars().any(|c| c.is_whitespace() || c.is_control()) || port == 0
		{
			return Err("IRC endpoint requires a bounded host and nonzero port".into());
		}
		let loopback_only = cfg!(test) || std::env::var_os(TEST_LOOPBACK_ONLY).is_some();
		Ok(Self {
			host: host.into(),
			port,
			tls,
			loopback_only,
		})
	}
	pub(super) fn encrypted(&self) -> bool {
		self.tls
	}
	pub(super) async fn connect(&self, tls: Option<&Tls>) -> Result<Box<dyn Stream>, String> {
		let socket = if self.loopback_only {
			if !loopback(&self.host) {
				return Err("IRC tests may dial only an explicit loopback endpoint".into());
			}
			let addresses: Vec<_> = lookup_host((self.host.as_str(), self.port))
				.await
				.map_err(|e| format!("IRC loopback lookup failed: {e}"))?
				.filter(|address| address.ip().is_loopback())
				.collect();
			if addresses.is_empty() {
				return Err("IRC test endpoint did not resolve to loopback".into());
			}
			TcpStream::connect(addresses.as_slice()).await
		} else {
			TcpStream::connect((self.host.as_str(), self.port)).await
		}
		.map_err(|e| format!("IRC TCP connect failed: {e}"))?;
		socket
			.set_nodelay(true)
			.map_err(|e| format!("IRC TCP setup failed: {e}"))?;
		if !self.tls {
			return Ok(Box::new(socket));
		}
		let tls = tls.ok_or("IRC TLS trust has not been loaded")?;
		let name = ServerName::try_from(self.host.clone()).map_err(|_| "IRC TLS server name is invalid")?;
		let stream = tls
			.0
			.connect(name, socket)
			.await
			.map_err(|e| format!("IRC TLS handshake failed: {e}"))?;
		Ok(Box::new(stream))
	}
}

fn loopback(host: &str) -> bool {
	host.eq_ignore_ascii_case("localhost")
		|| host
			.parse::<std::net::IpAddr>()
			.is_ok_and(|address| address.is_loopback())
}

pub(super) trait Stream: AsyncRead + AsyncWrite + Unpin {}
impl<T: AsyncRead + AsyncWrite + Unpin> Stream for T {}

/// Shared trust configuration; loading the system store runs off the LocalSet.
#[derive(Clone)]
pub struct Tls(TlsConnector);
impl Tls {
	pub async fn system() -> Result<Self, String> {
		let config = rooms_platform::tls::system_config()
			.await
			.map_err(|e| format!("IRC {e}"))?;
		Ok(Self(TlsConnector::from(Arc::new(config))))
	}
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod endpoint_tests {
	use super::Endpoint;

	#[tokio::test]
	async fn tests_refuse_non_loopback_before_resolution_or_dialing() {
		assert!(
			Endpoint::new("irc.libera.chat", 6697, true)
				.unwrap()
				.connect(None)
				.await
				.err()
				.unwrap()
				.contains("only an explicit loopback")
		);
		for host in ["localhost", "LOCALHOST", "127.0.0.1", "127.12.34.56", "::1"] {
			assert!(Endpoint::new(host, 1, false).is_ok(), "{host}");
		}
	}
}
