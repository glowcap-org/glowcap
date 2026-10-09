//! Exclusive session-directory custody and cancellable observation of disk work.
use rooms_application::documents::WriteFailure;
mod atomic;
#[cfg(test)]
mod tests;

use rooms_application::documents::SessionDocument;
use std::sync::Arc;
use tokio::task::JoinHandle;

use rooms_platform::storage::Directory;
pub use rooms_platform::storage::StorageError;

pub type Completion = rooms_runtime::documents::Completion<StorageError>;

enum Pending {
	Read(JoinHandle<Result<Option<Vec<u8>>, StorageError>>),
	Write(JoinHandle<Result<(), WriteFailure<StorageError>>>),
}

pub struct DocumentFile {
	directory: Arc<Directory>,
	document: SessionDocument,
	pending: Option<Pending>,
}

impl DocumentFile {
	/// Reuse the managed startup lease for independent private documents.
	/// This constructor never opens retired session authority or takes a second lock.
	pub fn bridge_secrets(directory: Arc<Directory>) -> Self {
		Self {
			directory,
			document: SessionDocument::BridgeSecrets,
			pending: None,
		}
	}
	pub fn document(&self) -> SessionDocument {
		self.document
	}
	pub fn has_pending(&self) -> bool {
		self.pending.is_some()
	}
	fn require_idle(&self) -> Result<(), StorageError> {
		if self.has_pending() {
			Err(StorageError::Pending)
		} else {
			Ok(())
		}
	}
	/// Cancellation drops only the observer. The owner retains the task until
	/// this method completes, so a later reload cannot race a detached write.
	pub async fn finish_pending(&mut self) -> Option<Completion> {
		let result = match self.pending.as_mut()? {
			Pending::Read(task) => {
				Completion::Read(task.await.unwrap_or_else(|e| Err(StorageError::Worker(e.to_string()))))
			}
			Pending::Write(task) => Completion::Write(
				task.await
					.unwrap_or_else(|e| Err(WriteFailure::Indeterminate(StorageError::Worker(e.to_string())))),
			),
		};
		self.pending = None;
		Some(result)
	}
	pub async fn read(&mut self) -> Result<Option<Vec<u8>>, StorageError> {
		self.require_idle()?;
		let (directory, document) = (self.directory.clone(), self.document);
		self.pending = Some(Pending::Read(tokio::task::spawn_blocking(move || {
			atomic::read(&directory.path().join(filename(document)), document)
		})));
		match self.finish_pending().await.expect("owned read") {
			Completion::Read(result) => result,
			Completion::Write(_) => unreachable!("one document operation"),
		}
	}
	/// The bounded encoded buffer moves into the disk worker without a copy.
	pub async fn replace(&mut self, bytes: Vec<u8>) -> Result<(), WriteFailure<StorageError>> {
		self.require_idle().map_err(WriteFailure::Unchanged)?;
		self.document
			.decode(&bytes)
			.map_err(|e| WriteFailure::Unchanged(e.into()))?;
		let (directory, document) = (self.directory.clone(), self.document);
		self.start_write(move || atomic::replace(&directory, document, &bytes));
		match self.finish_pending().await.expect("owned write") {
			Completion::Write(result) => result,
			Completion::Read(_) => unreachable!("one document operation"),
		}
	}
	fn start_write(&mut self, work: impl FnOnce() -> Result<(), WriteFailure<StorageError>> + Send + 'static) {
		self.pending = Some(Pending::Write(tokio::task::spawn_blocking(work)));
	}
}

fn filename(document: SessionDocument) -> &'static str {
	match document {
		SessionDocument::Checkpoint => "session.json",
		SessionDocument::Effects => "effects.json",
		SessionDocument::Grants => "grants.json",
		SessionDocument::BridgeSecrets => "bridge-secrets.json",
	}
}

impl rooms_runtime::documents::Document for DocumentFile {
	type Error = StorageError;
	fn document(&self) -> SessionDocument {
		self.document()
	}
	fn has_pending(&self) -> bool {
		self.has_pending()
	}
	async fn read(&mut self) -> Result<Option<Vec<u8>>, StorageError> {
		self.read().await
	}
	async fn replace(&mut self, bytes: Vec<u8>) -> Result<(), WriteFailure<StorageError>> {
		self.replace(bytes).await
	}
	async fn finish_pending(&mut self) -> Option<Completion> {
		self.finish_pending().await
	}
}
