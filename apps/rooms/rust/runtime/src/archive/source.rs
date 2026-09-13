//! Bounded reads from live capabilities or retained file materializations.
use crate::Error;
use rooms_application::files::FileDescription;
pub use rooms_glowcap::client::files::capture::Chunk;
use std::future::Future;
pub trait Source {
	fn description(&self) -> &FileDescription;
	fn read(&self, offset: u64, length: usize) -> impl Future<Output = Result<Chunk, Error>>;
}
/// Bytes already captured from their source: every read answers from memory,
/// so the only way a read fails is a span outside what was captured.
impl Source for rooms_glowcap::client::files::capture::Captured {
	fn description(&self) -> &FileDescription {
		self.description()
	}
	async fn read(&self, offset: u64, length: usize) -> Result<Chunk, Error> {
		self.span(offset, length).map_err(Error::invalid)
	}
}
impl<D: rooms_glowcap::client::Deadline> Source for rooms_glowcap::client::files::File<D> {
	fn description(&self) -> &FileDescription {
		&self.attachment().description
	}
	async fn read(&self, offset: u64, length: usize) -> Result<Chunk, Error> {
		self.read(offset, length).await.map(Into::into).map_err(Error::peer)
	}
}

impl Source for crate::files::media_files::Materialized {
	fn description(&self) -> &FileDescription {
		self.description()
	}
	async fn read(&self, offset: u64, maximum: usize) -> Result<Chunk, Error> {
		self.span(offset, maximum)
	}
}
