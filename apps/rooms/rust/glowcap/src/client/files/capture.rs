//! Immutable file materialization shared by independent application readers.
//! Capture uses bounded source reads; aligned spans share their allocations.
use super::{Deadline, File};
use rooms_application::files::{FileDescription, CHUNK_BYTES};
use std::sync::Arc;
mod chunk;
pub use chunk::Chunk;
#[derive(Clone)]
pub struct Captured {
	description: FileDescription,
	storage: Storage,
}
#[derive(Clone)]
enum Storage {
	Chunks(Vec<Arc<Box<[u8]>>>),
	Contiguous(Arc<Box<[u8]>>),
}
impl Captured {
	pub fn description(&self) -> &FileDescription {
		&self.description
	}
	pub async fn read<D: Deadline>(source: &File<D>) -> Result<Self, String> {
		Self::read_with(source.attachment().description.clone(), |offset, length| async move {
			source.read(offset, length).await.map_err(|error| error.to_string())
		})
		.await
	}
	/// A local immutable source can share its original allocation with captures
	/// and disk spans instead of assembling a second whole-file buffer.
	pub fn from_shared(description: FileDescription, bytes: Arc<Box<[u8]>>) -> Result<Self, String> {
		if description.size() != bytes.len() {
			return Err("capture source size does not match its description".into());
		}
		Ok(Self {
			description,
			storage: Storage::Contiguous(bytes),
		})
	}
	pub async fn read_with<F: core::future::Future<Output = Result<Vec<u8>, String>>>(
		description: FileDescription,
		mut read: impl FnMut(u64, usize) -> F,
	) -> Result<Self, String> {
		let mut chunks = Vec::with_capacity(description.size().div_ceil(CHUNK_BYTES));
		let mut offset = 0;
		while offset < description.size() {
			let length = CHUNK_BYTES.min(description.size() - offset);
			let bytes = read(offset as u64, length).await?;
			if bytes.len() != length {
				return Err("capture source returned an invalid span".into());
			}
			// Boxing removes spare Vec capacity. Arc owns that box rather than
			// copying its payload into an Arc slice allocation.
			chunks.push(Arc::new(bytes.into_boxed_slice()));
			offset += length;
		}
		Ok(Self {
			description,
			storage: Storage::Chunks(chunks),
		})
	}
	pub fn span(&self, offset: u64, maximum: usize) -> Result<Chunk, String> {
		let length = rooms_application::files::transfer::read_length(self.description.size(), offset, maximum)
			.map_err(|e| e.to_string())?;
		if length == 0 {
			return Ok(Vec::new().into());
		}
		let offset = offset as usize;
		let chunks = match &self.storage {
			Storage::Contiguous(bytes) => return Chunk::shared(bytes.clone(), offset..offset + length),
			Storage::Chunks(chunks) => chunks,
		};
		let index = offset / CHUNK_BYTES;
		let start = offset % CHUNK_BYTES;
		let first = &chunks[index];
		if start + length <= first.len() {
			return Chunk::shared(first.clone(), start..start + length);
		}
		let mut bytes = Vec::with_capacity(length);
		bytes.extend_from_slice(&first[start..]);
		bytes.extend_from_slice(&chunks[index + 1][..length - bytes.len()]);
		Ok(bytes.into())
	}
}
#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn captured_spans_share_aligned_storage_and_join_only_crossing_reads() {
		let size = CHUNK_BYTES + 3;
		let captured = Captured {
			description: FileDescription::new("file".into(), "text/plain".into(), size as u64, 0, 0).unwrap(),
			storage: Storage::Chunks(vec![
				Arc::new(vec![1; CHUNK_BYTES].into_boxed_slice()),
				Arc::new(vec![2, 3, 4].into_boxed_slice()),
			]),
		};
		let aligned = captured.span(0, CHUNK_BYTES).unwrap();
		assert_eq!(
			aligned.as_ref().as_ptr(),
			match &captured.storage {
				Storage::Chunks(chunks) => chunks[0].as_ptr(),
				_ => unreachable!(),
			}
		);
		assert_eq!(
			captured.span((CHUNK_BYTES - 2) as u64, 5).unwrap().into_vec(),
			[1, 1, 2, 3, 4]
		);
		assert!(captured.span(size as u64, 1).unwrap().as_ref().is_empty());
		assert_eq!(captured.span(0, CHUNK_BYTES + 1).unwrap().as_ref().len(), CHUNK_BYTES);
		assert!(captured.span(0, 0).is_err());
		assert!(captured.span(1 << 53, 1).unwrap().as_ref().is_empty());
		drop(captured);
		assert_eq!(
			aligned.as_ref(),
			vec![1; CHUNK_BYTES],
			"the disk job owns its shared chunk independently"
		);
	}
}
