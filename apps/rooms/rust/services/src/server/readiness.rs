//! Private process readiness is separate from the public directory locator.
//! It carries routing metadata, never the operator capabilities printed to the
//! operator's stream. The schema and validation have one owner on both ends.
use serde::{Deserialize, Serialize};
const PREFIX: &str = "ROOMS-SERVER-READY ";
const SCHEMA: &str = "rooms-server/1";

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Announcement {
	schema: String,
	pub location: String,
	pub trace_port: Option<u16>,
	pub local_endpoint: Option<rooms_platform::serving::endpoint::Endpoint>,
}
impl Announcement {
	pub fn new(
		location: String,
		trace_port: Option<u16>,
		local_endpoint: Option<rooms_platform::serving::endpoint::Endpoint>,
	) -> Self {
		Self {
			schema: SCHEMA.into(),
			location,
			trace_port,
			local_endpoint,
		}
	}
	pub fn line(&self) -> String {
		format!(
			"{PREFIX}{}",
			serde_json::to_string(self).expect("readiness contains only text and a port")
		)
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
		if ready.trace_port == Some(0) {
			return Err("server readiness names an unbound timeline port".into());
		}
		if let Some(endpoint) = &ready.local_endpoint {
			endpoint.validate()?;
		}
		let locator = glowcap::parse_locator(&ready.location).map_err(|_| "server readiness locator is invalid")?;
		ready.location = glowcap::format_locator_uri(&locator).map_err(|_| "server readiness locator is invalid")?;
		Ok(ready)
	}
}
