use super::{FileCallError, FileError, FileLineError, CHUNK_BYTES};
use crate::failure::FailureCode;
use core::fmt;

impl FileError {
	pub const fn code(self) -> Option<FailureCode> {
		match self {
			Self::Description | Self::Size => Some(FailureCode::BadAttachment),
			Self::Capacity | Self::StagedLimit | Self::Allocation | Self::ReadersFull => {
				Some(FailureCode::AttachmentRefused)
			}
			Self::Spent | Self::NotPublished | Self::ChunkTooLarge | Self::PastEnd => {
				Some(FailureCode::UploadIncomplete)
			}
			Self::Expired => Some(FailureCode::BlobExpired),
			_ => None,
		}
	}
}

impl fmt::Display for FileError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		if let Some(code) = self.code() {
			write!(f, "{}: ", code.wire())?;
		}
		f.write_str(match self {
			Self::Description => "the file description is invalid",
			Self::Size => "the file exceeds the allowed size",
			Self::Capacity => "there is no capacity for this file",
			Self::StagedLimit => "this membership has too many staged files",
			Self::Allocation => "the file buffer could not be allocated",
			Self::WrongStore => "the file belongs to another host",
			Self::WrongRoom => "the file belongs to another room",
			Self::Closed => "the file's room or membership has closed",
			Self::Expired => "this file is no longer held by the room",
			Self::Spent => "this upload is spent; attach again",
			Self::NotPublished => "publish this upload before writing its bytes",
			Self::ChunkTooLarge => return write!(f, "a chunk may be at most {CHUNK_BYTES} bytes"),
			Self::PastEnd => "write runs past the declared file size",
			Self::InvalidRead => "read needs a positive maximum length",
			Self::ReadersFull => "this file has too many readers waiting for its bytes",
			Self::ClockReversed => "the file clock moved backwards",
			Self::IdentityExhausted => "the file owner cannot mint another identity",
		})
	}
}

impl fmt::Display for FileCallError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Self::UnexpectedCapability => "file methods do not take capability arguments",
			Self::WriteArguments => "write needs one byte chunk",
			Self::DiscardArguments => "discard takes no arguments",
			Self::ReadArguments => "read needs an offset and maximum length",
			Self::Offset => "read needs offset >= 0",
			Self::Length => "read needs maxLen > 0",
			Self::UnknownMethod(verb) => return write!(f, "file has no method {verb}"),
			Self::File(error) => return error.fmt(f),
		})
	}
}

impl fmt::Display for FileLineError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Files(e) => e.fmt(f),
			Self::Line(e) => e.fmt(f),
		}
	}
}

impl core::error::Error for FileError {}
impl core::error::Error for FileCallError {}
impl core::error::Error for FileLineError {}
