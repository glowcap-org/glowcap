//! Browser-facing ICE records. The host supplies its transport's resource
//! limits. Validation and the public record shape are identical on both hosts.
use alloc::{
	string::{String, ToString},
	vec,
	vec::Vec,
};
use serde::Serialize;
use serde_json::Value;
mod decode;

#[derive(Clone, Copy)]
pub struct Limits {
	pub servers: usize,
	pub urls: usize,
	pub url_bytes: usize,
	pub credential_bytes: usize,
}
#[derive(Clone, Serialize)]
#[serde(untagged)]
enum Urls {
	One(String),
	Many(Vec<String>),
}
#[derive(Clone, Serialize)]
pub struct Server {
	urls: Urls,
	#[serde(skip_serializing_if = "Option::is_none")]
	username: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	credential: Option<String>,
}
#[derive(Clone, Serialize)]
#[serde(transparent)]
pub struct Servers(Vec<Server>);
impl Server {
	/// Borrow validated URLs without changing the record's original wire shape.
	pub fn urls(&self) -> &[String] {
		match &self.urls {
			Urls::One(url) => core::slice::from_ref(url),
			Urls::Many(urls) => urls,
		}
	}
	pub fn username(&self) -> Option<&str> {
		self.username.as_deref()
	}
	pub fn credential(&self) -> Option<&str> {
		self.credential.as_deref()
	}
}
impl Servers {
	pub fn iter(&self) -> impl ExactSizeIterator<Item = &Server> {
		self.0.iter()
	}
	pub fn parse(value: &Value, limits: Limits) -> Result<Self, &'static str> {
		decode::read(value, limits)
	}
	/// Decode directly into bounded records. Transport callers bound the input
	/// bytes first. No unrestricted JSON tree is allocated before count checks.
	pub fn from_json(bytes: &[u8], limits: Limits) -> Result<Self, &'static str> {
		let mut input = serde_json::Deserializer::from_slice(bytes);
		let servers = decode::read(&mut input, limits)?;
		input.end().map_err(|_| "ICE response has trailing data")?;
		Ok(servers)
	}
	pub fn stun(configured: Option<&str>, limits: Limits) -> Result<Self, &'static str> {
		let configured = configured.unwrap_or("stun:stun.cloudflare.com:3478");
		let records = if configured.trim().is_empty() {
			vec![]
		} else {
			configured
				.split(',')
				.map(|url| serde_json::json!({"urls": url}))
				.collect()
		};
		Self::parse(&Value::Array(records), limits)
	}
	pub fn with_turn(&self, mut issued: Self, limits: Limits) -> Result<Self, &'static str> {
		issued.0.retain_mut(|server| match &mut server.urls {
			Urls::One(url) => decode::is_turn(url),
			Urls::Many(urls) => {
				urls.retain(|url| decode::is_turn(url));
				!urls.is_empty()
			}
		});
		if issued.0.is_empty() {
			return Err("credential issuer returned no TURN server");
		}
		if self.0.len() + issued.0.len() > limits.servers {
			return Err("combined ICE configuration has too many servers");
		}
		let mut combined = self.clone();
		combined.0.append(&mut issued.0);
		Ok(combined)
	}
}

#[cfg(test)]
mod tests;
