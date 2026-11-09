//! Print the directory's kept operator capabilities from beside a running web
//! front. The server's reader needs the locators the directory advertises to
//! print complete links, and the front already serves both, so this read
//! asks it instead of asking the operator to copy them into variables. The
//! state directory and the front are paired by the operator: under `serve`
//! and the deployment they are one server, and a read that names another
//! server's state prints links that server never minted.
use super::status::{Failure, StatusQuery};
use crate::server::{CapabilityQuery, TraceLocator};
use std::path::PathBuf;

pub struct CapabilityRead {
	directory: PathBuf,
	/// The front `--url` names, when the operator chose one.
	url: Option<String>,
}
impl CapabilityRead {
	/// `--print-capabilities[=<state-directory>] [--url=http://host:port]`,
	/// refused before anything is read. The directory defaults to
	/// `GLOWCAP_ROOMS_STATE`. Any other first argument is not this read.
	pub fn parse(args: &[String], env: impl Fn(&str) -> Option<String>) -> Result<Option<Self>, String> {
		let Some(first) = args.first() else { return Ok(None) };
		let directory = if first == "--print-capabilities" {
			env("GLOWCAP_ROOMS_STATE")
		} else if let Some(path) = first.strip_prefix("--print-capabilities=") {
			Some(path.to_owned())
		} else {
			return Ok(None);
		};
		let url = match &args[1..] {
			[] => None,
			[option] => match option.strip_prefix("--url=").filter(|url| !url.trim().is_empty()) {
				Some(url) => Some(url.to_owned()),
				None => {
					return Err(
						"--print-capabilities takes a state directory and at most --url=http://host:port".into(),
					);
				}
			},
			_ => {
				return Err("--print-capabilities takes a state directory and at most --url=http://host:port".into());
			}
		};
		let directory = directory
			.filter(|s| !s.trim().is_empty())
			.ok_or("use --print-capabilities=<state-directory> or set GLOWCAP_ROOMS_STATE")?;
		Ok(Some(Self {
			directory: directory.into(),
			url,
		}))
	}
	/// The front `--url` names answers with the locators. Otherwise a locator
	/// set in the environment wins, for a read with no front running, and
	/// then the front on the local HTTP port answers. When nothing answers,
	/// the refusal names both ways to supply the locator.
	pub async fn run(self, env: impl Fn(&str) -> Option<String>) -> Result<String, String> {
		let supplied = match &self.url {
			Some(_) => None,
			None => CapabilityQuery::environment_locators(&env).map_err(|e| e.to_string())?,
		};
		let (locator, trace) = match supplied {
			Some(supplied) => supplied,
			None => {
				let address = match self.url {
					Some(url) => url,
					None => StatusQuery::local_address(&env)?,
				};
				let remedy = |failure| match failure {
					Failure::Unreachable(cause) => format!(
						"nothing answered at {address} ({cause}); start the server with glowcap apps rooms serve or glowcap apps rooms deployment up, or set GLOWCAP_ROOMS_LOCATOR to the directory's advertised locator"
					),
					Failure::Answered(cause) => cause,
				};
				let locator = StatusQuery::directory_locator(&address).await.map_err(remedy)?;
				let trace = match StatusQuery::trace_locator(&address).await.map_err(remedy)? {
					Some(locator) => TraceLocator::Advertised(locator),
					None => TraceLocator::NotRunning,
				};
				(locator, trace)
			}
		};
		let query = CapabilityQuery::new(self.directory, locator, trace).map_err(|e| e.to_string())?;
		query.run().await.map_err(|e| e.to_string())
	}
}
