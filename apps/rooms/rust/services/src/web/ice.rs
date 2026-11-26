//! The deployment keeps the issuer bearer. Browsers receive only validated,
//! expiring TURN records. Issuer work is bounded and never falls back silently.
use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::{Request, header::HeaderValue};
use hyper_util::rt::TokioIo;
use rooms_application::{
	admission::{Class, Refusal},
	ice::{Limits, Servers},
};
use std::{net::IpAddr, rc::Rc, sync::Arc, time::Duration};
use tokio::{net::TcpStream, sync::Semaphore};
use tokio_rustls::{TlsConnector, rustls::pki_types::ServerName};

const LIMITS: Limits = Limits {
	servers: glowcap::WEBRTC_MAX_ICE_SERVERS,
	urls: glowcap::WEBRTC_MAX_ICE_URLS_PER_SERVER,
	url_bytes: glowcap::WEBRTC_MAX_ICE_URL_BYTES,
	credential_bytes: glowcap::WEBRTC_MAX_ICE_CREDENTIAL_BYTES,
};
pub(super) struct Config {
	stun: Servers,
	issuer: Option<Issuer>,
}
struct Issuer {
	url: url::Url,
	authorization: HeaderValue,
	ttl: u32,
}
#[derive(serde::Deserialize)]
struct Issued<'a> {
	#[serde(borrow, rename = "iceServers")]
	servers: &'a serde_json::value::RawValue,
}
pub(super) enum Error {
	Admission(Refusal),
	Unavailable(String),
}
pub(super) struct Policy {
	admission: Rc<super::admission::Admission>,
	stun: Servers,
	issuer: Option<(Issuer, TlsConnector)>,
	capacity: Semaphore,
}
impl Config {
	pub fn read(env: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
		let stun = Servers::stun(env("GLOWCAP_ROOMS_ICE_SERVERS").as_deref(), LIMITS)?;
		let endpoint = env("GLOWCAP_ROOMS_TURN_CREDENTIALS_URL").unwrap_or_default();
		let token = env("GLOWCAP_ROOMS_TURN_BEARER_TOKEN").unwrap_or_default();
		let (endpoint, token) = (endpoint.trim(), token.trim());
		if endpoint.is_empty() != token.is_empty() {
			return Err("TURN credential URL and bearer token must be set together".into());
		}
		let issuer = if endpoint.is_empty() {
			None
		} else {
			let url = url::Url::parse(endpoint).map_err(|_| "TURN credential URL is invalid")?;
			if url.scheme() != "https"
				|| url.host_str().is_none()
				|| !url.username().is_empty()
				|| url.password().is_some()
				|| url.fragment().is_some()
			{
				return Err("TURN credential URL must be an HTTPS endpoint without userinfo or a fragment".into());
			}
			let ttl = env("GLOWCAP_ROOMS_TURN_TTL_SECONDS")
				.filter(|s| !s.trim().is_empty())
				.map(|s| s.trim().parse::<u32>())
				.transpose()
				.map_err(|_| "TURN TTL must be an integer")?
				.unwrap_or(86400);
			if !(300..=172800).contains(&ttl) {
				return Err("TURN TTL must be 300–172800 seconds".into());
			}
			let mut authorization = HeaderValue::from_str(&format!("Bearer {token}"))
				.map_err(|_| "TURN bearer token is not a valid HTTP field")?;
			authorization.set_sensitive(true);
			Some(Issuer {
				url,
				authorization,
				ttl,
			})
		};
		Ok(Self { stun, issuer })
	}
}
impl Policy {
	pub async fn open(config: Config, admission: Rc<super::admission::Admission>) -> Result<Self, String> {
		let issuer = match config.issuer {
			Some(issuer) => Some((
				issuer,
				TlsConnector::from(Arc::new(rooms_platform::tls::system_config().await?)),
			)),
			None => None,
		};
		Ok(Self {
			admission,
			stun: config.stun,
			issuer,
			capacity: Semaphore::new(16),
		})
	}
	pub async fn servers(&self, address: Option<IpAddr>) -> Result<Bytes, Error> {
		let servers = match &self.issuer {
			Some((issuer, tls)) => {
				let _slot = self
					.capacity
					.try_acquire()
					.map_err(|_| Error::Unavailable("TURN issuer request capacity exceeded".into()))?;
				self.admission
					.start(Class::HttpStart, address)
					.map_err(Error::Admission)?;
				let issued = tokio::time::timeout(Duration::from_secs(5), issuer.request(tls))
					.await
					.map_err(|_| Error::Unavailable("TURN credential request timed out".into()))?
					.map_err(Error::Unavailable)?;
				self.stun
					.with_turn(issued, LIMITS)
					.map_err(|error| Error::Unavailable(error.into()))?
			}
			None => self.stun.clone(),
		};
		serde_json::to_vec(&servers)
			.map(Bytes::from)
			.map_err(|_| Error::Unavailable("serializing ICE configuration failed".into()))
	}
}
impl Issuer {
	async fn request(&self, tls: &TlsConnector) -> Result<Servers, String> {
		let host = self.url.host_str().ok_or("TURN issuer has no host")?;
		let host = host.trim_start_matches('[').trim_end_matches(']');
		let socket = TcpStream::connect((host, self.url.port_or_known_default().unwrap_or(443)))
			.await
			.map_err(|_| "connecting to TURN issuer failed")?;
		let name = ServerName::try_from(host.to_owned()).map_err(|_| "TURN issuer TLS name is invalid")?;
		let socket = tls
			.connect(name, socket)
			.await
			.map_err(|_| "TURN issuer TLS handshake failed")?;
		let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(socket))
			.await
			.map_err(|_| "TURN issuer HTTP handshake failed")?;
		let exchange = async {
			let body = Full::new(Bytes::from(format!("{{\"ttl\":{}}}", self.ttl)));
			let request = Request::builder()
				.method("POST")
				.uri(&self.url[url::Position::BeforePath..])
				.header("host", &self.url[url::Position::BeforeHost..url::Position::AfterPort])
				.header("authorization", self.authorization.clone())
				.header("content-type", "application/json")
				.header("connection", "close")
				.body(body)
				.map_err(|_| "constructing TURN credential request failed")?;
			let response = sender
				.send_request(request)
				.await
				.map_err(|_| "TURN issuer HTTP request failed")?;
			if !response.status().is_success() {
				return Err(format!("TURN issuer refused ({})", response.status().as_u16()));
			}
			if let Some(length) = response.headers().get("content-length") {
				let length = length
					.to_str()
					.ok()
					.and_then(|s| s.parse::<u64>().ok())
					.ok_or("TURN issuer content length is invalid")?;
				if length > 64 * 1024 {
					return Err("TURN issuer response is too large".into());
				}
			}
			let body = Limited::new(response.into_body(), 64 * 1024)
				.collect()
				.await
				.map_err(|_| "TURN issuer body is invalid or too large")?
				.to_bytes();
			let issued: Issued<'_> =
				serde_json::from_slice(&body).map_err(|_| "TURN issuer returned malformed ICE configuration")?;
			Servers::from_json(issued.servers.get().as_bytes(), LIMITS).map_err(str::to_owned)
		};
		let connection = async { connection.await.map_err(|_| "TURN issuer connection failed".to_owned()) };
		tokio::try_join!(exchange, connection).map(|(servers, ())| servers)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::admission::Settings;

	#[tokio::test]
	async fn shared_http_budget_limits_turn_issuance_and_leaves_static_ice_available() {
		let settings =
			Settings::parse(|key| (key == "admission-rates").then(|| "http-start=1/1".into()), 32, 1).unwrap();
		let admission = super::super::admission::Admission::new(super::super::admission::Config {
			settings,
			per_address: true,
			trusted_proxies: Default::default(),
		});
		let address = Some(IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));
		let static_ice = Policy::open(Config::read(|_| None).unwrap(), admission.clone())
			.await
			.unwrap();
		let turn = Config::read(|name| match name {
			"GLOWCAP_ROOMS_TURN_CREDENTIALS_URL" => Some("https://issuer.invalid/".into()),
			"GLOWCAP_ROOMS_TURN_BEARER_TOKEN" => Some("test".into()),
			_ => None,
		})
		.unwrap();
		let turn = Policy::open(turn, admission.clone()).await.unwrap();
		assert!(static_ice.servers(address).await.is_ok());
		admission.start(Class::HttpStart, address).unwrap();
		assert!(matches!(
			turn.servers(address).await,
			Err(Error::Admission(Refusal::Throttled { .. }))
		));
		assert!(static_ice.servers(address).await.is_ok());
	}
}
