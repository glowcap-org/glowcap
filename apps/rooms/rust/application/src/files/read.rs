//! File reads validate metadata and expose bounded chunk requests.
use super::*;
use core::{
	ops::Range,
	task::{Context, Poll},
};

/// A pending read retains its blob authority but no file bytes. Dropping this
/// ticket cancels the registration, including before any bytes arrive.
pub struct ReadTicket {
	blob: Blob,
	offset: u64,
	max_len: u64,
	wake: Rc<ReaderWake>,
}

pub enum ReadOutcome<'a> {
	Ready(&'a [u8]),
	Waiting(ReadTicket),
}

fn range(record: &Record, offset: u64, max_len: u64) -> Result<Option<Range<usize>>, FileError> {
	if !record.live() {
		return Err(FileError::Expired);
	}
	if max_len == 0 {
		return Err(FileError::InvalidRead);
	}
	let start = offset.min(record.bytes.len() as u64) as usize;
	if start < record.written || record.written == record.bytes.len() {
		let len = (max_len.min(CHUNK_BYTES as u64) as usize).min(record.written.saturating_sub(start));
		Ok(Some(start..start + len))
	} else {
		Ok(None)
	}
}

impl FileStore {
	/// The borrowed chunk prevents mutation or eviction until the caller finishes
	/// encoding it. Waiting readers do not borrow the store or pin byte buffers.
	pub fn read(&mut self, blob: &Blob, offset: u64, max_len: u64) -> Result<ReadOutcome<'_>, FileError> {
		self.check(&blob.key)?;
		self.collect_file(blob.key.id);
		let record = self.records.get_mut(&blob.key.id).ok_or(FileError::Expired)?;
		if let Some(range) = range(record, offset, max_len)? {
			return Ok(ReadOutcome::Ready(&record.bytes[range]));
		}
		record.readers.retain(|r| r.strong_count() > 0);
		if record.readers.len() >= MAX_BLOB_READERS {
			return Err(FileError::ReadersFull);
		}
		let wake = Rc::new(ReaderWake {
			offset: offset.min(record.bytes.len() as u64) as usize,
			waker: RefCell::new(None),
		});
		record.readers.push(Rc::downgrade(&wake));
		Ok(ReadOutcome::Waiting(ReadTicket {
			blob: blob.clone(),
			offset,
			max_len,
			wake,
		}))
	}
	/// Poll from the application executor and encode the ready slice in that
	/// turn. The ticket has no executor dependency and can be cancelled by drop.
	pub fn poll_read<'a>(&'a self, ticket: &ReadTicket, cx: &mut Context<'_>) -> Poll<Result<&'a [u8], FileError>> {
		if let Err(error) = self.check(&ticket.blob.key) {
			return Poll::Ready(Err(error));
		}
		let Some(record) = self.records.get(&ticket.blob.key.id) else {
			return Poll::Ready(Err(FileError::Expired));
		};
		match range(record, ticket.offset, ticket.max_len) {
			Err(error) => Poll::Ready(Err(error)),
			Ok(Some(range)) => Poll::Ready(Ok(&record.bytes[range])),
			Ok(None) => {
				let mut wake = ticket.wake.waker.borrow_mut();
				if wake.as_ref().is_none_or(|w| !w.will_wake(cx.waker())) {
					*wake = Some(cx.waker().clone());
				}
				Poll::Pending
			}
		}
	}
}
