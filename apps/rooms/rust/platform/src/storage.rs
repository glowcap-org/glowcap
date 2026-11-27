//! Shared host filesystem custody and durable replacement. Application
//! codecs decide document validity. Disk workers retain the directory lease.
use rooms_application::documents::DocumentError;
use std::{
	fmt,
	fs::{self, File, OpenOptions},
	io::{self, Read},
	path::{Path, PathBuf},
	time::{Duration, Instant},
};
pub mod atomic;
pub mod session;
#[cfg(test)]
mod tests;
#[derive(Debug)]
pub enum StorageError {
	Io(io::Error),
	Document(DocumentError),
	Pending,
	InUse(PathBuf),
	Worker(String),
	Cleanup {
		primary: Box<StorageError>,
		cleanup: io::Error,
	},
}
impl From<io::Error> for StorageError {
	fn from(e: io::Error) -> Self {
		Self::Io(e)
	}
}
impl From<DocumentError> for StorageError {
	fn from(e: DocumentError) -> Self {
		Self::Document(e)
	}
}
impl fmt::Display for StorageError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Io(e) => e.fmt(f),
			Self::Document(e) => e.fmt(f),
			Self::Pending => f.write_str("a document operation is still owned; finish it before starting another"),
			Self::InUse(path) => write!(f, "Rooms state directory is already in use: {}", path.display()),
			Self::Worker(e) => write!(f, "document worker failed: {e}"),
			Self::Cleanup { primary, cleanup } => write!(f, "{primary}; temporary-file cleanup also failed: {cleanup}"),
		}
	}
}
impl std::error::Error for StorageError {}

pub struct Directory {
	pub(crate) path: PathBuf,
	// Every worker retains this lease, even if the application owner is dropped.
	_lock: File,
	pub(crate) directory: File,
}

/// A reader's shared hold on a lease: it fails only against the exclusive
/// holder, never against another reader, and it keeps an exclusive taker
/// waiting only while the reader reads. Dropping it releases the hold.
pub struct Reading {
	_lock: Option<File>,
}

impl Reading {
	/// Ask whether `lock_name` in `path` is held exclusively, without creating
	/// anything. `Ok(Some)` means nobody holds it, and the reader keeps the
	/// shared hold while it reads what the holder would have written. A lease
	/// file that does not exist is held by nobody. `Ok(None)` means an
	/// exclusive holder, such as a running service.
	pub fn begin(path: &Path, lock_name: &str) -> Result<Option<Self>, StorageError> {
		let file = match OpenOptions::new().read(true).open(path.join(lock_name)) {
			Ok(file) => file,
			Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Some(Self { _lock: None })),
			Err(e) => return Err(e.into()),
		};
		match file.try_lock_shared() {
			Ok(()) => Ok(Some(Self { _lock: Some(file) })),
			Err(fs::TryLockError::WouldBlock) => Ok(None),
			Err(fs::TryLockError::Error(e)) => Err(e.into()),
		}
	}
}

impl Directory {
	pub fn open(path: PathBuf, lock_name: &str) -> Result<Self, StorageError> {
		Self::open_within(path, lock_name, Duration::ZERO)
	}

