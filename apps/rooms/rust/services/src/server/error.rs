//! One failure vocabulary for the directory peer. Every tier below renders
//! into it once. The operator reads it once.
use rooms_application::server::document;
use rooms_platform::storage::StorageError;
use std::{borrow::Cow, fmt};

/// Why a directory-peer operation did not complete. A `Refused` carries the
/// whole diagnosis as text because that text is the contract: for options it
/// is the exact line the operator reads.
#[derive(Debug)]
pub enum Error {
	Refused(Cow<'static, str>),
	Storage(Box<StorageError>),
	/// The server document on disk is not one this peer can adopt.
	Document(document::Error),
	DocumentAt {
		file: std::path::PathBuf,
		cause: document::Error,
	},
	/// The operations document on disk is not one this peer can adopt.
	Operations(rooms_application::server::operations::document::Error),
	Captp(Box<glowcap::Error>),
	Listener(Box<rooms_platform::serving::OpenError>),
	/// A disk worker did not run to completion.
	Worker(String),
	/// History storage is unusable or an admitted persistence effect failed.
	History(String),
	Io(std::io::Error),
	/// A cleanup that failed while the peer was already failing. The primary
	/// cause stays first. The cleanup keeps its own name.
	Cleanup {
		primary: Box<Error>,
		cleanup: Box<Error>,
	},
}

impl Error {
	pub(super) fn refused(detail: impl Into<Cow<'static, str>>) -> Self {
		Self::Refused(detail.into())
	}
	/// The outcome of `primary` followed by `cleanup`.
	pub(super) fn fold(primary: Result<(), Error>, cleanup: Result<(), Error>) -> Result<(), Error> {
		match (primary, cleanup) {
			(Ok(()), outcome) | (outcome, Ok(())) => outcome,
			(Err(primary), Err(cleanup)) => Err(primary.retain(Err(cleanup))),
		}
	}
	/// This failure, keeping the failure of the cleanup that followed it.
	pub(super) fn retain(self, cleanup: Result<(), Error>) -> Error {
		match cleanup {
			Ok(()) => self,
			Err(cleanup) => Self::Cleanup {
				primary: Box::new(self),
				cleanup: Box::new(cleanup),
			},
		}
	}
}

impl From<StorageError> for Error {
	fn from(error: StorageError) -> Self {
		Self::Storage(Box::new(error))
	}
}
impl From<rooms_platform::serving::OpenError> for Error {
	fn from(error: rooms_platform::serving::OpenError) -> Self {
		Self::Listener(Box::new(error))
	}
}
impl From<document::Error> for Error {
	fn from(error: document::Error) -> Self {
		Self::Document(error)
	}
}
impl From<glowcap::Error> for Error {
	fn from(error: glowcap::Error) -> Self {
		Self::Captp(Box::new(error))
	}
}
impl From<Box<glowcap::Error>> for Error {
	fn from(error: Box<glowcap::Error>) -> Self {
		Self::Captp(error)
	}
}
impl From<std::io::Error> for Error {
	fn from(error: std::io::Error) -> Self {
		Self::Io(error)
	}
}

impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Refused(detail) => f.write_str(detail),
			Self::Storage(error) => error.fmt(f),
			// The document is sound and only this change would outgrow it.
			Self::Document(error @ document::Error::Size) => write!(f, "{error}"),
			Self::Document(error) => write!(f, "the server document is unusable: {error}"),
			Self::DocumentAt { file, cause } => {
				write!(f, "the server document is unusable: {}: {cause}", file.display())
			}
			Self::Operations(error) => write!(f, "the operations document is unusable: {error}"),
			Self::Captp(error) => error.fmt(f),
			Self::Listener(error) => error.fmt(f),
			Self::Worker(cause) => write!(f, "a disk worker failed: {cause}"),
			Self::History(what) => f.write_str(what),
			Self::Io(error) => error.fmt(f),
			Self::Cleanup { primary, cleanup } => write!(f, "{primary}; cleanup also failed: {cleanup}"),
		}
	}
}
impl std::error::Error for Error {}
