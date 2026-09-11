//! One shutdown order for partial startup and a running session.
use super::{directs::DirectGraph, error::Error, facet::Facet, workers::Workers, Platform};
use crate::{
	archive_shares::ArchiveShares,
	directory_runtime::{handed_rooms::HandedRooms, DirectoryRuntime},
	grant_commands::GrantCommands,
	room_offers::RoomOffers,
	rooms::RoomRuntime,
	session_archive::SessionArchive,
	session_commands::SessionCommands,
};
use std::rc::Rc;
/// The owners the peer composes, in the order they are opened. Closing walks
/// the same list backward-by-dependency from either a failed `open` or a
/// finished `serve`, so there is exactly one shutdown order to get right.
pub(super) struct Owners<P: Platform> {
	pub(super) commands: Option<SessionCommands>,
	pub(super) archive: Option<Rc<SessionArchive<P>>>,
	pub(super) directories: Option<DirectoryRuntime<P>>,
	pub(super) handed: Option<HandedRooms<P>>,
	pub(super) shares: Option<ArchiveShares>,
	pub(super) offers: Option<RoomOffers<P>>,
	pub(super) rooms: Option<RoomRuntime<P>>,
	pub(super) directs: Option<DirectGraph<P>>,
	pub(super) facet: Option<Facet<P>>,
	pub(super) grants: Option<GrantCommands>,
	pub(super) workers: Workers,
	pub(super) root: Option<Publication>,
}

impl<P: Platform> Owners<P> {
	pub(super) fn new(commands: SessionCommands) -> Self {
		Self {
			commands: Some(commands),
			archive: None,
			directories: None,
			handed: None,
			shares: None,
			offers: None,
			rooms: None,
			directs: None,
			facet: None,
			grants: None,
			workers: Workers::new(),
			root: None,
		}
	}
	pub(super) async fn close(mut self) -> Result<(), Error> {
		let mut result: Result<(), Error> = Ok(());
		let mut fold = |outcome: Result<(), Error>| {
			let prior = std::mem::replace(&mut result, Ok(()));
			result = Error::fold(prior, outcome);
		};
		if let Some(facet) = self.facet.take() {
			// Stop answering and drop attached views before anything they name.
			fold(facet.close().await);
		}
		if let Some(mut root) = self.root.take() {
			fold(root.close());
		}
		if let Some(grants) = self.grants.take() {
			fold(grants.close().await.map_err(Error::runtime));
		}
		// Owners retire in reverse dependency order: each waits for its own
		// worker, so a later owner never sees an earlier one half-closed.
		if let Some(directs) = self.directs.take() {
			fold(directs.close().await);
		}
		if let Some(offers) = self.offers.take() {
			fold(offers.close().await.map_err(Error::runtime));
		}
		if let Some(handed) = self.handed.take() {
			fold(handed.close().await.map_err(Error::runtime));
		}
		if let Some(shares) = self.shares.take() {
			shares.close();
		}
		if let Some(rooms) = self.rooms.take() {
			fold(rooms.close().await.map_err(Error::runtime));
		}
		if let Some(directories) = self.directories.take() {
			fold(directories.close().await.map_err(Error::runtime));
		}
		if let Some(commands) = self.commands.take() {
			fold(commands.close().await.map_err(Error::runtime));
		}
		if let Some(archive) = self.archive.take() {
			fold(archive.close().await.map(|_| ()).map_err(Error::runtime));
		}
		fold(self.workers.join().await);
		result
	}
}

/// Removing a name never revokes another publication on the same Host.
pub(super) struct Publication {
	host: glowcap::Host,
	name: Option<String>,
}
impl Publication {
	pub(super) fn new(host: glowcap::Host, name: String) -> Self {
		Self { host, name: Some(name) }
	}
	pub(super) fn name(&self) -> &str {
		self.name.as_deref().expect("live session root")
	}
	fn close(&mut self) -> Result<(), Error> {
		if let Some(name) = &self.name {
			self.host.remove_durable(name)?;
			self.name = None;
		}
		Ok(())
	}
}
impl Drop for Publication {
	fn drop(&mut self) {
		let _ = self.close();
	}
}

impl<P: Platform> Drop for Owners<P> {
	fn drop(&mut self) {
		// Cancellation cannot keep held actors admitting work after their
		// workers disappear. Orderly close additionally observes every task.
		if let Some(facet) = &self.facet {
			facet.stop();
		}
		self.workers.stop();
	}
}
