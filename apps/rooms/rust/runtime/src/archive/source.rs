//! Bounded reads from live capabilities or retained file materializations.
use rooms_application::files::FileDescription;
pub use rooms_glowcap::client::files::capture::Chunk;
use std::future::Future;
pub trait Source {
	fn description(&self) -> &FileDescription;
	fn read(&self, offset: u64, length: usize) -> impl Future<Output = Result<Chunk, String>>;
}
/// Bytes already captured from their source: every read answers from memory.
impl Source for rooms_glowcap::client::files::capture::Captured {
	fn description(&self) -> &FileDescription {
		self.description()
	}
	async fn read(&self, offset: u64, length: usize) -> Result<Chunk, String> {
		self.span(offset, length)
	}
}
impl<D: rooms_glowcap::client::Deadline> Source for rooms_glowcap::client::files::File<D> {
	fn description(&self) -> &FileDescription {
		&self.attachment().description
	}
	async fn read(&self, offset: u64, length: usize) -> Result<Chunk, String> {
		self.read(offset, length)
			.await
			.map(Into::into)
			.map_err(|e| e.to_string())
	}
}

impl Source for crate::media_files::Materialized {
	fn description(&self) -> &FileDescription {
		self.description()
	}
	async fn read(&self, offset: u64, maximum: usize) -> Result<Chunk, String> {
		self.span(offset, maximum)
	}
}
