//! Typed handoff from the Zig command parser. Validate operation prerequisites
//! before opening a workspace; argv syntax and discovery stay in the CLI.
use super::Failure;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf};
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Options {
	pub verb: String,
	pub state: PathBuf,
	pub named: BTreeMap<String, Vec<String>>,
	pub arguments: Vec<String>,
}
impl Options {
	pub fn get(&self, key: &str) -> Option<&str> {
		self.named.get(key)?.first().map(String::as_str)
	}
	pub fn values(&self, key: &str) -> Vec<String> {
		self.named.get(key).cloned().unwrap_or_default()
	}
	pub fn number(&self, key: &str, default: u64) -> Result<u64, Failure> {
		self.get(key)
			.map(|v| {
				v.parse()
					.map_err(|_| Failure::invalid(format!("--{key} needs an unsigned integer")))
			})
			.unwrap_or(Ok(default))
	}
	pub fn read(body: &str) -> Result<Self, Failure> {
		if body.len() > 1024 * 1024 {
			return Err(Failure::exhausted("Rooms command exceeds 1 MiB"));
		}
		let mut options: Self = serde_json::from_str(body)?;
		if options.state.as_os_str().is_empty() {
			return Err(Failure::invalid("--dir is required"));
		}
		options.state = std::path::absolute(&options.state)?;
		if options.number("wait", 30)? > 30 {
			return Err(Failure::invalid("--wait must be 0..30"));
		}
		for id in options.values("id") {
			id.parse::<u64>()
				.map_err(|_| Failure::invalid("--id needs an unsigned integer"))?;
		}
		if matches!(options.verb.as_str(), "reply" | "leave") {
			let count = ["id", "room", "dm", "conversation"]
				.iter()
				.filter(|k| options.get(k).is_some())
				.count();
			if count != 1 {
				return Err(Failure::invalid("choose exactly one reply or leave target"));
			}
		}
		for required in match options.verb.as_str() {
			"reply" => &["text"][..],
			"join" => &["room"][..],
			"dismiss" => &["id"][..],
			"resume" => &["accept-gap"][..],
			_ => &[],
		} {
			if options.get(required).is_none() {
				return Err(Failure::invalid(format!("--{required} is required")));
			}
		}
		if options.verb == "command" && options.arguments.is_empty() {
			return Err(Failure::invalid("command needs an application command name"));
		}
		if let Some(transport) = options.get("transport")
			&& !["iroh", "tcp", "onion"].contains(&transport)
		{
			return Err(Failure::invalid("transport must be iroh, tcp, or onion"));
		}
		if let Some(reachability) = options.get("reachability")
			&& !["discovery", "direct"].contains(&reachability)
		{
			return Err(Failure::invalid("reachability must be discovery or direct"));
		}
		Ok(options)
	}
}
