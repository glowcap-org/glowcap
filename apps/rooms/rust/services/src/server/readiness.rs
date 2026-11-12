//! Private process readiness is separate from the public directory locator.
//! It carries routing metadata. A supervised server's record also carries the
//! operator capability lines the server minted, so the supervisor that reads
//! it owns the whole presentation and prints them beside its own. The schema
//! and validation have one owner on both ends.
use serde::{Deserialize, Serialize};

/// The warning both startup blocks print above the `ROOMS-*` lines.
pub const KEEP_LINKS_PRIVATE: &str = "keep each link below private, because whoever holds it has its power";
/// The longest announcement line a supervisor reads: the locator, the trace
/// locator, the local endpoint, and one line per boot capability plus the
/// timeline listener's, each at most a sturdyref with its token and quoting.
pub(crate) const MAX_LINE_BYTES: usize = (rooms_application::server::operations::BOOT_CAPABILITIES.len() + 4)
	* (glowcap::loam::ReferenceRequest::MAX_URI_BYTES + 128);
const PREFIX: &str = "ROOMS-SERVER-READY ";
const SCHEMA: &str = "rooms-server/1";

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Announcement {
	schema: String,
	pub location: String,
	pub trace_address: Option<std::net::SocketAddr>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub trace_locator: Option<String>,
	pub local_endpoint: Option<rooms_platform::serving::endpoint::Endpoint>,
	/// The flush-left `ROOMS-* <link>` lines the operator keeps, in the
	/// server's order. Present only in a supervised server's record.
	#[serde(default, skip_serializing_if = "Vec::is_empty")]
	pub capabilities: Vec<String>,
}
impl Announcement {
	pub fn new(
		location: String,
		trace_address: Option<std::net::SocketAddr>,
		local_endpoint: Option<rooms_platform::serving::endpoint::Endpoint>,
	) -> Self {
		Self {
			schema: SCHEMA.into(),
			location,
			trace_address,
			trace_locator: None,
			local_endpoint,
			capabilities: Vec::new(),
		}
	}
	/// The one line a supervisor reads. A local endpoint whose path is not
	/// Unicode has no JSON form and is refused here.
	pub fn line(&self) -> Result<String, String> {
		let json = serde_json::to_string(self).map_err(|e| format!("server readiness cannot be rendered: {e}"))?;
		Ok(format!("{PREFIX}{json}"))
	}
	pub fn parse(line: &str) -> Result<Self, String> {
		let json = line
			.trim()
			.strip_prefix(PREFIX)
			.ok_or("server did not publish structured readiness")?;
		let mut ready: Self = serde_json::from_str(json).map_err(|_| "server readiness record is malformed")?;
		if ready.schema != SCHEMA {
			return Err("server readiness schema is unsupported".into());
		}
		if ready.trace_address.is_some_and(|address| address.port() == 0) {
			return Err("server readiness names an unbound timeline port".into());
		}
		if let Some(locator) = &ready.trace_locator {
			let parsed = glowcap::parse_locator(locator).map_err(|_| "server trace locator is invalid")?;
			let endpoint = parsed
				.require_string_hint(rooms_application::web_channel::HINT)
				.map_err(|_| "server trace locator needs a byte channel")?;
			rooms_application::web_channel::endpoint(endpoint)?;
		}
		if let Some(endpoint) = &ready.local_endpoint {
			endpoint.validate()?;
		}
		if ready
			.capabilities
			.iter()
			.any(|line| !line.starts_with("ROOMS-") || line.chars().any(char::is_control))
		{
			return Err("server readiness capability lines are malformed".into());
		}
		let locator = glowcap::parse_locator(&ready.location).map_err(|_| "server readiness locator is invalid")?;
		ready.location = glowcap::format_locator_uri(&locator).map_err(|_| "server readiness locator is invalid")?;
		Ok(ready)
	}
}
