//! Erasure is local storage-owner authority. Commit the empty record account
//! before retiring blob references, preserving cursors and uncertain writes.
use super::*;
impl FileArchive {
	/// Clear retained records and bytes without resetting revision or shares.
	/// Failure may mean committed erasure with pending physical cleanup; retry
	/// clear or cleanup_blobs. An uncertain journal outcome requires reopen.
	pub async fn clear(&mut self) -> Result<(), Error> {
		self.submit(|store| store.clear().map(|()| Completion::Cleaned)).await?;
		Ok(())
	}
}
impl Store {
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
		self.blobs.as_mut().expect("opened blobs").erase().map_err(|cleanup| {
			DiskFailure::Corrupt("archive records erased; retained byte cleanup failed".into()).retain(cleanup)
		})
	}
}
