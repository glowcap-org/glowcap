//! The host durable Rooms session peer. One process owns one member's
//! intended workspace: it reconnects the directories, rooms, and direct
//! conversations the checkpoint names, records what it is asked to keep, and
//! answers attached views over the administrator sturdyref and the grants it
//! publishes. [`peer::Peer`] owns host acceptance and readiness; the application lifecycle and capability verbs live in `rooms_runtime::service`; [`error::Error`] is the one failure vocabulary.
mod config;
mod error;
mod notice;
mod peer;
mod readiness;
mod trace;
mod transports;
mod verbs;

pub use config::{Config, HELP, Transport};
pub use error::{Error, Worker};
pub use notice::{Notice, Report};
pub use peer::Peer;

use std::future::Future;

/// Run one peer inside a current-thread `LocalSet` until `shutdown` resolves.
/// `ready` receives the administrator sturdyref only after identity, listener,
/// grants, and the administrator publication are all admitted; `report`
/// receives every failure that has no caller left to answer.
pub async fn run(
	config: Config,
	shutdown: impl Future<Output = ()>,
	ready: impl FnOnce(&str),
	report: Report,
) -> Result<(), Error> {
	let peer = Peer::open(config, report).await?;
	ready(peer.link());
	peer.serve(shutdown).await
}

#[cfg(test)]
mod tests;