	/// [`Directory::open`] that waits up to `wait` for a lease held only
	/// briefly, such as by a [`Reading`], before answering `InUse`. The wait is
	/// bounded, so a holder that stays is refused at the end of it. A waiting
	/// taker has no priority over readers, so only readers that follow one
	/// another with no gap for the whole bound keep it out, and a reader holds
	/// for one small read.
	pub fn open_within(path: PathBuf, lock_name: &str, wait: Duration) -> Result<Self, StorageError> {
		let path = std::path::absolute(path)?;
		let mut missing = Vec::new();
		let mut ancestor = path.as_path();
		loop {
			match fs::metadata(ancestor) {
				Ok(_) => break,
				Err(e) if e.kind() == io::ErrorKind::NotFound => {
					missing.push(ancestor.to_owned());
					ancestor = ancestor.parent().ok_or(e)?;
				}
				Err(e) => return Err(e.into()),
			}
		}
		let mut builder = fs::DirBuilder::new();
		builder.recursive(true);
		#[cfg(unix)]
		{
			use std::os::unix::fs::DirBuilderExt;
			builder.mode(0o700);
		}
		builder.create(&path)?;
		// A synced document is not durable if its newly created parent can
		// disappear on restart. Persist each new directory entry up to the first
		// existing ancestor before allowing document replacement.
		for created in &missing {
			File::open(created)?.sync_all()?;
		}
		if !missing.is_empty() {
			File::open(ancestor)?.sync_all()?;
		}
		let path = fs::canonicalize(path)?;
		#[cfg(unix)]
		{
			use std::os::unix::fs::PermissionsExt;
			fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
		}
		let directory = File::open(&path)?;
		let mut options = OpenOptions::new();
		options.create(true).truncate(false).read(true).write(true);
		#[cfg(unix)]
		{
			use std::os::unix::fs::OpenOptionsExt;
			options.mode(0o600);
		}
		let lock = options.open(path.join(lock_name))?;
		let until = Instant::now() + wait;
		loop {
			match lock.try_lock() {
				Ok(()) => break,
				Err(fs::TryLockError::WouldBlock) if Instant::now() < until => {
					std::thread::sleep(Duration::from_millis(5));
				}
				Err(fs::TryLockError::WouldBlock) => return Err(StorageError::InUse(path.clone())),
				Err(fs::TryLockError::Error(e)) => return Err(e.into()),
			}
		}
		let owner = Self {
			path,
			directory,
			_lock: lock,
		};
		// The lease is held, so a staging file still here belongs to an
		// incarnation that died mid-replacement; its document was never renamed
		// into place and it is nothing but debris.
		for entry in fs::read_dir(&owner.path)? {
			let entry = entry?;
			let name = entry.file_name();
			if atomic::is_staged(&name) && entry.file_type()?.is_file() {
				fs::remove_file(entry.path())?;
			}
		}
		Ok(owner)
	}

	pub fn path(&self) -> &std::path::Path {
		&self.path
	}

	pub fn sync(&self) -> io::Result<()> {
		self.directory.sync_all()
	}
}

impl Drop for Directory {
	fn drop(&mut self) {
		// A child can inherit this open-file description until exec closes it.
		// Release the lease when its last worker finishes, rather than waiting
		// for every inherited descriptor to close. File drop remains the fallback.
		if let Err(error) = self._lock.unlock() {
			eprintln!("rooms: releasing state directory {}: {error}", self.path.display());
		}
	}
}

pub fn read(path: &std::path::Path, max: usize) -> Result<Option<Vec<u8>>, StorageError> {
	let metadata = match fs::metadata(path) {
		Ok(value) => value,
		Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
		Err(e) => return Err(e.into()),
	};
	if !metadata.is_file() {
		return Err(io::Error::other("a Rooms state file must be a regular file").into());
	}
	let file = match File::open(path) {
		Ok(file) => file,
		Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
		Err(e) => return Err(e.into()),
	};
	read_open(file, max).map(Some)
}

/// Read the bounded document from the same open file a caller inspected.
pub fn read_open(mut file: File, max: usize) -> Result<Vec<u8>, StorageError> {
	let metadata = file.metadata()?;
	if !metadata.is_file() {
		return Err(io::Error::other("a Rooms state file must be a regular file").into());
	}
	if metadata.len() > max as u64 {
		return Err(DocumentError::TooLarge.into());
	}
	// Reading one extra byte catches growth after stat; the file never chooses
	// an unbounded allocation. This is one owned startup/document buffer.
	let mut bytes = Vec::with_capacity((metadata.len() as usize).saturating_add(1).min(max + 1));
	std::io::Read::by_ref(&mut file)
		.take(max as u64 + 1)
		.read_to_end(&mut bytes)?;
	if bytes.len() > max {
		return Err(DocumentError::TooLarge.into());
	}
	Ok(bytes)
}
