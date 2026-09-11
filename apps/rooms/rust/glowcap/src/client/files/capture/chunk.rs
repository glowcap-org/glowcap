//! Owned network chunks and bounded spans of immutable captured allocations.
use std::{ops::Range, sync::Arc};
pub struct Chunk(Backing);
enum Backing {
	Owned(Vec<u8>),
	Shared(Arc<Box<[u8]>>, Range<usize>),
}
impl Chunk {
	/// Bound the allocation retained across an executor handoff, not merely the
	/// visible span. A slice of a large local file detaches only this small span.
	pub fn into_bounded(self, maximum: usize) -> Result<Self, String> {
		if self.as_ref().len() > maximum {
			return Err("chunk exceeds its handoff ceiling".into());
		}
		match self.0 {
			Backing::Shared(bytes, range) if bytes.len() > maximum => Ok(bytes[range].to_vec().into()),
			Backing::Owned(bytes) if bytes.capacity() > maximum => Ok(bytes.into_boxed_slice().into_vec().into()),
			backing => Ok(Self(backing)),
		}
	}

	pub fn into_vec(self) -> Vec<u8> {
		match self.0 {
			Backing::Owned(bytes) => bytes,
			Backing::Shared(bytes, range) => bytes[range].to_vec(),
		}
	}
	pub fn shared(bytes: Arc<Box<[u8]>>, range: Range<usize>) -> Result<Self, String> {
		bytes.get(range.clone()).ok_or("captured chunk range is invalid")?;
		Ok(Self(Backing::Shared(bytes, range)))
	}
}
impl From<Vec<u8>> for Chunk {
	fn from(bytes: Vec<u8>) -> Self {
		Self(Backing::Owned(bytes))
	}
}
impl AsRef<[u8]> for Chunk {
	fn as_ref(&self) -> &[u8] {
		match &self.0 {
			Backing::Owned(bytes) => bytes,
			Backing::Shared(bytes, range) => &bytes[range.clone()],
		}
	}
}
