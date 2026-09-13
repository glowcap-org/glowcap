//! Exact Rooms upload/blob method admission over borrowed binding arguments.
use super::*;
use crate::room::ArgumentView;

pub trait FileArgument: ArgumentView {
	fn bytes(&self) -> Option<&[u8]>;
	/// Non-negative wire integers only, saturating above u64::MAX. This keeps
	/// arbitrary-size offsets valid without allocating a bignum in Rooms.
	fn natural(&self) -> Option<u64>;
}

#[derive(Debug, PartialEq, Eq)]
pub enum FileCallError {
	UnexpectedCapability,
	WriteArguments,
	DiscardArguments,
	ReadArguments,
	Offset,
	Length,
	UnknownMethod(String),
	File(FileError),
}

impl From<FileError> for FileCallError {
	fn from(error: FileError) -> Self {
		Self::File(error)
	}
}

impl FileStore {
	pub fn upload_call<A: FileArgument>(
		&mut self,
		upload: &Upload,
		verb: &str,
		args: &[A],
	) -> Result<(), FileCallError> {
		if args.iter().any(ArgumentView::contains_capability) {
			return Err(FileCallError::UnexpectedCapability);
		}
		self.check(&upload.blob.key)?;
		self.collect_file(upload.blob.key.id);
		let phase = self.records.get(&upload.blob.key.id).ok_or(FileError::Spent)?.phase;
		if phase == Phase::Held {
			return Err(FileError::Spent.into());
		}
		match verb {
			crate::protocol_data::WRITE => {
				let [chunk] = args else {
					return Err(FileCallError::WriteArguments);
				};
				if phase == Phase::Staged {
					return Err(FileError::NotPublished.into());
				}
				self.write(upload, chunk.bytes().ok_or(FileCallError::WriteArguments)?)?;
			}
			crate::protocol_data::DISCARD => {
				if !args.is_empty() {
					return Err(FileCallError::DiscardArguments);
				}
				self.discard(upload)?;
			}
			_ => return Err(FileCallError::UnknownMethod(verb.into())),
		}
		Ok(())
	}
	pub fn blob_call<A: FileArgument>(
		&mut self,
		blob: &Blob,
		verb: &str,
		args: &[A],
	) -> Result<ReadOutcome<'_>, FileCallError> {
		if args.iter().any(ArgumentView::contains_capability) {
			return Err(FileCallError::UnexpectedCapability);
		}
		if verb != crate::protocol_data::READ {
			return Err(FileCallError::UnknownMethod(verb.into()));
		}
		let [offset, length] = args else {
			return Err(FileCallError::ReadArguments);
		};
		self.check(&blob.key)?;
		self.collect_file(blob.key.id);
		if !self.records.contains_key(&blob.key.id) {
			return Err(FileError::Expired.into());
		}
		let offset = offset.natural().ok_or(FileCallError::Offset)?;
		let length = length
			.natural()
			.filter(|&length| length > 0)
			.ok_or(FileCallError::Length)?;
		Ok(self.read(blob, offset, length)?)
	}
}
