use std::sync::Arc;
use tokio::{
	io::{AsyncRead, AsyncWrite},
	net::TcpStream,
};
use tokio_rustls::{rustls::pki_types::ServerName, TlsConnector};

/// Validated dial inputs, without registration credentials.
#[derive(Clone)]
pub struct Endpoint {
	host: String,
	port: u16,
	tls: bool,
}
impl Endpoint {
	pub fn new(host: &str, port: u16, tls: bool) -> Result<Self, String> {
		if host.is_empty() || host.len() > 255 || host.chars().any(|c| c.is_whitespace() || c.is_control()) || port == 0
		{
			return Err("IRC endpoint requires a bounded host and nonzero port".into());
		}
		Ok(Self {
			host: host.into(),
			port,
			tls,
		})
	}
	pub(super) fn encrypted(&self) -> bool {
		self.tls
	}
	pub(super) async fn connect(&self, tls: Option<&Tls>) -> Result<Box<dyn Stream>, String> {
		let socket = TcpStream::connect((self.host.as_str(), self.port))
			.await
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

pub(super) trait Stream: AsyncRead + AsyncWrite + Unpin {}
impl<T: AsyncRead + AsyncWrite + Unpin> Stream for T {}

/// Shared trust configuration; loading the system store runs off the LocalSet.
#[derive(Clone)]
pub struct Tls(TlsConnector);
impl Tls {
	pub async fn system() -> Result<Self, String> {
		let config = crate::tls::system_config().await.map_err(|e| format!("IRC {e}"))?;
		Ok(Self(TlsConnector::from(Arc::new(config))))
	}
}

#[cfg(test)]
mod tests;
