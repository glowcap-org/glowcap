//! One failure vocabulary for the session peer. Every tier below renders into
//! it once, and the CapTP boundary renders it into a break reason once.
use crate::{grant_publications, grants, session_commands::AdmissionError, session_state};
use rooms_application::failure::Retry;
use rooms_platform::storage::StorageError;
use std::{borrow::Cow, fmt};

impl From<rooms_platform::serving::OpenError> for Error {
	fn from(error: rooms_platform::serving::OpenError) -> Self {
		Self::Listener(Box::new(error))
	}
}

/// Why a session-peer operation did not complete.
///
/// The first seven arms are the classes a caller acts on, in the same vocabulary
/// the runtime uses, so a failure that crosses into this process keeps the
/// answer to "can asking again work?". Each carries its diagnosis as text
/// because that text is also a contract: over CapTP it is the exact break
/// reason an attached view shows, and for options it is the exact line the
/// operator reads. Foreign causes are boxed so a `Result` of this type stays
/// small on every hot return path.
#[derive(Debug)]
pub enum Error {
	Refused(Cow<'static, str>),
	/// Caller-supplied arguments, or a retained document, failed validation.
	Invalid(Cow<'static, str>),
	/// Work already admitted by an owner must finish before it can take more.
	Busy(Cow<'static, str>),
	/// Retained capacity, a budget, or a namespace is exhausted.
	Exhausted(Cow<'static, str>),
	/// The intent, generation, or context the request named has been superseded.
	Stale(Cow<'static, str>),
	Closed(Cow<'static, str>),
	/// An effect was sent but its answer was lost, so whether it applied is
	/// unknown. Only a withdrawal or a fresh observation is safe.
	Uncertain(Cow<'static, str>),
	Admission(AdmissionError),
	/// The session state machine's own verdict. This is the application's
	/// state error rather than the runtime's wrapper around it, because the
	/// wrapper can carry a runtime failure that never crosses a thread and a
	/// peer process moves its failures between them.
	State(Box<rooms_application::session::state::Error>),
	Storage(Box<dyn std::error::Error + Send + Sync>),
	GrantLoad(Box<grants::LoadError>),
	GrantPublication(Box<grant_publications::Error>),
	Captp(Box<glowcap::Error>),
	/// A remote application failure. The single-threaded runtime cannot move
	/// its shared source here, but its exact retry verdict still crosses.
	Peer {
		reason: String,
		retry: Retry,
	},
	Listener(Box<rooms_platform::serving::OpenError>),
	Io {
		what: &'static str,
		source: std::io::Error,
	},
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

#[derive(Debug)]
struct TextError(String);
impl fmt::Display for TextError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(&self.0)
	}
}
impl std::error::Error for TextError {}

pub use rooms_runtime::service::Worker;

impl Error {
	pub fn refused(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Refused(text.into())
	}
	pub fn invalid(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Invalid(text.into())
	}
	pub fn busy(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Busy(text.into())
	}
	pub fn exhausted(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Exhausted(text.into())
	}
	pub fn stale(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Stale(text.into())
	}
	pub fn closed(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Closed(text.into())
	}
	/// An effect whose answer nobody observed. The caller must read the state
	/// back rather than send it again.
	pub fn uncertain(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Uncertain(text.into())
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
			Self::Refused(text)
			| Self::Invalid(text)
			| Self::Busy(text)
			| Self::Exhausted(text)
			| Self::Stale(text)
			| Self::Closed(text)
			| Self::Uncertain(text) => f.write_str(text),
			Self::Admission(e) => e.fmt(f),
			Self::State(e) => e.fmt(f),
			Self::Storage(e) => e.fmt(f),
			Self::GrantLoad(e) => e.fmt(f),
			Self::GrantPublication(e) => e.fmt(f),
			Self::Captp(e) => e.fmt(f),
			Self::Peer { reason, .. } => f.write_str(reason),
			Self::Listener(e) => e.fmt(f),
			Self::Io { what, source } => write!(f, "{what}: {source}"),
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
			Self::Refused(_)
			| Self::Invalid(_)
			| Self::Busy(_)
			| Self::Exhausted(_)
			| Self::Stale(_)
			| Self::Closed(_)
			| Self::Uncertain(_)
			| Self::Peer { .. } => None,
		}
	}
}

impl From<AdmissionError> for Error {
	fn from(e: AdmissionError) -> Self {
		Self::Admission(e)
	}
}
/// The runtime already classes its own state wrapper, so this tier takes that
/// verdict rather than making a second one.
impl From<session_state::Error> for Error {
	fn from(error: session_state::Error) -> Self {
		Self::from(rooms_runtime::Error::session(error))
	}
}
impl From<session_state::ViewError> for Error {
	fn from(error: session_state::ViewError) -> Self {
		Self::from(rooms_runtime::Error::from(error))
	}
}
impl From<rooms_application::session::state::Error> for Error {
	fn from(e: rooms_application::session::state::Error) -> Self {
		Self::State(Box::new(e))
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

/// Lift a runtime failure into the peer's vocabulary, class for class.
///
/// The two types cannot be one. The runtime keeps its typed sources behind
/// `Rc` so a single completion can be handed to every observer of a
/// single-threaded session, while a peer process moves failures across
/// threads. What does carry across is the class, and this is the one place it
/// is preserved rather than flattened.
impl From<rooms_runtime::service::error::Error> for Error {
	fn from(error: rooms_runtime::service::error::Error) -> Self {
		use rooms_runtime::service::error::Error as Shared;
		match error {
			Shared::Refused(e) => Self::Refused(e),
			Shared::Invalid(e) => Self::Invalid(e),
			Shared::Busy(e) => Self::Busy(e),
			Shared::Exhausted(e) => Self::Exhausted(e),
			Shared::Stale(e) => Self::Stale(e),
			Shared::Closed(e) => Self::Closed(e),
			Shared::Uncertain(e) => Self::Uncertain(e),
			Shared::Admission(e) => Self::Admission(e),
			// A live borrow clears as the current turn finishes. An unloaded
			// state has no owner that can make progress, so it is closed.
			Shared::View(session_state::ViewError::Busy) => {
				Self::Busy(session_state::ViewError::Busy.to_string().into())
			}
			Shared::View(session_state::ViewError::Unloaded) => {
				Self::Closed(session_state::ViewError::Unloaded.to_string().into())
			}
			Shared::State(e) => Self::State(Box::new(e)),
			// The binding's diagnosis is refcounted for the runtime's observers
			// and not shareable across threads, so this tier takes its own copy.
			Shared::Captp(e) => Self::Captp(Box::new(e.as_ref().clone())),
			// The source is not shared across this thread boundary. Its reason
			// and retry verdict are, so a coded peer refusal does not become the
			// local policy class merely because it crossed processes.
			Shared::Peer(e) => Self::Peer {
				retry: e.retry(),
				reason: e.to_string(),
			},
			Shared::Storage(e) => Self::Storage(Box::new(TextError(e.to_string()))),
			Shared::WorkerEnded { worker, cause } => Self::WorkerEnded {
				worker,
				cause: cause.map(|e| Box::new(Self::from(*e))),
			},
			Shared::Cleanup { primary, cleanup } => Self::from(*primary).retain(Self::from(*cleanup)),
		}
	}
}

#[cfg(test)]
mod tests {
	use super::Error;
	use rooms_application::failure::Retry;
	use rooms_runtime::Error as Shared;

	/// Every class the runtime can report has to arrive here as the same
	/// class. A hop that flattens one costs the caller the only fact it acts
	/// on, and nothing else in this crate would notice.
	#[test]
	fn every_runtime_class_survives_the_hop_into_the_peer() {
		assert!(matches!(Error::from(Shared::refused("no")), Error::Refused(_)));
		assert!(matches!(Error::from(Shared::invalid("shape")), Error::Invalid(_)));
		assert!(matches!(Error::from(Shared::busy("working")), Error::Busy(_)));
		assert!(matches!(Error::from(Shared::exhausted("full")), Error::Exhausted(_)));
		assert!(matches!(Error::from(Shared::stale("moved")), Error::Stale(_)));
		assert!(matches!(Error::from(Shared::closed("gone")), Error::Closed(_)));
		assert!(matches!(Error::from(Shared::uncertain("lost")), Error::Uncertain(_)));
		assert!(matches!(
			Error::from(Shared::storage_message("disk")),
			Error::Storage(_)
		));
	}

	/// A primary failure keeps its place, and the cleanup retained behind it
	/// keeps its own class rather than becoming part of a sentence.
	#[test]
	fn a_retained_cleanup_crosses_with_both_classes_intact() {
		let folded = Shared::invalid("bad request").retain(Shared::storage_message("flush failed"));
		let Error::Cleanup { primary, cleanup } = Error::from(folded) else {
			panic!("the peer must keep both failures")
		};
		assert!(matches!(*primary, Error::Invalid(_)));
		assert!(matches!(*cleanup, Error::Storage(_)));
	}

	/// The state view's two failures both clear on their own, and converting
	/// one must not route back through the conversion that produced it.
	#[test]
	fn a_borrowed_state_view_converts_once_and_terminates() {
		let busy = Error::from(crate::session_state::ViewError::Busy);
		assert!(matches!(busy, Error::Busy(_)));
		assert_eq!(busy.to_string(), "session state is already borrowed");
	}

	#[test]
	fn a_peer_retry_verdict_survives_the_thread_boundary() {
		let peer = Shared::peer(rooms_glowcap::client::Error::Timeout("late"));
		assert!(matches!(
			Error::from(peer),
			Error::Peer {
				retry: Retry::AfterStateChange,
				..
			}
		));
	}
}
