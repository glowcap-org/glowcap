//! Process composition for one managed Rooms workspace. Loam owns
//! authority, the runtime owns callbacks and effects, and adapters own I/O.
mod config;
pub mod control;
mod error;
mod local;
mod notice;
mod peer;
mod readiness;
mod transports;

pub use config::{Config, HELP, Transport};
pub use error::{Error, Worker};
pub use local::{Event, Local};
pub use notice::{Notice, Report};
pub use peer::Peer;

use std::future::Future;

/// Run one peer inside a current-thread `LocalSet` until `shutdown` resolves.
/// `ready` receives the workspace use sturdyref after storage and publication
/// are admitted; management is published independently. `report`
/// receives every failure that has no caller left to answer.
pub async fn run(
	config: Config,
	shutdown: impl Future<Output = ()>,
	ready: impl FnOnce(&str),
	report: Report,
) -> Result<(), Error> {
	let mut peer = Peer::open(config, report.clone()).await?;
	ready(peer.link());
	let result = peer.serve(shutdown).await;
	while let Err(cause) = peer.close().await {
		report(Notice::Activity {
			operation: "session close".into(),
			cause: glowcap::loam::refusal(cause.to_string()),
		});
		tokio::time::sleep(std::time::Duration::from_secs(1)).await;
	}
	result
}

#[cfg(test)]
mod tests;
