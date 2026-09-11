//! Shared native filesystem custody and durable replacement. Application
//! codecs decide document validity; disk workers retain the directory lease.
use rooms_application::documents::DocumentError;
use std::{
	fmt,
	fs::{self, File, OpenOptions},
	io::{self, Read},
	path::PathBuf,
};
pub(crate) mod atomic;
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

pub(crate) struct Directory {
	pub(crate) path: PathBuf,
	// Every worker retains this lease, even if the application owner is dropped.
	_lock: File,
	pub(crate) directory: File,
}

impl Directory {
	pub(crate) fn open(path: PathBuf, lock_name: &str) -> Result<Self, StorageError> {
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
		lock.try_lock().map_err(|e| {
			let error = io::Error::from(e);
			if error.kind() == io::ErrorKind::WouldBlock {
				StorageError::InUse(path.clone())
			} else {
				StorageError::Io(error)
			}
		})?;
		// The lease is held, so a staging file still here belongs to an
		// incarnation that died mid-replacement; its document was never renamed
		// into place and it is nothing but debris.
		for entry in fs::read_dir(&path)? {
			let entry = entry?;
			let name = entry.file_name();
			if atomic::is_staged(&name) && entry.file_type()?.is_file() {
				fs::remove_file(entry.path())?;
			}
		}
		Ok(Self {
			path,
			directory,
			_lock: lock,
		})
	}
}

pub(crate) fn read(path: &std::path::Path, max: usize) -> Result<Option<Vec<u8>>, StorageError> {
	let metadata = match fs::metadata(path) {
		Ok(value) => value,
		Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
		Err(e) => return Err(e.into()),
	};
	if !metadata.is_file() {
		return Err(io::Error::other("a Rooms state file must be a regular file").into());
	}
	let mut file = match File::open(path) {
		Ok(file) => file,
		Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
		Err(e) => return Err(e.into()),
	};
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
	Ok(Some(bytes))
}
