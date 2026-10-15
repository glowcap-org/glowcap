//! The host Rooms server: the directory every member registers with and
//! watches, the introductions and WebRTC signaling it relays between members,
//! and the rooms they open and enter, with their lines, files, topics,
//! invitations, and durable links. The policies are under
//! `rooms_application::server`. This tier owns the sessions, the clocks, the
//! work that runs outside a turn, the document, and the history on disk.
mod admission;
mod answer;
mod authority;
mod behavior;
mod capabilities;
mod config;
mod document;
mod error;
mod files;
mod history;
mod invitations;
mod irc;
mod lines;
mod notice;
mod operations;
mod peer;
pub(crate) mod readiness;
mod receipts;
mod registration;
mod rooms;
mod seat;
mod signaling;
mod state;

pub use capabilities::CapabilityQuery;
pub use config::{Config, HELP, Transport};
pub use error::Error;
pub use notice::{Notice, Report};
pub(crate) use operations::trace::locator as trace_locator;
pub use operations::{Asked, Minted};
pub use peer::{Peer, Ready};

use std::future::Future;

/// Run one server inside a current-thread `LocalSet` until `shutdown`
/// resolves. `ready` receives the locator partners dial and the operator
/// capabilities only after the document, identity, and listener are all
/// admitted. `report` receives every failure that has no caller left to
/// answer. A refusal from `ready` closes the peer and ends the run.
pub async fn run(
	config: Config,
	shutdown: impl Future<Output = ()>,
	ready: impl FnOnce(&Ready) -> Result<(), Error>,
	report: Report,
) -> Result<(), Error> {
	tokio::pin!(shutdown);
	let Some(peer) = Peer::open_until(config, report, shutdown.as_mut()).await? else {
		return Ok(());
	};
	if let Err(error) = peer.ready().and_then(|announced| ready(&announced)) {
		return Err(error.retain(peer.close().await));
	}
	peer.serve(shutdown).await
}

#[cfg(test)]
mod tests;
