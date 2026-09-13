//! Committed blob reads can run while a serial file write waits on its sources.
//! The backend checks the reader against current committed state on every read.
use crate::Error;
use rooms_application::archive::blobs::Reader;
use std::future::Future;
pub trait BlobAccess {
	fn read(&self, reader: Reader, offset: u64, maximum: usize) -> impl Future<Output = Result<Vec<u8>, Error>>;
}
pub struct UnavailableBlobs;
impl BlobAccess for UnavailableBlobs {
	async fn read(&self, _: Reader, _: u64, _: usize) -> Result<Vec<u8>, Error> {
		Err(Error::refused(
			"archive backend does not support independent blob reads",
		))
	}
}

/// A backend never widens the caller's bounded byte request. One that did has
/// broken its contract, which is a storage failure rather than a bad request.
pub(crate) fn checked_bytes(bytes: Vec<u8>, maximum: usize) -> Result<Vec<u8>, Error> {
	if bytes.len() > maximum || bytes.len() > rooms_application::files::CHUNK_BYTES {
		return Err(Error::storage_message(
			"archive backend returned an oversized blob chunk",
		));
	}
	Ok(bytes)
}
