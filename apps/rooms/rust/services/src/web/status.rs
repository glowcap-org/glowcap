//! Bounded operator reads from a running HTTP front. These commands acquire no
//! server custody and need neither application source nor a browser compiler.
use bytes::Bytes;
use http_body_util::{BodyExt, Empty, Limited};
use hyper::Request;
use hyper_util::rt::TokioIo;
use std::time::Duration;
use tokio::net::TcpStream;

enum Field {
	Ready,
	Locator,
	Version,
}
pub struct StatusQuery {
	base: url::Url,
	field: Field,
}
impl StatusQuery {
	/// Routing metadata contains no trace capability. Private state supplies
	/// authority separately, while this read follows the current incarnation.
	pub(crate) async fn trace_locator(address: &str) -> Result<Option<glowcap::Locator>, String> {
		let args = [format!("--locator={address}")];
		let query = Self::parse(&args, |_| None)?.ok_or("web status named no query for the locator")?;
		let text = tokio::time::timeout(Duration::from_secs(5), query.read_optional("/trace/locator"))
			.await
			.map_err(|_| "trace discovery timed out")??;
		text.map(|text| {
			glowcap::parse_locator(&text).map_err(|e| format!("web answered an invalid trace locator: {e}"))
		})
		.transpose()
	}
	pub fn parse(args: &[String], env: impl Fn(&str) -> Option<String>) -> Result<Option<Self>, String> {
		let Some(first) = args.first() else { return Ok(None) };
		let (name, address) = first
			.split_once('=')
			.map(|(n, a)| (n, Some(a)))
			.unwrap_or((first, None));
		let field = match name {
			"--check-ready" => Field::Ready,
			"--locator" => Field::Locator,
			"--ui-version" => Field::Version,
			_ => return Ok(None),
		};
		if args.len() != 1 {
			return Err("a web status query takes no service options".into());
		}
		let address = match address {
			Some(value) => value.to_owned(),
			None => {
				let port = env("GLOWCAP_ROOMS_HTTP_PORT")
					.unwrap_or_else(|| "8080".into())
					.parse::<u16>()
					.map_err(|_| "HTTP port must be an integer from 1 through 65535")?;
				if port == 0 {
					return Err("a status query needs the bound HTTP port".into());
				}
				format!("http://127.0.0.1:{port}")
			}
		};
		let base = url::Url::parse(&address).map_err(|_| "web status address is invalid")?;
		if base.scheme() != "http"
			|| base.host_str().is_none()
			|| !base.username().is_empty()
			|| base.password().is_some()
			|| base.query().is_some()
			|| base.fragment().is_some()
			|| !matches!(base.path(), "" | "/")
			|| base.port() == Some(0)
		{
			return Err("web status needs an HTTP origin without a path, credentials or query".into());
		}
		Ok(Some(Self { base, field }))
	}
	pub async fn run(self) -> Result<String, String> {
		tokio::time::timeout(Duration::from_secs(5), async {
			match self.field {
				Field::Locator => self.locator().await,
				Field::Version => self.version().await,
				Field::Ready => {
					self.locator().await?;
					self.version().await?;
					Ok("rooms: ready".into())
				}
			}
		})
		.await
		.map_err(|_| "web status query timed out")?
	}
	async fn locator(&self) -> Result<String, String> {
		let text = self.read("/locator").await?;
		let locator = glowcap::parse_locator(&text).map_err(|_| "web answered an invalid directory locator")?;
		glowcap::format_locator_uri(&locator).map_err(|_| "web answered an invalid directory locator".into())
	}
	async fn version(&self) -> Result<String, String> {
		let text = self.read("/ui-version").await?;
		if text.is_empty() || text.len() > 128 || !text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
			return Err("web answered an invalid UI version".into());
		}
		Ok(text)
	}
	async fn read(&self, path: &str) -> Result<String, String> {
		self.read_optional(path)
			.await?
			.ok_or_else(|| format!("web {path} is unavailable"))
	}
	async fn read_optional(&self, path: &str) -> Result<Option<String>, String> {
		let host = self
			.base
			.host_str()
			.ok_or("web status address names no host")?
			.trim_start_matches('[')
			.trim_end_matches(']');
		let port = self
			.base
			.port_or_known_default()
			.ok_or("web status address names no port")?;
		let socket = TcpStream::connect((host, port))
			.await
			.map_err(|e| format!("connecting to web status failed: {e}"))?;
		let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(socket))
			.await
			.map_err(|e| format!("opening web status HTTP failed: {e}"))?;
		let exchange = async {
			let request = Request::builder()
				.uri(path)
				.header("host", &self.base[url::Position::BeforeHost..url::Position::AfterPort])
				.header("connection", "close")
				.body(Empty::<Bytes>::new())
				.map_err(|e| e.to_string())?;
			let response = sender.send_request(request).await.map_err(|e| e.to_string())?;
			if response.status() == hyper::StatusCode::NO_CONTENT {
				return Ok(None);
			}
			if response.status() != hyper::StatusCode::OK {
				return Err(format!("web {path} answered {}", response.status().as_u16()));
			}
			let body = Limited::new(response.into_body(), 4096)
				.collect()
				.await
				.map_err(|_| format!("web {path} answer is incomplete or exceeds 4096 bytes"))?
				.to_bytes();
			let text = std::str::from_utf8(&body).map_err(|_| format!("web {path} answer is not Unicode"))?;
			Ok(Some(text.trim().to_owned()))
		};
		tokio::pin!(exchange, connection);
		tokio::select! {
			biased;
			result = &mut exchange => result,
			result = &mut connection => {
				result.map_err(|e| format!("web status connection failed: {e}"))?;
				// Driving a close-delimited response can finish the connection
				// in the same poll that makes its buffered answer readable.
				exchange.await
			},
		}
	}
}
