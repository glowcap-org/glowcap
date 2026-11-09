//! Print the directory's kept operator capabilities from beside a running web
//! front. The server's reader needs the locators the directory advertises to
//! print complete recipes, and the front already serves both, so this read
//! asks it instead of asking the operator to copy them into variables. The
//! state directory and the front are paired by the operator: under `serve`
//! and the deployment they are one server, and a read that names another
//! server's state prints recipes that server never minted.
use super::status::{Failure, StatusQuery};
use crate::server::{CapabilityQuery, TraceLocator};
use std::path::PathBuf;

pub struct CapabilityRead {
	directory: PathBuf,
}
impl CapabilityRead {
	/// `--print-capabilities[=<state-directory>]`, the same form `rooms-server`
	/// takes, refused for the same reasons before anything is read. Any other
	/// first argument is not this read.
	pub fn parse(args: &[String], env: impl Fn(&str) -> Option<String>) -> Result<Option<Self>, String> {
		let directory = CapabilityQuery::arguments(args, env).map_err(|e| e.to_string())?;
		Ok(directory.map(|directory| Self { directory }))
	}
	/// A locator set in the environment wins, for a read with no front
	/// running. Otherwise the front on the local HTTP port answers, and when
	/// nothing answers the refusal names both ways to supply the locator.
	pub async fn run(self, env: impl Fn(&str) -> Option<String>) -> Result<String, String> {
		let (locator, trace) = match CapabilityQuery::environment_locators(&env).map_err(|e| e.to_string())? {
			Some(supplied) => supplied,
			None => {
				let address = StatusQuery::local_address(&env)?;
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
