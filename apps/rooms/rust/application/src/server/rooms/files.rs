//! The bytes a room holds for the files posted in it. The store is the
//! owner; these verbs name the upload or blob an actor stands for and hand
//! the call through, so admission, budgets, and eviction live in one place.
use super::{entrance::LossyString, Refusal, Rooms, UploadKey};
use crate::files::{Blob, FileArgument, FileCallError, ReadOutcome};

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	pub(super) fn file_time(&mut self, monotonic_ms: u64) -> Result<(), Refusal> {
		self.files
			.observe_time(monotonic_ms)
			.map_err(|error| Refusal::plain(error.to_string_lossy()))
	}

	/// `write` and `discard` on an upload in flight.
	pub fn upload_verb<A: FileArgument>(
		&mut self,
		key: UploadKey,
		verb: &str,
		args: &[A],
		monotonic_ms: u64,
	) -> Result<(), Refusal> {
		self.file_time(monotonic_ms)?;
		let Some(upload) = self.uploads.get(&key) else {
			return Err(Refusal::coded(
				crate::failure::FailureCode::UploadIncomplete,
				"this upload is spent; attach again",
			));
		};
		let upload = upload.upload.clone();
		let result = self.files.upload_call(&upload, verb, args);
		match result {
			Ok(()) => Ok(()),
			Err(FileCallError::UnknownMethod(verb)) => {
				Err(Refusal::plain(alloc::format!("upload has no method {verb}")))
			}
			Err(error) => Err(Refusal::plain(error.to_string_lossy())),
		}
	}
	/// `read` on a blob: bytes now, or a ticket the adapter polls until the
	/// bytes arrive or the file expires.
	pub fn blob_verb<A: FileArgument>(
		&mut self,
		blob: &Blob,
		verb: &str,
		args: &[A],
		monotonic_ms: u64,
	) -> Result<ReadOutcome<'_>, Refusal> {
		self.file_time(monotonic_ms)?;
		self.files
			.blob_call(blob, verb, args)
			.map_err(|error| Refusal::plain(error.to_string_lossy()))
	}
	/// Uploads that went quiet past their idle window are reclaimed here.
	pub fn advance(&mut self, now: u64) {
		// A clock that did not move forward is nothing to act on.
		let _ = self.files.advance(now);
		let spent: alloc::vec::Vec<_> = self
			.uploads
			.iter()
			.filter(|(_, upload)| self.files.upload_spent(&upload.upload))
			.map(|(key, _)| *key)
			.collect();
		for key in spent {
			self.uploads.remove(&key);
		}
	}
	pub fn next_upload_deadline(&self) -> Option<u64> {
		self.files.next_deadline()
	}
}
