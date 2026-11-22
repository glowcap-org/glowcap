//! The bot's typed failures. A refused lease, an unusable configuration, or
//! unreadable state stops `serve` before it starts. Once it serves, every
//! failure is handled where it is caught and the process stays up.
use super::rooms::RoomsError;
use nix::errno::Errno;
use rooms_application::documents::WriteFailure;
use rooms_platform::storage::StorageError;
use std::{fmt, io, path::PathBuf};

#[derive(Debug)]
pub enum Error {
	/// A command line or request the bot cannot act on.
	Usage(String),
	/// The stored or supplied configuration is unusable.
	Config(String),
	/// Another `serve` holds the bot directory.
	Lease(PathBuf),
	/// A state file is damaged or cannot be written.
	Storage(StorageError),
	/// A state file's replacement failed after it may have landed, so the
	/// file holds the old document or the new one.
	Unsettled(StorageError),
	/// The bot's state broke one of its own rules.
	State {
		file: String,
		reason: String,
	},
	/// A stored document does not decode, as one another build of the bot
	/// wrote may not.
	Unreadable {
		file: String,
		reason: String,
	},
	Io {
		context: &'static str,
		source: io::Error,
	},
	Rooms(RoomsError),
	/// An action verb's failure, already in the shape its caller reads: the
	/// JSON line it prints, and the sentence a person sees.
	Action {
		response: serde_json::Value,
		message: String,
	},
	/// `ready` found the bot not serving or not attached to a session that
	/// answers.
	NotReady(String),
	/// The system gave no randomness for an operation id.
	Entropy(String),
	/// A state document would pass the size the bot reads back.
	TooLarge {
		file: String,
		bytes: usize,
		limit: usize,
	},
}

impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Usage(reason) | Self::Config(reason) | Self::NotReady(reason) => reason.fmt(f),
			Self::Lease(path) => write!(
				f,
				"another rooms-bot serve already holds {}. Stop it before starting a second one",
				path.display()
			),
			Self::Storage(error) => error.fmt(f),
			Self::Unsettled(error) => write!(f, "{error}. The file may hold the change, so it is written again"),
			Self::State { file, reason } => write!(
				f,
				"{file} is unreadable: {reason}. Preserve it and inspect before restart"
			),
			Self::Unreadable { file, reason } => write!(
				f,
				"{file} in the bot directory is unreadable: {reason}. Keep a copy of the directory to inspect. \
				 A directory written by another build of the bot needs a fresh start: remove the directory \
				 (under Compose, the bot's container and state volume) and serve again with the same --link"
			),
			Self::Io { context, source } => write!(f, "{context}: {source}"),
			Self::Rooms(error) => error.fmt(f),
			Self::Action { message, .. } => message.fmt(f),
			Self::Entropy(reason) => write!(f, "no randomness for an operation id: {reason}"),
			Self::TooLarge { file, bytes, limit } => {
				write!(f, "{file} would be {bytes} bytes, past its {limit}-byte bound")
			}
		}
	}
}

impl std::error::Error for Error {}

impl Error {
	pub fn io(context: &'static str) -> impl FnOnce(io::Error) -> Self {
		move |source| Self::Io { context, source }
	}
	/// Whether waiting and doing the same work again can succeed. Only the
	/// system failures in [`CLEARING`] can clear on their own. A document the
	/// bot cannot read, one that has outgrown its bound, a path that is not a
	/// regular file, and a refused permission stay that way until a person acts.
	pub fn is_transient(&self) -> bool {
		match self {
			Self::Storage(error) | Self::Unsettled(error) => storage_clears(error),
			Self::Io { source, .. } => clears(source),
			Self::Entropy(_) => true,
			Self::Usage(_)
			| Self::Config(_)
			| Self::NotReady(_)
			| Self::Lease(_)
			| Self::State { .. }
			| Self::Unreadable { .. }
			| Self::Rooms(_)
			| Self::Action { .. }
			| Self::TooLarge { .. } => false,
		}
	}
	pub fn unreadable(file: &str, reason: impl ToString) -> Self {
		Self::Unreadable {
			file: file.into(),
			reason: reason.to_string(),
		}
	}

	pub fn state(file: &str, reason: impl ToString) -> Self {
		Self::State {
			file: file.into(),
			reason: reason.to_string(),
		}
	}
}

/// The system failures that clear with time: a full disk or quota, an
/// interrupted or busy call, a device error, and running out of memory or
/// open files. Every other failure needs a person to change something.
pub const CLEARING: [Errno; 9] = [
	Errno::ENOSPC,
	Errno::EDQUOT,
	Errno::EIO,
	Errno::EINTR,
	Errno::EAGAIN,
	Errno::ENOMEM,
	Errno::EMFILE,
	Errno::ENFILE,
	Errno::EBUSY,
];

fn clears(error: &io::Error) -> bool {
	error
		.raw_os_error()
		.is_some_and(|code| CLEARING.contains(&Errno::from_raw(code)))
}

fn storage_clears(error: &StorageError) -> bool {
	match error {
		StorageError::Io(source) => clears(source),
		StorageError::Cleanup { primary, .. } => storage_clears(primary),
		// The storage worker is busy or restarting.
		StorageError::Pending | StorageError::Worker(_) => true,
		StorageError::Document(_) | StorageError::InUse(_) => false,
	}
}

impl From<StorageError> for Error {
	fn from(error: StorageError) -> Self {
		Self::Storage(error)
	}
}

/// A replacement that may have landed stays distinct, so the ledger can
/// write the same document again rather than a different one.
impl From<WriteFailure<StorageError>> for Error {
	fn from(failure: WriteFailure<StorageError>) -> Self {
		match failure {
			WriteFailure::Unchanged(error) => Self::Storage(error),
			WriteFailure::Indeterminate(error) => Self::Unsettled(error),
		}
	}
}

impl From<RoomsError> for Error {
	fn from(error: RoomsError) -> Self {
		Self::Rooms(error)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::documents::DocumentError;

	#[test]
	fn only_storage_failures_that_can_clear_are_transient() {
		let full = Error::Storage(StorageError::Io(io::Error::from_raw_os_error(28)));
		assert!(full.is_transient());
		let not_a_file = Error::Storage(StorageError::Io(io::Error::other("not a regular file")));
		assert!(!not_a_file.is_transient());
		let denied = Error::Storage(StorageError::Io(io::Error::from_raw_os_error(Errno::EACCES as i32)));
		assert!(!denied.is_transient(), "a refused permission waits for a person");
		let read_only = Error::Io {
			context: "writing",
			source: io::Error::from_raw_os_error(Errno::EROFS as i32),
		};
		assert!(!read_only.is_transient());
		for errno in CLEARING {
			let error = Error::Unsettled(StorageError::Io(io::Error::from_raw_os_error(errno as i32)));
			assert!(error.is_transient(), "{errno}");
		}
		assert!(!Error::Storage(StorageError::Document(DocumentError::TooLarge)).is_transient());
		assert!(!Error::state("turns.json", "damaged").is_transient());
	}
}
