//! Tab/process-lifetime documents. These do not survive their owner's release.
use super::*;
use rooms_application::documents::{DocumentError, SessionDocument};

#[derive(Debug)]
pub enum Error {
	Document(DocumentError),
	Role,
}
impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::Document(error) => error.fmt(f),
			Self::Role => f.write_str("unexpected session-state document"),
		}
	}
}
impl std::error::Error for Error {}

/// A fixed-role, non-cloneable document for a tab or process lifetime.
pub struct VolatileDocument {
	document: SessionDocument,
	bytes: Option<Vec<u8>>,
}
impl VolatileDocument {
	pub fn new(document: SessionDocument) -> Self {
		Self { document, bytes: None }
	}
}
impl Document for VolatileDocument {
	type Error = Error;
	fn document(&self) -> SessionDocument {
		self.document
	}
	fn has_pending(&self) -> bool {
		false
	}
	async fn read(&mut self) -> Result<Option<Vec<u8>>, Error> {
		// Restoration owns its input; retain the bounded committed bytes for reload.
		Ok(self.bytes.clone())
	}
	async fn replace(&mut self, bytes: Vec<u8>) -> Result<(), WriteFailure<Error>> {
		self.document
			.decode(&bytes)
			.map_err(|error| WriteFailure::Unchanged(Error::Document(error)))?;
		// No suspension or copy between admission and atomic replacement.
		self.bytes = Some(bytes);
		Ok(())
	}
	async fn finish_pending(&mut self) -> Option<Completion<Error>> {
		None
	}
}
pub struct VolatileDocuments {
	checkpoint: VolatileDocument,
	effects: VolatileDocument,
}
impl Default for VolatileDocuments {
	fn default() -> Self {
		Self {
			checkpoint: VolatileDocument::new(SessionDocument::Checkpoint),
			effects: VolatileDocument::new(SessionDocument::Effects),
		}
	}
}
impl SessionStorage for VolatileDocuments {
	type Error = Error;
	async fn replace(&mut self, kind: SessionDocument, bytes: Vec<u8>) -> Result<(), WriteFailure<Error>> {
		let slot = match kind {
			SessionDocument::Checkpoint => &mut self.checkpoint,
			SessionDocument::Effects => &mut self.effects,
			_ => return Err(WriteFailure::Unchanged(Error::Role)),
		};
		slot.replace(bytes).await
	}
}
impl Documents for VolatileDocuments {
	fn has_pending(&self) -> bool {
		false
	}
	async fn read(&mut self) -> Result<Stored, Error> {
		Ok(Stored {
			checkpoint: self.checkpoint.read().await?,
			effects: self.effects.read().await?,
		})
	}
	async fn finish_pending(&mut self) -> [Option<Completion<Error>>; 2] {
		[None, None]
	}
}
