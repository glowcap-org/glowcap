//! Record journal execution stays off the capability executor. Each disk job
//! retains the directory lock and shared immutable records through completion.
use super::{Backend, Chunk, Source};
mod blobs;
mod erase;
mod files;
mod identity;
mod shares;
pub use blobs::Usage as BlobUsage;
use rooms_application::{
	archive::{
		Filter, MAX_RECORDS, Record, disk,
		index::{Entry, Index, Page},
		request::Request,
	},
	documents::WriteFailure,
	fields::SafeInteger,
};
use rooms_platform::storage::{self, Directory, StorageError};
use rooms_runtime::Error;
use std::{
	borrow::Cow,
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
	RecordingSource(rooms_application::text::DocumentText),
	#[cfg(feature = "processes")]
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
	pending: Option<JoinHandle<Result<Completion, DiskFailure>>>,
}
impl FileArchive {
	pub async fn open(path: impl AsRef<Path>, options: Options) -> Result<Self, Error> {
		let path = path.as_ref().to_owned();
		let store = tokio::task::spawn_blocking(move || Store::open(path, options))
			.await
			.map_err(lost)?
			.map_err(Error::from)?;
		Ok(Self {
			store: Arc::new(Mutex::new(store)),
			pending: None,
		})
	}
	/// Cancelling an observation does not cancel filesystem work. Observe it
	/// before admitting another operation, retaining errors rather than skipping
	/// an uncertain write. Dropping this owner leaves the disk job holding custody.
	pub async fn finish_pending(&mut self) -> Result<(), Error> {
		match self.settle().await {
			Some(result) => result.map(|_| ()),
			None => Ok(()),
		}
	}
	/// The one place a disk job's classed failure becomes the runtime's own.
	async fn settle(&mut self) -> Option<Result<Completion, Error>> {
		let pending = self.pending.as_mut()?;
		let result = pending
			.await
			.map_err(lost)
			.and_then(|result| result.map_err(Error::from));
		self.pending.take();
		Some(result)
	}
	async fn submit(
		&mut self,
		work: impl FnOnce(&mut Store) -> Result<Completion, DiskFailure> + Send + 'static,
	) -> Result<Completion, Error> {
		self.finish_pending().await?;
		let store = self.store.clone();
		self.pending = Some(tokio::task::spawn_blocking(move || {
			let mut store = files::lock(&store)?;
			store.live()?;
			work(&mut store)
		}));
		self.settle()
			.await
			.unwrap_or_else(|| Err(Error::invalid("disk operation was not submitted")))
	}
	async fn call(&mut self, request: Request) -> Result<Completion, Error> {
		self.submit(move |store| match request {
			Request::Put(record) => store.put(record).map(Completion::Revision),
			Request::Read { filter, after, limit } => store
				.index
				.read(&filter, after, limit)
				.map(Completion::Page)
				.map_err(DiskFailure::Archive),
			_ => unreachable!("only storage operations enter the file worker"),
		})
		.await
	}
}
impl Backend for FileArchive {
	async fn clear_source(&mut self, source: &rooms_application::text::DocumentText) -> Result<(), Error> {
		FileArchive::clear_source(self, source).await
	}
	fn blob_access(&self) -> impl super::BlobAccess + use<> {
		files::ReadAccess(self.store.clone())
	}
	async fn clear(&mut self) -> Result<(), Error> {
		FileArchive::clear(self).await
	}
	fn durable_shares(&self) -> bool {
		true
	}
	async fn change_share(
		&mut self,
		command: rooms_application::archive::shares::Command,
	) -> Result<rooms_application::archive::shares::Change, Error> {
		FileArchive::change_share(self, command).await
	}
	async fn active_shares(&mut self) -> Result<Vec<rooms_application::archive::shares::Share>, Error> {
		FileArchive::active_shares(self).await
	}
	fn retains_blobs(&self) -> bool {
		true
	}
	async fn put(&mut self, record: Record) -> Result<u64, Error> {
		match self.call(Request::Put(record)).await? {
			Completion::Revision(revision) => Ok(revision),
			_ => unreachable!("put completion"),
		}
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		filter.validate().map_err(Error::archive)?;
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
	async fn put_files<S: Source>(&mut self, record: Record, sources: &[S]) -> Result<u64, Error> {
		self.put_with_files(record, sources).await
	}
	async fn blob_reader(
		&mut self,
		facet: rooms_application::archive::Facet,
		digest: String,
	) -> Result<rooms_application::archive::blobs::Reader, Error> {
		self.reader_for_digest(facet, digest).await
	}
	async fn read_blob(
		&mut self,
		reader: rooms_application::archive::blobs::Reader,
		offset: u64,
		maximum: usize,
	) -> Result<Vec<u8>, Error> {
		FileArchive::read_blob(self, reader, offset, maximum).await
	}
}
impl Store {
	fn open(path: PathBuf, options: Options) -> Result<Self, DiskFailure> {
		let index = Index::new(options.capacity)?;
		if options.compact_delta == 0
			|| options.compact_delta > MAX_RECORDS
			|| options.max_file_bytes == 0
			|| options.max_file_bytes > disk::MAX_FILE_BYTES
		{
			return Err(DiskFailure::Invalid("invalid archive storage limits".into()));
		}
		let directory = Directory::open(path, "archive.lock")?;
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
		match storage::read(&store.directory.path().join(disk::FILE), options.max_file_bytes)? {
			Some(bytes) => {
				let loaded = disk::recover(&bytes, options.capacity, options.compact_delta, options.max_file_bytes)?;
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
	/// The blob store `open` attaches last, after recovery and compaction have
	/// settled the index it indexes. Nothing reaches a store before `open`
	/// returns, so a missing blob store is an invalid-state refusal, not a panic.
	fn blobs(&self) -> Result<&blobs::Blobs, DiskFailure> {
		self.blobs
			.as_ref()
			.ok_or_else(|| DiskFailure::Invalid("archive blob store is not open".into()))
	}
	fn blobs_mut(&mut self) -> Result<&mut blobs::Blobs, DiskFailure> {
		self.blobs
			.as_mut()
			.ok_or_else(|| DiskFailure::Invalid("archive blob store is not open".into()))
	}
	fn live(&self) -> Result<(), DiskFailure> {
		if self.ready {
			Ok(())
		} else {
			Err(DiskFailure::Uncertain(
				"archive storage outcome is uncertain; reload required".into(),
			))
		}
	}
	/// A journal write that did not commit leaves the archive exactly as it
	/// was, so the caller may put the record again. One nobody could observe
	/// retires this store until a reload reads the journal back, because the
	/// record may or may not be on disk.
	fn written(&mut self, result: Result<(), WriteFailure<StorageError>>) -> Result<(), DiskFailure> {
		match result {
			Ok(()) => Ok(()),
			Err(WriteFailure::Unchanged(e)) => Err(DiskFailure::Storage(e)),
			Err(WriteFailure::Indeterminate(e)) => {
				self.ready = false;
				Err(DiskFailure::Uncertain(format!("{e}; archive reload required").into()))
			}
		}
	}
	fn compact(&mut self) -> Result<(), DiskFailure> {
		let snapshot = disk::snapshot(&self.index, self.options.max_file_bytes)?;
		let written = storage::atomic::replace(&self.directory, disk::FILE, snapshot.chunks());
		self.written(written)?;
		self.bytes = snapshot.byte_len();
		self.rows = self.index.len();
		Ok(())
	}
	fn put(&mut self, record: Record) -> Result<u64, DiskFailure> {
		self.live()?;
		let record = self.index.prepare_put(record);
		self.commit_with_blobs(record)
	}
	fn commit_record(&mut self, record: Record) -> Result<u64, DiskFailure> {
		self.live()?;
		let revision = SafeInteger::<true>::new(self.index.revision() + 1)
			.ok_or_else(|| DiskFailure::Full("archive revision space exhausted".into()))?
			.get();
		if self.rows - self.index.len() >= self.options.compact_delta {
			self.compact()?;
		}
		let bytes = disk::revision(revision, &record, self.options.max_file_bytes)?;
		if bytes.len() > self.options.max_file_bytes - self.bytes {
			self.compact()?;
			if bytes.len() > self.options.max_file_bytes - self.bytes {
				let mut proposed = Index::new(self.options.capacity)?;
				proposed.restore(
					self.index.revision(),
					self.index
						.snapshot()
						.map(|e| Entry {
							revision: e.revision,
							record: e.record.clone(),
						})
						.collect(),
				)?;
				proposed.apply(revision, record)?;
				let snapshot = disk::snapshot(&proposed, self.options.max_file_bytes)?;
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
		self.index
			.apply(revision, record)
			.map_err(|_| DiskFailure::Invalid("archive index refused a validated revision".into()))?;
		self.bytes += bytes.len();
		self.rows += 1;
		Ok(revision)
	}
}

/// What one blocking disk job can fail with.
///
/// The runtime's classed error keeps its typed sources behind `Rc`, so one
/// completion can be handed to every observer waiting on it. That also means it
/// cannot cross a thread, and this archive runs its journal on a blocking one.
/// So a disk failure crosses that boundary with its class intact and becomes a
/// runtime error the moment it lands, rather than arriving as a sentence
/// something further up has to guess a class from.
#[derive(Debug)]
pub(super) enum DiskFailure {
	/// The archive's own verdict on a record, filter, page, or index.
	Archive(rooms_application::archive::Error),
	/// The filesystem refused and the journal is unchanged.
	Storage(StorageError),
	/// The store found retained state it cannot serve: a blob that is not a
	/// file, a size that disagrees with its record, content that does not
	/// match its digest. Asking again reads the same bytes, so this is the
	/// archive failing rather than the request being wrong.
	Corrupt(Cow<'static, str>),
	/// A ceiling this store keeps itself.
	Full(Cow<'static, str>),
	/// This store was handed limits it cannot honor.
	Invalid(Cow<'static, str>),
	/// A write or a lock whose outcome nobody observed.
	Uncertain(Cow<'static, str>),
	/// A cleanup that failed while the job was already failing.
	Cleanup { primary: Box<Self>, cleanup: Box<Self> },
}

impl DiskFailure {
	/// Keep this failure as the primary cause and carry a failed cleanup behind it.
	pub(super) fn retain(self, cleanup: Self) -> Self {
		Self::Cleanup {
			primary: Box::new(self),
			cleanup: Box::new(cleanup),
		}
	}
}

impl From<rooms_application::archive::Error> for DiskFailure {
	fn from(error: rooms_application::archive::Error) -> Self {
		Self::Archive(error)
	}
}
impl From<StorageError> for DiskFailure {
	fn from(error: StorageError) -> Self {
		Self::Storage(error)
	}
}
/// A journal on disk this build cannot read back. Nothing the caller asks
/// differently will change it, so it is the archive that is unserviceable.
impl From<disk::RecoveryError> for DiskFailure {
	fn from(error: disk::RecoveryError) -> Self {
		Self::Corrupt(error.to_string().into())
	}
}
impl From<DiskFailure> for Error {
	fn from(failure: DiskFailure) -> Self {
		match failure {
			DiskFailure::Archive(error) => Self::archive(error),
			DiskFailure::Storage(error) => Self::storage(error),
			DiskFailure::Corrupt(text) => Self::storage_message(text),
			DiskFailure::Full(text) => Self::exhausted(text),
			DiskFailure::Invalid(text) => Self::invalid(text),
			DiskFailure::Uncertain(text) => Self::uncertain(text),
			DiskFailure::Cleanup { primary, cleanup } => Self::from(*primary).retain(Self::from(*cleanup)),
		}
	}
}
/// A blocking disk job that neither returned nor unwound: it panicked, or the
/// runtime dropped it. Whether its write reached the journal is unknown here,
/// so the archive has to be read again rather than written again.
fn lost(join: tokio::task::JoinError) -> Error {
	Error::uncertain(format!("archive storage job did not finish: {join}"))
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod hosting_tests;

#[cfg(test)]
mod blob_tests;

#[cfg(test)]
mod hosted_blob_tests;

#[cfg(test)]
mod share_tests;

#[cfg(test)]
mod hosted_share_tests;

#[cfg(test)]
mod erase_tests;
