//! Erasure is local storage-owner authority. Commit the empty record account
//! before retiring blob references, preserving cursors and uncertain writes.
use super::*;
impl FileArchive {
	pub async fn clear_source(&mut self, source: &rooms_application::text::DocumentText) -> Result<(), Error> {
		let source = source.clone();
		self.submit(move |store| store.clear_source(&source).map(|()| Completion::Cleaned))
			.await?;
		Ok(())
	}
	/// Clear retained records and bytes without resetting revision or shares.
	/// Failure may mean committed erasure with pending physical cleanup. Retry
	/// clear or cleanup_blobs. An uncertain journal outcome requires reopen.
	pub async fn clear(&mut self) -> Result<(), Error> {
		self.submit(|store| store.clear().map(|()| Completion::Cleaned)).await?;
		Ok(())
	}
}
impl Store {
	/// Stage only bounded index spines and shared record roots: disk commitment
	/// must precede replacing the live account. Record and file payloads are
	/// borrowed by the snapshot writer, never copied into a second account.
	fn clear_source(&mut self, source: &rooms_application::text::DocumentText) -> Result<(), DiskFailure> {
		self.live()?;
		let mut retained = Index::new(self.options.capacity)?;
		let entries = self
			.index
			.snapshot()
			.filter(|entry| &entry.record.coordinates().source != source)
			.map(|entry| Entry {
				revision: entry.revision,
				record: entry.record.clone(),
			})
			.collect();
		retained.restore(self.index.revision(), entries)?;
		if retained.len() != self.index.len() {
			let snapshot = disk::snapshot(&retained, self.options.max_file_bytes)?;
			let written = storage::atomic::replace(&self.directory, disk::FILE, snapshot.chunks());
			self.written(written)?;
			let mut changes = blobs::Changes::new();
			for entry in self
				.index
				.snapshot()
				.filter(|entry| &entry.record.coordinates().source == source)
			{
				for (digest, delta) in blobs::Blobs::changes(Some(&entry.record), None) {
					*changes.entry(digest).or_default() += delta;
				}
			}
			self.index = retained;
			self.bytes = snapshot.byte_len();
			self.rows = self.index.len();
			self.blobs_mut()?.committed(changes)?;
		}
		self.blobs_mut()?.cleanup()
	}
	fn clear(&mut self) -> Result<(), DiskFailure> {
		self.live()?;
		if !self.index.is_empty() {
			let mut empty = Index::new(self.options.capacity)?;
			empty.restore(self.index.revision(), Vec::new())?;
			let snapshot = disk::snapshot(&empty, self.options.max_file_bytes)?;
			let written = storage::atomic::replace(&self.directory, disk::FILE, snapshot.chunks());
			self.written(written)?;
			self.index = empty;
			self.bytes = snapshot.byte_len();
			self.rows = 0;
		}
		// Once committed, no retained record can reach these bytes. Keep failed
		// deletions charged so another clear or startup can finish physical erase.
		self.blobs_mut()?.erase().map_err(|cleanup| {
			DiskFailure::Corrupt("archive records erased; retained byte cleanup failed".into()).retain(cleanup)
		})
	}
}
