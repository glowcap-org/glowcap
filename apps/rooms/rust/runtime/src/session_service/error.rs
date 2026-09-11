//! Platform-independent failures of session capability dispatch.
use crate::{session_commands::AdmissionError, session_state::ViewError};
use rooms_application::session::state;
use std::{borrow::Cow, fmt};
#[derive(Debug)]
pub enum Error {
	Refused(Cow<'static, str>),
	Admission(AdmissionError),
	View(ViewError),
	State(state::Error),
	Captp(Box<glowcap::Error>),
	WorkerEnded {
		worker: super::Worker,
		cause: Option<Box<Self>>,
	},
	Runtime(String),
	Cleanup {
		primary: Box<Self>,
		cleanup: Box<Self>,
	},
}
impl Error {
	pub fn fold(primary: Result<(), Self>, cleanup: Result<(), Self>) -> Result<(), Self> {
		match (primary, cleanup) {
			(Ok(()), result) => result,
			(Err(e), result) => Err(e.retain_result(result)),
		}
	}
	pub fn refused(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Refused(text.into())
	}
	pub fn runtime(text: impl Into<String>) -> Self {
		Self::Runtime(text.into())
	}
	pub fn retain(self, cleanup: Self) -> Self {
		Self::Cleanup {
			primary: Box::new(self),
			cleanup: Box::new(cleanup),
		}
	}
	pub fn retain_result(self, cleanup: Result<(), Self>) -> Self {
		match cleanup {
			Ok(()) => self,
			Err(e) => self.retain(e),
		}
	}
}
impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Refused(e) => f.write_str(e),
			Self::Admission(e) => e.fmt(f),
			Self::View(e) => e.fmt(f),
			Self::State(e) => e.fmt(f),
			Self::Captp(e) => e.fmt(f),
			Self::Runtime(e) => f.write_str(e),
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
			Self::View(e) => Some(e),
			Self::State(e) => Some(e),
			Self::Captp(e) => Some(e.as_ref()),
			Self::Cleanup { primary, .. } => Some(primary.as_ref()),
			Self::WorkerEnded { cause, .. } => cause.as_deref().map(|e| e as _),
			Self::Refused(_) | Self::Runtime(_) => None,
		}
	}
}
impl From<AdmissionError> for Error {
	fn from(e: AdmissionError) -> Self {
		Self::Admission(e)
	}
}
impl From<ViewError> for Error {
	fn from(e: ViewError) -> Self {
		Self::View(e)
	}
}
impl From<state::Error> for Error {
	fn from(e: state::Error) -> Self {
		Self::State(e)
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
