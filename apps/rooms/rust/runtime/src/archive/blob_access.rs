//! Committed blob reads can run while a serial file write waits on its sources.
//! The backend checks the reader against current committed state on every read.
use rooms_application::archive::blobs::Reader;
use std::future::Future;
pub trait BlobAccess {
	fn read(&self, reader: Reader, offset: u64, maximum: usize) -> impl Future<Output = Result<Vec<u8>, String>>;
}
pub struct UnavailableBlobs;
impl BlobAccess for UnavailableBlobs {
	async fn read(&self, _: Reader, _: u64, _: usize) -> Result<Vec<u8>, String> {
		Err("archive backend does not support independent blob reads".into())
	}
}

/// A backend never widens the caller's bounded byte request.
pub(crate) fn checked_bytes(bytes: Vec<u8>, maximum: usize) -> Result<Vec<u8>, String> {
	if bytes.len() > maximum || bytes.len() > rooms_application::files::CHUNK_BYTES {
		return Err("archive backend returned an oversized blob chunk".into());
	}
	Ok(bytes)
}
