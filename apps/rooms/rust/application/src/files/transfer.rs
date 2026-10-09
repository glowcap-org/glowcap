//! Client transfer progress. An unobserved write cannot safely be repeated:
//! the server may already have appended it. Discard and stage afresh instead.
use super::{CHUNK_BYTES, MAX_FILE_BYTES};
pub const STALL_MS: u64 = 60_000;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Size,
	Chunk,
	UnobservedWrite,
	Complete,
	ReadLength,
	ReadReply,
	UploadReply,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Size => "the transfer exceeds the file size limit",
			Self::Chunk => "the write must fit one chunk and the file's remaining bytes",
			Self::UnobservedWrite => "the last write has no acknowledgement; discard the upload before restarting",
			Self::Complete => "the upload is already complete",
			Self::ReadLength => "a blob read needs a positive length",
			Self::ReadReply => "the blob answered an empty, oversized, or non-byte chunk",
			Self::UploadReply => "attach did not return an upload capability",
		})
	}
}
impl core::error::Error for Error {}

pub struct UploadProgress {
	size: usize,
	written: usize,
	pending: Option<usize>,
}
impl UploadProgress {
	pub fn new(size: usize) -> Result<Self, Error> {
		if size > MAX_FILE_BYTES {
			return Err(Error::Size);
		}
		Ok(Self {
			size,
			written: 0,
			pending: None,
		})
	}
	pub fn written(&self) -> usize {
		self.written
	}
	pub fn remaining(&self) -> usize {
		self.size - self.written
	}
	pub fn complete(&self) -> bool {
		self.written == self.size
	}
	pub fn begin(&mut self, length: usize) -> Result<(), Error> {
		if self.pending.is_some() {
			return Err(Error::UnobservedWrite);
		}
		if self.complete() {
			return Err(Error::Complete);
		}
		if length == 0 || length > CHUNK_BYTES || length > self.remaining() {
			return Err(Error::Chunk);
		}
		self.pending = Some(length);
		Ok(())
	}
	pub fn acknowledge(&mut self) -> Result<(), Error> {
		self.written += self.pending.take().ok_or(Error::UnobservedWrite)?;
		Ok(())
	}
}

pub fn read_length(size: usize, offset: u64, maximum: usize) -> Result<usize, Error> {
	if size > MAX_FILE_BYTES {
		return Err(Error::Size);
	}
	if maximum == 0 {
		return Err(Error::ReadLength);
	}
	if offset >= size as u64 {
		return Ok(0);
	}
	Ok(maximum.min(CHUNK_BYTES).min(size - offset as usize))
}
pub fn accept_chunk(expected: usize, received: Option<usize>) -> Result<(), Error> {
	match received {
		Some(length) if length > 0 && length <= expected => Ok(()),
		_ => Err(Error::ReadReply),
	}
}
