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
/// are admitted, followed by its independent management sturdyref. `report`
/// receives every failure that has no caller left to answer.
pub async fn run(
	config: Config,
	shutdown: impl Future<Output = ()>,
	ready: impl FnOnce(&str, &str),
	report: Report,
) -> Result<(), Error> {
	let peer = Peer::open(config, report).await?;
	ready(peer.link(), peer.management_link());
	peer.run(shutdown).await
}

#[cfg(test)]
mod tests;
