use super::{Directory, StorageError};
use rooms_application::documents::WriteFailure;
use std::{
	fs::{self, File, OpenOptions},
	io::{self, Write},
	path::{Path, PathBuf},
	sync::atomic::{AtomicU64, Ordering},
};
static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);
/// Whether a directory entry is one of `staged`'s files.
pub(crate) fn is_staged(name: &std::ffi::OsStr) -> bool {
	name.to_str()
		.is_some_and(|name| name.starts_with('.') && name.contains(".tmp-"))
}
pub fn staged(directory: &std::path::Path, name: &str) -> Result<(PathBuf, File), StorageError> {
	for _ in 0..16 {
		let next = NEXT_TEMP
			.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
			.map_err(|_| io::Error::other("temporary-file identities exhausted"))?;
		let path = directory.join(format!(".{}.tmp-{}-{next}", name, std::process::id()));
		let mut options = OpenOptions::new();
		options.write(true).create_new(true);
		#[cfg(unix)]
		{
			use std::os::unix::fs::OpenOptionsExt;
			options.mode(0o600);
		}
		match options.open(&path) {
			Ok(file) => return Ok((path, file)),
			Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
			Err(e) => return Err(e.into()),
		}
	}
	Err(io::Error::other("temporary-file names are occupied").into())
}

pub fn replace<'a>(
	directory: &Directory,
	name: &str,
	chunks: impl IntoIterator<Item = &'a [u8]>,
) -> Result<(), WriteFailure<StorageError>> {
	replace_with_sync(directory, name, chunks, || directory.directory.sync_all())
}

/// Replace a file in a directory this process does not hold a lease on, such
/// as a readiness mirror outside the state directory. The directory is opened
/// only to sync the rename. Nothing else about it is claimed.
pub fn replace_at<'a>(
	directory: &Path,
	name: &str,
	chunks: impl IntoIterator<Item = &'a [u8]>,
) -> Result<(), WriteFailure<StorageError>> {
	let handle = File::open(directory).map_err(|e| WriteFailure::Unchanged(e.into()))?;
	replace_in(directory, name, chunks, || handle.sync_all())
}

pub fn replace_with_sync<'a>(
	directory: &Directory,
	name: &str,
	chunks: impl IntoIterator<Item = &'a [u8]>,
	sync_directory: impl FnOnce() -> io::Result<()>,
) -> Result<(), WriteFailure<StorageError>> {
	replace_in(&directory.path, name, chunks, sync_directory)
}

// Directory synchronization is an explicit last operation: an error there
// cannot be reported as an unchanged document after rename already committed.
fn replace_in<'a>(
	directory: &Path,
	name: &str,
	chunks: impl IntoIterator<Item = &'a [u8]>,
	sync_directory: impl FnOnce() -> io::Result<()>,
) -> Result<(), WriteFailure<StorageError>> {
	let (temporary, mut file) = staged(directory, name).map_err(WriteFailure::Unchanged)?;
	let mut replacing = false;
	let result = (|| -> io::Result<()> {
		for bytes in chunks {
			file.write_all(bytes)?;
		}
		file.sync_all()?;
		drop(file);
		// Treat even a refused rename as uncertain. Some filesystems can report
		// an error after performing an operation; recovery must inspect reality.
		replacing = true;
		fs::rename(&temporary, directory.join(name))?;
		sync_directory()
	})();
	match result {
		Ok(()) => Ok(()),
		Err(error) => {
			let mut error = StorageError::Io(error);
			if let Err(cleanup) = fs::remove_file(&temporary)
				&& cleanup.kind() != io::ErrorKind::NotFound
			{
				error = StorageError::Cleanup {
					primary: Box::new(error),
					cleanup,
				};
			}
			Err(if replacing {
				WriteFailure::Indeterminate(error)
			} else {
				WriteFailure::Unchanged(error)
			})
		}
	}
}

/// An append may be torn after its first write or committed despite a failed
/// fsync. Only an open failure can certify that the existing file is unchanged.
pub fn append(directory: &Directory, name: &str, bytes: &[u8]) -> Result<(), WriteFailure<StorageError>> {
	let mut file = OpenOptions::new()
		.append(true)
		.open(directory.path.join(name))
		.map_err(|e| WriteFailure::Unchanged(e.into()))?;
	file.write_all(bytes)
		.and_then(|_| file.sync_all())
		.map_err(|e| WriteFailure::Indeterminate(e.into()))
}
