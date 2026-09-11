//! Custody of the server document. A state directory is leased for the
//! server's life, and `rooms.json` is read whole and adopted, or minted once
//! with fresh entropy and written atomically before anything is published.
//! Without a state directory the document lives for the process alone:
//! a fresh identity each start, and every change kept in memory.
use super::error::Error;
use crate::storage::{self, Directory, StorageError};
use rooms_application::{
	documents::WriteFailure,
	server::{
		document::{self, Document},
		links::Authority,
	},
};
use std::{path::PathBuf, sync::Arc};

/// The leased state directory, when there is one, and the authority read
/// from its document.
pub struct ServerState {
	lease: Option<Arc<Directory>>,
	pub authority: Authority,
	uncertain: bool,
}

/// Lease `path` and adopt its document, minting one when none is there, or
/// mint a process-local one. Disk work runs off the capability executor.
pub async fn open(path: Option<PathBuf>) -> Result<ServerState, Error> {
	let Some(path) = path else {
		let document = fresh()?;
		return Ok(ServerState {
			lease: None,
			authority: Authority::read(&document)?,
			uncertain: false,
		});
	};
	let (lease, document) = tokio::task::spawn_blocking(move || open_blocking(path))
		.await
		.map_err(|e| Error::Worker(e.to_string()))??;
	Ok(ServerState {
		lease: Some(Arc::new(lease)),
		authority: Authority::read(&document)?,
		uncertain: false,
	})
}

fn fresh() -> Result<Document, Error> {
	let (mut seed, mut secret) = ([0u8; document::KEY_BYTES], [0u8; document::KEY_BYTES]);
	getrandom::fill(&mut seed).map_err(|e| Error::refused(format!("drawing the identity seed failed: {e}")))?;
	getrandom::fill(&mut secret).map_err(|e| Error::refused(format!("drawing the room-link secret failed: {e}")))?;
	Ok(Document::fresh(seed, secret))
}

fn open_blocking(path: PathBuf) -> Result<(Directory, Document), Error> {
	let directory = Directory::open(path, ".rooms-server.lock")?;
	let file = directory.path.join(document::FILE);
	let document = match storage::read(&file, document::MAX_BYTES)? {
		Some(bytes) => std::str::from_utf8(&bytes)
			.map_err(|_| document::Error::Json)
			.and_then(|text| Document::decode(text.strip_prefix('\u{feff}').unwrap_or(text)))
			.map_err(|cause| Error::DocumentAt { file, cause })?,
		None => {
			let fresh = fresh()?;
			write_blocking(&directory, &fresh)?;
			fresh
		}
	};
	Ok((directory, document))
}

fn encoded(document: &Document) -> Result<String, Error> {
	let mut text = document.encode()?;
	text.push('\n');
	Ok(text)
}

fn write_blocking(directory: &Directory, document: &Document) -> Result<(), Error> {
	let text = encoded(document)?;
	storage::atomic::replace(directory, document::FILE, std::iter::once(text.as_bytes()))?;
	Ok(())
}

impl ServerState {
	/// No mutation may publish from a stale authority snapshot, including
	/// idempotent issuance that would otherwise skip a disk write.
	pub(super) fn require_current(&self) -> Result<(), Error> {
		if self.uncertain {
			Err(Error::refused(
				"the room authority document requires restart reconciliation",
			))
		} else {
			Ok(())
		}
	}
	/// The leased state directory, for the other documents kept beside the
	/// server's own.
	pub fn directory(&self) -> Option<Arc<Directory>> {
		self.lease.clone()
	}
	/// Persist `next`'s document, then adopt it. The old authority stands
	/// until the write has succeeded. An uncertain replacement prevents further
	/// writes until startup reloads the authoritative document.
	pub async fn install(&mut self, next: Authority) -> Result<(), Error> {
		self.require_current()?;
		if let Some(lease) = &self.lease {
			let lease = lease.clone();
			let text = encoded(&next.document())?;
			match tokio::task::spawn_blocking(move || {
				storage::atomic::replace(&lease, document::FILE, [text.as_bytes()])
			})
			.await
			{
				Ok(Ok(())) => {}
				Ok(Err(WriteFailure::Unchanged(error))) => return Err(error.into()),
				Ok(Err(WriteFailure::Indeterminate(error))) => {
					self.uncertain = true;
					return Err(Error::refused(format!(
						"the room authority write is uncertain; restart to reconcile it: {error}"
					)));
				}
				Err(error) => {
					self.uncertain = true;
					return Err(Error::refused(format!(
						"the room authority writer failed; restart to reconcile it: {error}"
					)));
				}
			}
		}
		self.authority = next;
		Ok(())
	}
}

impl From<WriteFailure<StorageError>> for Error {
	fn from(failure: WriteFailure<StorageError>) -> Self {
		match failure {
			WriteFailure::Unchanged(e) | WriteFailure::Indeterminate(e) => Self::from(e),
		}
	}
}
