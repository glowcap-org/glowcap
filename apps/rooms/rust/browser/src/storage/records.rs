//! Native IndexedDB indices own lookup and ordering. Each mutation of records,
//! attachment positions, byte accounting and revision is one transaction.
use super::{Database, Error, Operation};
use rooms_application::archive::{Filter, Record, index::Page};
use rooms_application::text::DocumentText;
pub(super) mod codec;
mod read;
mod write;
use read::page;
pub(super) use read::reader;
use write::{Put, put};
pub(super) const RECORDS: &str = "archive-records";
pub(super) const BLOBS: &str = "archive-blobs";
pub(super) const META: &str = "archive-meta";
pub(super) const MAX_SAFE: u64 = (1 << 53) - 1;
/// One serial executor for the shared archive worker. A cancelled caller leaves
/// its transaction here; the next operation observes that outcome before acting.
pub struct Archive {
	pub(super) database: Database,
	pub(super) cache: super::blobs::Cache,
	pending: Option<Operation<Put>>,
}
impl Archive {
	pub fn new(database: Database) -> Self {
		Self {
			database,
			pending: None,
			cache: super::blobs::Cache::default(),
		}
	}
	pub(super) async fn settle(&mut self) -> Result<Option<u64>, Error> {
		let Some(operation) = &mut self.pending else {
			return Ok(None);
		};
		let result = operation.wait().await;
		self.pending = None;
		result.map(|put| put.revision)
	}
	pub async fn put_retained(&mut self, record: Record, epoch: DocumentText) -> Result<Option<u64>, Error> {
		self.commit(record, Some(epoch), Vec::new()).await
	}
	pub(super) async fn commit(
		&mut self,
		record: Record,
		epoch: Option<DocumentText>,
		files: Vec<super::blobs::Staged>,
	) -> Result<Option<u64>, Error> {
		self.settle().await?;
		self.pending = Some(put(&self.database, record, epoch, files)?);
		self.settle().await
	}
	pub async fn put(&mut self, record: Record) -> Result<u64, Error> {
		self.commit(record, None, Vec::new())
			.await?
			.ok_or(Error::Invalid("unrestricted archive write was not admitted"))
	}
	pub async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		self.settle().await?;
		page(&self.database, filter.clone(), after, limit)?.wait().await
	}
	pub async fn clear(&mut self) -> Result<(), Error> {
		self.settle().await?;
		// Retain a mutation through the same pending slot, so an abandoned
		// clear's failure is observed before this executor admits another write.
		self.pending = Some(write::clear(&self.database)?);
		self.settle().await.map(|_| self.cache.clear())
	}
	pub async fn close(&mut self) -> Result<(), Error> {
		let result = self.settle().await;
		self.database.close().await;
		self.cache.clear();
		result.map(|_| ())
	}
}
