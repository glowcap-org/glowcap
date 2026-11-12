//! Bounded operator reads from a running HTTP front. These commands acquire no
//! server custody and need neither application source nor a browser compiler.
use bytes::Bytes;
use http_body_util::{BodyExt, Empty, Limited};
use hyper::Request;
use hyper_util::rt::TokioIo;
use std::time::Duration;
use tokio::net::TcpStream;

/// Why a read failed: nothing answered at the address, or the front
/// answered something this read refuses. Each text is the line an operator
/// reads, and a caller that offers a next step matches the kind.
pub(crate) enum Failure {
	Unreachable(String),
	Answered(String),
}
impl From<Failure> for String {
	fn from(failure: Failure) -> Self {
		match failure {
			Failure::Unreachable(text) | Failure::Answered(text) => text,
		}
	}
}
enum Field {
	Ready,
	Locator,
	Version,
	/// The link that opens the first allowed Rooms page with this server,
	/// or nothing when the operator allowed no page.
	Page,
}
/// The running front at one HTTP origin. The host and port are settled when
/// it is named, so no read can fail on the address.
struct Front {
	base: url::Url,
	host: String,
	port: u16,
}
impl Front {
	/// The front at `address`, an HTTP origin without a path, credentials, or
	/// query.
	fn at(address: &str) -> Result<Self, String> {
		let base = url::Url::parse(address).map_err(|_| "web status address is invalid")?;
		let invalid = || "web status needs an HTTP origin without a path, credentials or query".to_owned();
		if base.scheme() != "http"
			|| !base.username().is_empty()
			|| base.password().is_some()
			|| base.query().is_some()
			|| base.fragment().is_some()
			|| !matches!(base.path(), "" | "/")
			|| base.port() == Some(0)
		{
			return Err(invalid());
		}
		let host = base
			.host_str()
			.ok_or_else(invalid)?
			.trim_start_matches('[')
			.trim_end_matches(']')
			.to_owned();
		let port = base.port_or_known_default().ok_or_else(invalid)?;
		Ok(Self { base, host, port })
	}
	async fn locator(&self) -> Result<glowcap::Locator, Failure> {
		let text = self
			.read_optional("/locator")
			.await?
			.ok_or_else(|| Failure::Answered("web /locator is unavailable".into()))?;
		glowcap::parse_locator(&text).map_err(|_| Failure::Answered("web answered an invalid directory locator".into()))
	}
	async fn read(&self, path: &str) -> Result<String, String> {
		self.read_optional(path)
			.await?
			.ok_or_else(|| format!("web {path} is unavailable"))
	}
	/// One bounded GET: `None` for a 204, the trimmed body for a 200, and a
	/// refusal for anything else.
	async fn read_optional(&self, path: &str) -> Result<Option<String>, Failure> {
		let socket = TcpStream::connect((self.host.as_str(), self.port))
			.await
			.map_err(|e| Failure::Unreachable(format!("connecting to web status failed: {e}")))?;
		let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(socket))
			.await
			.map_err(|e| Failure::Answered(format!("opening web status HTTP failed: {e}")))?;
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
		let answer: Result<Option<String>, String> = tokio::select! {
			biased;
			result = &mut exchange => result,
			result = &mut connection => match result {
				Err(e) => Err(format!("web status connection failed: {e}")),
				// Driving a close-delimited response can finish the connection
				// in the same poll that makes its buffered answer readable.
				Ok(()) => exchange.await,
			},
		};
		answer.map_err(Failure::Answered)
	}
}
pub struct StatusQuery {
	front: Front,
	field: Field,
}
impl StatusQuery {
	/// The timeline's locator the front at `address` advertises, or `None`
	/// when it serves no timeline. Routing metadata contains no trace
	/// capability: private state supplies authority separately, while this
	/// read follows the current incarnation.
	pub(crate) async fn trace_locator(address: &str) -> Result<Option<glowcap::Locator>, Failure> {
		let front = Front::at(address).map_err(Failure::Answered)?;
		let text = tokio::time::timeout(Duration::from_secs(5), front.read_optional("/trace/locator"))
			.await
			.map_err(|_| Failure::Unreachable("trace discovery timed out".into()))??;
		text.map(|text| {
			glowcap::parse_locator(&text)
				.map_err(|e| Failure::Answered(format!("web answered an invalid trace locator: {e}")))
		})
		.transpose()
	}
	/// The directory locator the running front at `address` advertises.
	pub(crate) async fn directory_locator(address: &str) -> Result<glowcap::Locator, Failure> {
		let front = Front::at(address).map_err(Failure::Answered)?;
		tokio::time::timeout(Duration::from_secs(5), front.locator())
			.await
			.map_err(|_| Failure::Unreachable("web status query timed out".into()))?
	}
	/// The address a status read defaults to: the loopback front on
	/// `GLOWCAP_ROOMS_HTTP_PORT`, or 8080.
	pub(crate) fn local_address(env: impl Fn(&str) -> Option<String>) -> Result<String, String> {
		let port = env("GLOWCAP_ROOMS_HTTP_PORT").unwrap_or_else(|| "8080".into());
		let port = rooms_application::host::port(&port).ok_or("HTTP port must be an integer from 1 through 65535")?;
		if port == 0 {
			return Err("a status query needs the bound HTTP port".into());
		}
		Ok(format!("http://127.0.0.1:{port}"))
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
			"--page-link" => Field::Page,
			_ => return Ok(None),
		};
		if args.len() != 1 {
			return Err("a web status query takes no service options".into());
		}
		let address = match address {
			Some(value) => value.to_owned(),
			None => Self::local_address(env)?,
		};
		let front = Front::at(&address)?;
		Ok(Some(Self { front, field }))
	}
	/// The answer, or `None` for a page query when the operator allowed no
	/// page.
	pub async fn run(self) -> Result<Option<String>, String> {
		tokio::time::timeout(Duration::from_secs(5), async {
			match self.field {
				Field::Locator => {
					let locator = self.front.locator().await?;
					glowcap::format_locator_uri(&locator)
						.map(Some)
						.map_err(|_| "web answered an invalid directory locator".into())
				}
				Field::Version => self.version().await.map(Some),
				Field::Page => self.page().await,
				Field::Ready => {
					self.front.locator().await.map_err(String::from)?;
					self.version().await?;
					Ok(Some("rooms: ready".into()))
				}
			}
		})
		.await
		.map_err(|_| "web status query timed out")?
	}
	async fn version(&self) -> Result<String, String> {
		let text = self.front.read("/ui-version").await?;
		if text.is_empty() || text.len() > 128 || !text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
			return Err("web answered an invalid UI version".into());
		}
		Ok(text)
	}
	async fn page(&self) -> Result<Option<String>, String> {
		let Some(text) = self.front.read_optional("/page").await? else {
			return Ok(None);
		};
		let link = url::Url::parse(&text).map_err(|_| "web answered an invalid page link")?;
		Ok(Some(link.to_string()))
	}
}
