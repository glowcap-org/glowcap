//! Source capabilities stay on the application executor. A bounded channel
//! transfers owned or shared chunks to the one disk job without assembling a file.
use super::*;
use rooms_application::{
	archive::{Facet, blobs as policy},
	files::CHUNK_BYTES,
};
use tokio::sync::mpsc;
impl FileArchive {
	pub async fn put_with_files<S: Source>(&mut self, record: Record, sources: &[S]) -> Result<u64, Error> {
		self.finish_pending().await?;
		policy::validate_sources(&record, sources.iter().map(Source::description)).map_err(Error::archive)?;
		let (chunks, mut incoming) = mpsc::channel(1);
		let store = self.store.clone();
		self.pending = Some(tokio::task::spawn_blocking(move || {
			stage(&store, record, &mut incoming).map(Completion::Revision)
		}));
		// A source read fails on this side of the thread, where its class can be
		// kept whole. The disk job only learns that its sources stopped.
		let mut refused: Option<Error> = None;
		'sources: for source in sources {
			let mut offset = 0;
			while offset < source.description().size() {
				let length = CHUNK_BYTES.min(source.description().size() - offset);
				let read = tokio::select! {
					_ = chunks.closed() => break 'sources,
					bytes = source.read(offset as u64, length) => bytes,
				};
				let bytes = read.and_then(|bytes| {
					if bytes.as_ref().len() == length {
						bytes.into_bounded(CHUNK_BYTES).map_err(Error::invalid)
					} else {
						Err(Error::invalid(
							"archive source did not return exactly the requested bytes",
						))
					}
				});
				let bytes = match bytes {
					Ok(bytes) => bytes,
					Err(error) => {
						refused = Some(error);
						// best-effort: the marker only stops a job still reading.
						// A closed channel means it already stopped, and the
						// failure the caller sees is the retained one either way.
						let _ = chunks
							.send(Err(DiskFailure::Invalid("archive source read failed".into())))
							.await;
						break 'sources;
					}
				};
				if chunks.send(Ok(bytes)).await.is_err() {
					break 'sources;
				}
				offset += length;
			}
		}
		drop(chunks);
		// Observe the job either way; the source's own failure stays primary.
		let staged = self
			.settle()
			.await
			.unwrap_or_else(|| Err(Error::invalid("file operation was not submitted")));
		if let Some(error) = refused {
			return Err(error);
		}
		match staged? {
			Completion::Revision(revision) => Ok(revision),
			_ => unreachable!("put files completion"),
		}
	}
	pub async fn reader_for_digest(&mut self, facet: Facet, digest: String) -> Result<policy::Reader, Error> {
		match self
			.submit(move |store| {
				policy::Reader::digest(&facet, &store.index, &digest)
					.map(Completion::Reader)
					.map_err(DiskFailure::Archive)
			})
			.await?
		{
			Completion::Reader(reader) => Ok(reader),
			_ => unreachable!("reader completion"),
		}
	}
	pub async fn read_blob(&mut self, reader: policy::Reader, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		match self
			.submit(move |store| store.read_blob(&reader, offset, maximum).map(Completion::Bytes))
			.await?
		{
			Completion::Bytes(bytes) => Ok(bytes),
			_ => unreachable!("blob read completion"),
		}
	}
	pub async fn blob_usage(&mut self) -> Result<BlobUsage, Error> {
		match self
			.submit(|store| Ok(Completion::Usage(store.blobs()?.usage())))
			.await?
		{
			Completion::Usage(usage) => Ok(usage),
			_ => unreachable!("usage completion"),
		}
	}
	pub async fn cleanup_blobs(&mut self) -> Result<(), Error> {
		self.submit(|store| {
			store.blobs_mut()?.cleanup()?;
			Ok(Completion::Cleaned)
		})
		.await?;
		Ok(())
	}
}
impl Store {
	fn read_blob(&mut self, reader: &policy::Reader, offset: u64, maximum: usize) -> Result<Vec<u8>, DiskFailure> {
		let length = reader.read_length(&self.index, offset, maximum)?;
		let attachment = reader.resolve(&self.index)?;
		// The index borrow ends with `resolve`; the blob store is borrowed on its own.
		let blobs = self
			.blobs
			.as_mut()
			.ok_or_else(|| DiskFailure::Invalid("archive blob store is not open".into()))?;
		blobs.read(attachment, offset, length)
	}

	pub(super) fn commit_with_blobs(&mut self, record: Record) -> Result<u64, DiskFailure> {
		let changes = blobs::Blobs::changes(self.index.retired_by(&record), Some(&record));
		if !self.blobs()?.permits(&changes) {
			return Err(DiskFailure::Full(
				"archive retained blobs exceed their byte ceiling".into(),
			));
		}
		let revision = self.commit_record(record)?;
		self.blobs_mut()?.committed(changes)?;
		Ok(revision)
	}
	pub(super) fn finish_file_put(&mut self, result: Result<u64, DiskFailure>) -> Result<u64, DiskFailure> {
		if let Err(primary) = result {
			// An uncertain journal may reference staged bytes. Only a definitely
			// uncommitted operation can remove its unreferenced staging here.
			if self.ready
				&& let Err(cleanup) = self.blobs_mut()?.cleanup()
			{
				return Err(primary.retain(cleanup));
			}
			Err(primary)
		} else {
			result
		}
	}
}

/// The serial worker opens this executor before borrowing its backend for an
/// ingestion. It owns no mutation authority. Each read rechecks committed state.
pub(super) struct ReadAccess(pub(super) Arc<Mutex<Store>>);
impl crate::archive::BlobAccess for ReadAccess {
	async fn read(&self, reader: policy::Reader, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		let store = self.0.clone();
		tokio::task::spawn_blocking(move || {
			let mut store = lock(&store)?;
			store.live()?;
			store.read_blob(&reader, offset, maximum)
		})
		.await
		.map_err(lost)?
		.map_err(Error::from)
	}
}
pub(super) fn lock(store: &Mutex<Store>) -> Result<std::sync::MutexGuard<'_, Store>, DiskFailure> {
	store
		.lock()
		.map_err(|_| DiskFailure::Uncertain("archive storage worker panicked; reload required".into()))
}
fn stage(store: &Mutex<Store>, record: Record, chunks: &mut blobs::Chunks) -> Result<u64, DiskFailure> {
	let record = {
		let mut store = lock(store)?;
		store.live()?;
		store.blobs_mut()?.cleanup()?;
		store.index.prepare_put(record)
	};
	let result = (|| {
		let mut digests = Vec::new();
		for attachment in policy::files(&record)? {
			let staged = lock(store)?.blobs_mut()?.begin(attachment.size())?;
			// No journal or blob-index lock spans a source wait. A source may
			// itself be a reader of this archive's committed bytes.
			let staged = staged.write(chunks)?;
			digests.push(lock(store)?.blobs_mut()?.finish(staged)?);
		}
		let record = record.with_blob_digests(digests)?;
		lock(store)?.commit_with_blobs(record)
	})();
	lock(store)?.finish_file_put(result)
}
