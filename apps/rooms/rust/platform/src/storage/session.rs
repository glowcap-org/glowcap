//! Native custody for private session bootstrap metadata. The directory lease
//! survives every persisted stage. Opening never imports retired grant documents.
use super::{Directory, StorageError, atomic, read};
use crate::HostPlatform;
use glowcap::{
	Host, Result,
	loam::{self, Limits, Store},
};
use rooms_runtime::session::managed::{Bootstrap, BootstrapOptions, Opened, schemas};
use std::{num::NonZeroUsize, path::Path, sync::Arc};

const METADATA: &str = "rooms-bootstrap";
const STORE: &str = "loam";
#[cfg(test)]
mod tests;

/// Exclusive session-directory ownership, acquired before startup mirrors or
/// private metadata can be changed.
pub struct Custody {
	directory: Arc<Directory>,
}
impl Custody {
	/// Acquire exclusive ownership before changing this session's startup files.
	pub fn acquire(path: &Path) -> Result<Self> {
		Ok(Self {
			directory: Arc::new(Directory::open(path.to_owned(), ".rooms-session.lock").map_err(storage)?),
		})
	}
	pub fn directory(&self) -> &Arc<Directory> {
		&self.directory
	}
	/// Load or initialize private metadata while retaining exclusive ownership.
	pub fn prepare(self) -> Result<Prepared> {
		let directory = self.directory;
		for name in ["session.json", "effects.json", "grants.json"] {
			if directory
				.path()
				.join(name)
				.try_exists()
				.map_err(|error| storage(error.into()))?
			{
				return Err(loam::refusal(
					"retired Rooms session storage requires an explicit operator reset",
				));
			}
		}
		let bootstrap = match read(&directory.path().join(METADATA), Bootstrap::BYTES).map_err(storage)? {
			Some(bytes) => Bootstrap::decode(
				bytes
					.try_into()
					.map_err(|_| loam::refusal("invalid Rooms bootstrap length"))?,
			)?,
			None => {
				if directory
					.path()
					.join(STORE)
					.try_exists()
					.map_err(|error| storage(error.into()))?
				{
					return Err(loam::refusal(
						"Rooms Store exists without its private bootstrap metadata",
					));
				}
				let mut random = [0; 64];
				getrandom::fill(&mut random).map_err(|error| loam::refusal(error.to_string()))?;
				let bootstrap = Bootstrap {
					seed: random[..32]
						.try_into()
						.map_err(|_| loam::refusal("bootstrap seed draw has the wrong length"))?,
					store_identity: random[32..48]
						.try_into()
						.map_err(|_| loam::refusal("bootstrap Store identity draw has the wrong length"))?,
					owner_identity: random[48..]
						.try_into()
						.map_err(|_| loam::refusal("bootstrap owner identity draw has the wrong length"))?,
					anchor: None,
				};
				persist(&directory, bootstrap)?;
				bootstrap
			}
		};
		Ok(Prepared { directory, bootstrap })
	}
}
/// Fixed startup metadata and its directory lease. Preparation finishes before
/// traffic is admitted. The atomic writer borrows the fixed encoded buffer.
pub struct Prepared {
	directory: Arc<Directory>,
	bootstrap: Bootstrap,
}
impl Prepared {
	pub fn open(path: &Path) -> Result<Self> {
		Custody::acquire(path)?.prepare()
	}
	pub fn seed(&self) -> [u8; 32] {
		self.bootstrap.seed
	}
	pub fn directory(&self) -> &Arc<Directory> {
		&self.directory
	}
	/// Opens the existing LMDB adapter under explicit physical and resident
	/// budgets. A confirmed anchor cannot create a missing Store. Unknown open
	/// outcomes are refused and keep the metadata for an exact next attempt.
	pub async fn start(self, host: Host, limits: Limits, map_bytes: usize, live_capacity: u32) -> Result<Session> {
		let path = self.directory.path().join(STORE);
		if !path.try_exists().map_err(|error| storage(error.into()))? {
			if self.bootstrap.anchor.is_some() {
				return Err(loam::refusal("anchored Rooms Store is missing"));
			}
			std::fs::create_dir(&path).map_err(|error| storage(error.into()))?;
			std::fs::File::open(&path)
				.and_then(|file| file.sync_all())
				.map_err(|error| storage(error.into()))?;
			self.directory.sync().map_err(|error| storage(error.into()))?;
		}
		let store = if self.bootstrap.anchor.is_none() {
			Store::open_bootstrap(&path, self.bootstrap.store_identity, map_bytes, &schemas(), limits)?
		} else {
			Store::open(
				&path,
				self.bootstrap.store_identity,
				false,
				map_bytes,
				&schemas(),
				limits,
			)?
		};
		let directory = self.directory;
		let opened = self
			.bootstrap
			.open(
				store,
				host,
				HostPlatform,
				BootstrapOptions {
					reply_bytes: NonZeroUsize::new(limits.forward_reply_bytes)
						.ok_or_else(|| loam::refusal("Rooms reply budget is zero"))?,
					live_capacity,
					initial_connection: rooms_application::content::session::workspace::Connection::Relay,
				},
				|bootstrap| std::future::ready(persist(&directory, bootstrap)),
			)
			.await?;
		Ok(Session {
			opened,
			_directory: directory,
		})
	}
}
/// Session storage and its directory lease retire in dependency order. Held
/// transports may share the lease through `Prepared::directory` while listening.
pub struct Session {
	pub opened: Opened<HostPlatform>,
	_directory: Arc<Directory>,
}
fn persist(directory: &Directory, bootstrap: Bootstrap) -> Result<()> {
	atomic::replace(directory, METADATA, [&bootstrap.encode()[..]])
		.map_err(|error| loam::refusal(format!("Rooms bootstrap persistence refused: {error:?}")))
}
fn storage(error: StorageError) -> glowcap::Error {
	loam::refusal(error.to_string())
}
