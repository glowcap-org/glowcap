//! One failure vocabulary for the session peer. Every tier below renders into
//! it once, and the CapTP boundary renders it into a break reason once.
use crate::{grant_publications, grants, session_commands::AdmissionError, session_state, storage::StorageError};
use std::{borrow::Cow, fmt};

impl From<crate::serving::OpenError> for Error {
	fn from(error: crate::serving::OpenError) -> Self {
		Self::Listener(Box::new(error))
	}
}

/// Why a session-peer operation did not complete. A `Refused` carries the whole
/// diagnosis as text because that text is the contract: over CapTP it is the
/// exact break reason an attached view shows, and for options it is the exact
/// line the operator reads. Foreign causes are boxed so a `Result` of this
/// type stays small on every hot return path.
#[derive(Debug)]
pub enum Error {
	Refused(Cow<'static, str>),
	Admission(AdmissionError),
	State(Box<session_state::Error>),
	Storage(Box<StorageError>),
	GrantLoad(Box<grants::LoadError>),
	GrantPublication(Box<grant_publications::Error>),
	Captp(Box<glowcap::Error>),
	Listener(Box<crate::serving::OpenError>),
	Io {
		what: &'static str,
		source: std::io::Error,
	},
	/// The runtime tier still speaks `String`. This is the one place its
	/// failures enter the typed vocabulary, so a caller can tell a runtime
	/// refusal from an argument refusal without parsing text.
	Runtime(String),
	WorkerEnded {
		worker: Worker,
		cause: Option<Box<Error>>,
	},
	/// A cleanup that failed while the peer was already failing. The primary
	/// cause stays first; the cleanup keeps its own name instead of being
	/// folded into a sentence.
	Cleanup {
		primary: Box<Error>,
		cleanup: Box<Error>,
	},
}

pub use rooms_runtime::session_service::Worker;

impl Error {
	pub fn refused(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Refused(text.into())
	}
	pub fn runtime(text: impl Into<String>) -> Self {
		Self::Runtime(text.into())
	}
	pub fn io(what: &'static str) -> impl FnOnce(std::io::Error) -> Self {
		move |source| Self::Io { what, source }
	}
	/// Keep `self` as the primary cause and retain a failed cleanup beside it.
	pub fn retain(self, cleanup: Self) -> Self {
		Self::Cleanup {
			primary: Box::new(self),
			cleanup: Box::new(cleanup),
		}
	}
	/// Retain a cleanup outcome beside `self` when the cleanup failed too.
	pub fn retain_result(self, cleanup: Result<(), Self>) -> Self {
		match cleanup {
			Ok(()) => self,
			Err(cleanup) => self.retain(cleanup),
		}
	}
	/// Fold a cleanup outcome into an outcome already in hand: a cleanup failure
	/// never hides the primary one, and a clean primary adopts the cleanup's.
	pub fn fold(primary: Result<(), Self>, cleanup: Result<(), Self>) -> Result<(), Self> {
		match (primary, cleanup) {
			(Ok(()), outcome) => outcome,
			(Err(primary), Ok(())) => Err(primary),
			(Err(primary), Err(cleanup)) => Err(primary.retain(cleanup)),
		}
	}
}

impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Refused(text) => f.write_str(text),
			Self::Admission(e) => e.fmt(f),
			Self::State(e) => e.fmt(f),
			Self::Storage(e) => e.fmt(f),
			Self::GrantLoad(e) => e.fmt(f),
			Self::GrantPublication(e) => e.fmt(f),
			Self::Captp(e) => e.fmt(f),
			Self::Listener(e) => e.fmt(f),
			Self::Io { what, source } => write!(f, "{what}: {source}"),
			Self::Runtime(text) => f.write_str(text),
			Self::WorkerEnded { worker, cause } => match cause {
				Some(cause) => write!(f, "session {} ended unexpectedly: {cause}", worker.name()),
				None => write!(f, "session {} ended unexpectedly", worker.name()),
			},
			Self::Cleanup { primary, cleanup } => write!(f, "{primary}; cleanup also failed: {cleanup}"),
		}
	}
}

impl std::error::Error for Error {
	fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
		match self {
			Self::Admission(e) => Some(e),
			Self::State(e) => Some(e.as_ref()),
			Self::Storage(e) => Some(e.as_ref()),
			Self::GrantLoad(e) => Some(e.as_ref()),
			Self::GrantPublication(e) => Some(e.as_ref()),
			Self::Captp(e) => Some(e.as_ref()),
			Self::Listener(e) => Some(e.as_ref()),
			Self::Io { source, .. } => Some(source),
			Self::WorkerEnded { cause, .. } => cause.as_deref().map(|e| e as _),
			Self::Cleanup { primary, .. } => Some(primary.as_ref()),
			Self::Refused(_) | Self::Runtime(_) => None,
		}
	}
}

impl From<AdmissionError> for Error {
	fn from(e: AdmissionError) -> Self {
		Self::Admission(e)
	}
}
impl From<session_state::Error> for Error {
	fn from(e: session_state::Error) -> Self {
		Self::State(Box::new(e))
	}
}
impl From<session_state::ViewError> for Error {
	fn from(error: session_state::ViewError) -> Self {
		Self::from(session_state::Error::from(error))
	}
}
impl From<rooms_application::session::state::Error> for Error {
	fn from(e: rooms_application::session::state::Error) -> Self {
		Self::from(session_state::Error::State(e))
	}
}
impl From<StorageError> for Error {
	fn from(e: StorageError) -> Self {
		Self::Storage(Box::new(e))
	}
}
impl From<grants::LoadError> for Error {
	fn from(e: grants::LoadError) -> Self {
		Self::GrantLoad(Box::new(e))
	}
}
impl From<grant_publications::Error> for Error {
	fn from(e: grant_publications::Error) -> Self {
		Self::GrantPublication(Box::new(e))
	}
}
impl From<glowcap::Error> for Error {
	fn from(e: glowcap::Error) -> Self {
		Self::Captp(Box::new(e))
	}
}
impl From<Box<glowcap::Error>> for Error {
	fn from(e: Box<glowcap::Error>) -> Self {
		Self::Captp(e)
	}
}

impl From<rooms_runtime::session_service::error::Error> for Error {
	fn from(error: rooms_runtime::session_service::error::Error) -> Self {
		use rooms_runtime::session_service::error::Error as Shared;
		match error {
			Shared::Refused(e) => Self::Refused(e),
			Shared::Admission(e) => Self::Admission(e),
			Shared::View(e) => e.into(),
			Shared::State(e) => e.into(),
			Shared::Captp(e) => Self::Captp(e),
			Shared::Runtime(e) => Self::Runtime(e),
			Shared::WorkerEnded { worker, cause } => Self::WorkerEnded {
				worker,
				cause: cause.map(|e| Box::new(Self::from(*e))),
			},
			Shared::Cleanup { primary, cleanup } => Self::from(*primary).retain(Self::from(*cleanup)),
		}
	}
}

impl From<rooms_runtime::session_service::OpenError<StorageError>> for Error {
	fn from(error: rooms_runtime::session_service::OpenError<StorageError>) -> Self {
		use rooms_runtime::session_service::OpenError;
		match error {
			OpenError::Session(e) => e.into(),
			OpenError::Grants(e) => Self::GrantPublication(e),
			OpenError::Cleanup { primary, cleanup } => Self::from(*primary).retain(cleanup.into()),
		}
	}
}
