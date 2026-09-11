//! Record journal execution stays off the capability executor. Each disk job
//! retains the directory lock and shared immutable records through completion.
use super::{Backend, Chunk, Source};
mod blobs;
mod erase;
mod files;
mod identity;
mod shares;
use crate::storage::{self, Directory, StorageError};
pub use blobs::Usage as BlobUsage;
use rooms_application::{
	archive::{
		disk,
		index::{Entry, Index, Page},
		request::Request,
		Filter, Record, MAX_RECORDS,
	},
	documents::WriteFailure,
	fields::SafeInteger,
};
use std::{
	path::{Path, PathBuf},
	sync::{Arc, Mutex},
};
use tokio::task::JoinHandle;
#[derive(Clone, Copy)]
pub struct Options {
	pub capacity: usize,
	pub compact_delta: usize,
	pub max_file_bytes: usize,
	pub max_blob_bytes: usize,
}
impl Default for Options {
	fn default() -> Self {
		Self {
			capacity: MAX_RECORDS,
			compact_delta: disk::COMPACT_DELTA,
			max_file_bytes: disk::MAX_FILE_BYTES,
			max_blob_bytes: rooms_application::archive::blobs::MAX_BLOB_BYTES,
		}
	}
}
struct Store {
	directory: Directory,
	index: Index,
	options: Options,
	bytes: usize,
	rows: usize,
	ready: bool,
	blobs: Option<blobs::Blobs>,
	shares: rooms_application::archive::shares::Ledger,
}
enum Completion {
	#[cfg(feature = "service")]
	OnionKey(Option<Vec<u8>>),
	Identity(rooms_application::archive::identity::Identity),
	Revision(u64),
	Page(Page),
	Bytes(Vec<u8>),
	Reader(rooms_application::archive::blobs::Reader),
	Usage(BlobUsage),
	Cleaned,
	ShareChange(rooms_application::archive::shares::Change),
	Shares(Vec<rooms_application::archive::shares::Share>),
}
/// Durable archive records and content-addressed bytes share one serial owner.
/// Independent reads may inspect committed blobs during source ingestion.
pub struct FileArchive {
	store: Arc<Mutex<Store>>,
	pending: Option<JoinHandle<Result<Completion, String>>>,
}
impl FileArchive {
	pub async fn open(path: impl AsRef<Path>, options: Options) -> Result<Self, String> {
		let path = path.as_ref().to_owned();
		let store = tokio::task::spawn_blocking(move || Store::open(path, options))
			.await
			.map_err(|e| e.to_string())??;
		Ok(Self {
			store: Arc::new(Mutex::new(store)),
			pending: None,
		})
	}
	/// Cancelling an observation does not cancel filesystem work. Observe it
	/// before admitting another operation, retaining errors rather than skipping
	/// an uncertain write. Dropping this owner leaves the disk job holding custody.
	pub async fn finish_pending(&mut self) -> Result<(), String> {
		match self.settle().await {
			Some(result) => result.map(|_| ()),
			None => Ok(()),
		}
	}
	async fn settle(&mut self) -> Option<Result<Completion, String>> {
		let pending = self.pending.as_mut()?;
		let result = pending.await.map_err(|e| e.to_string()).and_then(|result| result);
		self.pending.take();
		Some(result)
	}
	async fn submit(
		&mut self,
		work: impl FnOnce(&mut Store) -> Result<Completion, String> + Send + 'static,
	) -> Result<Completion, String> {
		self.finish_pending().await?;
		let store = self.store.clone();
		self.pending = Some(tokio::task::spawn_blocking(move || {
			let mut store = store
				.lock()
				.map_err(|_| "archive storage worker panicked; reload required")?;
			store.live()?;
			work(&mut store)
		}));
		self.settle().await.expect("submitted disk operation")
	}
	async fn call(&mut self, request: Request) -> Result<Completion, String> {
		self.submit(move |store| match request {
			Request::Put(record) => store.put(record).map(Completion::Revision),
			Request::Read { filter, after, limit } => store
				.index
				.read(&filter, after, limit)
				.map(Completion::Page)
				.map_err(|e| e.to_string()),
			_ => unreachable!("only storage operations enter the file worker"),
		})
		.await
	}
}
impl Backend for FileArchive {
	fn blob_access(&self) -> impl super::BlobAccess + use<> {
		files::ReadAccess(self.store.clone())
	}
	async fn clear(&mut self) -> Result<(), String> {
		FileArchive::clear(self).await
	}
	fn durable_shares(&self) -> bool {
		true
	}
	async fn change_share(
		&mut self,
		command: rooms_application::archive::shares::Command,
	) -> Result<rooms_application::archive::shares::Change, String> {
		FileArchive::change_share(self, command).await
	}
	async fn active_shares(&mut self) -> Result<Vec<rooms_application::archive::shares::Share>, String> {
		FileArchive::active_shares(self).await
	}
	fn retains_blobs(&self) -> bool {
		true
	}
	async fn put(&mut self, record: Record) -> Result<u64, String> {
		match self.call(Request::Put(record)).await? {
			Completion::Revision(revision) => Ok(revision),
			_ => unreachable!("put completion"),
		}
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, String> {
		filter.validate().map_err(|e| e.to_string())?;
		match self
			.call(Request::Read {
				filter: filter.clone(),
				after,
				limit,
			})
			.await?
		{
			Completion::Page(page) => Ok(page),
			_ => unreachable!("read completion"),
		}
	}
	async fn put_files<S: Source>(&mut self, record: Record, sources: &[S]) -> Result<u64, String> {
		self.put_with_files(record, sources).await
	}
	async fn blob_reader(
		&mut self,
		facet: rooms_application::archive::Facet,
		digest: String,
	) -> Result<rooms_application::archive::blobs::Reader, String> {
		self.reader_for_digest(facet, digest).await
	}
	async fn read_blob(
		&mut self,
		reader: rooms_application::archive::blobs::Reader,
		offset: u64,
		maximum: usize,
	) -> Result<Vec<u8>, String> {
		FileArchive::read_blob(self, reader, offset, maximum).await
	}
}
impl Store {
	fn open(path: PathBuf, options: Options) -> Result<Self, String> {
		let index = Index::new(options.capacity).map_err(|e| e.to_string())?;
		if options.compact_delta == 0
			|| options.compact_delta > MAX_RECORDS
			|| options.max_file_bytes == 0
			|| options.max_file_bytes > disk::MAX_FILE_BYTES
		{
			return Err("invalid archive storage limits".into());
		}
		let directory = Directory::open(path, "archive.lock").map_err(|e| e.to_string())?;
		let mut store = Self {
			directory,
			index,
			options,
			bytes: 0,
			rows: 0,
			ready: true,
			blobs: None,
			shares: Default::default(),
		};
		match storage::read(&store.directory.path.join(disk::FILE), options.max_file_bytes)
			.map_err(|e| e.to_string())?
		{
			Some(bytes) => {
				let loaded = disk::recover(&bytes, options.capacity, options.compact_delta, options.max_file_bytes)
					.map_err(|e| e.to_string())?;
				store.bytes = bytes.len();
				store.rows = loaded.rows;
				store.index = loaded.index;
				if loaded.repair_tail {
					store.compact()?;
				}
			}
			None => store.compact()?,
		}
		store.open_shares()?;
		store.blobs = Some(blobs::Blobs::open(
			&store.directory,
			&store.index,
			options.max_blob_bytes,
		)?);
		Ok(store)
	}
	fn live(&self) -> Result<(), String> {
		if self.ready {
			Ok(())
		} else {
			Err("archive storage outcome is uncertain; reload required".into())
		}
	}
	fn written(&mut self, result: Result<(), WriteFailure<StorageError>>) -> Result<(), String> {
		match result {
			Ok(()) => Ok(()),
			Err(WriteFailure::Unchanged(e)) => Err(e.to_string()),
			Err(WriteFailure::Indeterminate(e)) => {
				self.ready = false;
				Err(format!("{e}; archive reload required"))
			}
		}
	}
	fn compact(&mut self) -> Result<(), String> {
		let snapshot = disk::snapshot(&self.index, self.options.max_file_bytes).map_err(|e| e.to_string())?;
		let written = storage::atomic::replace(&self.directory, disk::FILE, snapshot.chunks());
		self.written(written)?;
		self.bytes = snapshot.byte_len();
		self.rows = self.index.len();
		Ok(())
	}
	fn put(&mut self, record: Record) -> Result<u64, String> {
		self.live()?;
		let record = self.index.prepare_put(record);
		self.commit_with_blobs(record)
	}
	fn commit_record(&mut self, record: Record) -> Result<u64, String> {
		self.live()?;
		let revision = SafeInteger::<true>::new(self.index.revision() + 1)
			.ok_or("archive revision space exhausted")?
			.get();
		if self.rows - self.index.len() >= self.options.compact_delta {
			self.compact()?;
		}
		let bytes = disk::revision(revision, &record, self.options.max_file_bytes).map_err(|e| e.to_string())?;
		if bytes.len() > self.options.max_file_bytes - self.bytes {
			self.compact()?;
			if bytes.len() > self.options.max_file_bytes - self.bytes {
				let mut proposed = Index::new(self.options.capacity).map_err(|e| e.to_string())?;
				proposed
					.restore(
						self.index.revision(),
						self.index
							.snapshot()
							.map(|e| Entry {
								revision: e.revision,
								record: e.record.clone(),
							})
							.collect(),
					)
					.map_err(|e| e.to_string())?;
				proposed.apply(revision, record).map_err(|e| e.to_string())?;
				let snapshot = disk::snapshot(&proposed, self.options.max_file_bytes).map_err(|e| e.to_string())?;
				let written = storage::atomic::replace(&self.directory, disk::FILE, snapshot.chunks());
				self.written(written)?;
				self.index = proposed;
				self.bytes = snapshot.byte_len();
				self.rows = self.index.len();
				return Ok(revision);
			}
		}
		let written = storage::atomic::append(&self.directory, disk::FILE, &bytes);
		self.written(written)?;
		self.index.apply(revision, record).expect("validated next revision");
		self.bytes += bytes.len();
		self.rows += 1;
		Ok(revision)
	}
}
#[cfg(test)]
mod tests;

#[cfg(test)]
mod hosting_tests;

#[cfg(test)]
mod blob_tests;

#[cfg(test)]
mod hosted_blobs;

#[cfg(test)]
mod share_tests;

#[cfg(test)]
mod hosted_shares;

#[cfg(test)]
mod erase_tests;
