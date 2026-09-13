//! Filesystem execution for the shared checkpoint/effects owner.
use super::{Completion, DocumentFile, SessionDocument, StorageError, WriteFailure};
use rooms_application::session::state::SessionStorage;
use rooms_runtime::documents::{Documents, Stored};

pub struct StateDocuments {
	checkpoint: DocumentFile,
	effects: DocumentFile,
}
impl StateDocuments {
	pub(super) fn new(checkpoint: DocumentFile, effects: DocumentFile) -> Self {
		Self { checkpoint, effects }
	}
}
impl Documents for StateDocuments {
	fn has_pending(&self) -> bool {
		self.checkpoint.has_pending() || self.effects.has_pending()
	}
	async fn read(&mut self) -> Result<Stored, StorageError> {
		if self.checkpoint.document() != SessionDocument::Checkpoint
			|| self.effects.document() != SessionDocument::Effects
		{
			return Err(StorageError::Worker("invalid session document roles".into()));
		}
		if self.has_pending() {
			return Err(StorageError::Pending);
		}
		Ok(Stored {
			checkpoint: self.checkpoint.read().await?,
			effects: self.effects.read().await?,
		})
	}
	async fn finish_pending(&mut self) -> [Option<Completion>; 2] {
		[
			self.checkpoint.finish_pending().await,
			self.effects.finish_pending().await,
		]
	}
}
impl SessionStorage for StateDocuments {
	type Error = StorageError;
	async fn replace(&mut self, kind: SessionDocument, bytes: Vec<u8>) -> Result<(), WriteFailure<StorageError>> {
		match kind {
			SessionDocument::Checkpoint => self.checkpoint.replace(bytes).await,
			SessionDocument::Effects => self.effects.replace(bytes).await,
			_ => Err(WriteFailure::Unchanged(StorageError::Worker(
				"unexpected session-state document".into(),
			))),
		}
	}
}
