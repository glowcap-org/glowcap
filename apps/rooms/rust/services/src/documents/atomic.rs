use super::{Directory, StorageError, filename};
use rooms_application::documents::SessionDocument;
use rooms_application::documents::WriteFailure;
use std::path::Path;

pub(super) fn read(path: &Path, document: SessionDocument) -> Result<Option<Vec<u8>>, StorageError> {
	let Some(mut bytes) = rooms_platform::storage::read(path, document.max_bytes())? else {
		return Ok(None);
	};
	document.decode(&bytes)?;
	if bytes.starts_with(b"\xef\xbb\xbf") {
		bytes.drain(..3);
	}
	Ok(Some(bytes))
}

pub(super) fn replace(
	directory: &Directory,
	document: SessionDocument,
	bytes: &[u8],
) -> Result<(), WriteFailure<StorageError>> {
	rooms_platform::storage::atomic::replace(directory, filename(document), core::iter::once(bytes))
}
