//! Typed failures shared by runtime owners and rendered only at a product edge.
//!
//! Every arm is a class a caller can act on without reading prose: the text a
//! class carries is for the person who finally sees it, never for a `match`.
//! The class also fixes when a retry can help, through the same [`Retry`]
//! vocabulary the wire's failure codes use, so an owner that only knows the
//! class still answers "try again, or not?" correctly.
use rooms_application::{failure::Retry, session::state};
use std::{borrow::Cow, fmt, rc::Rc};

/// A task owned by the shared session composition.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Worker {
	Storage,
	Grants,
	Directories,
	Rooms,
	Archive,
	DirectDispatch,
	DirectCommands,
	HandedRooms,
	RoomOffers,
	OfferOutcomes,
	DirectOutcomes,
	RoomEvents,
	DirectEvents,
	Changes(&'static str),
	Reconciliation,
}

impl Worker {
	pub fn name(self) -> &'static str {
		match self {
			Self::Storage => "storage worker",
			Self::Grants => "grant worker",
			Self::Directories => "directory worker",
			Self::Rooms => "room worker",
			Self::Archive => "archive worker",
			Self::DirectDispatch => "direct dispatcher",
			Self::DirectCommands => "direct command worker",
			Self::HandedRooms => "handed-room worker",
			Self::RoomOffers => "room-offer worker",
			Self::OfferOutcomes => "room-offer outcome drain",
			Self::DirectOutcomes => "direct dispatch outcome drain",
			Self::RoomEvents => "room event pump",
			Self::DirectEvents => "direct event pump",
			Self::Changes(owner) => owner,
			Self::Reconciliation => "operations reconciler",
		}
	}
}

/// One failure, classed. `Clone` because a completion is retained for every
/// concurrent observer of the owner that failed, so the typed sources sit
/// behind `Rc` rather than being flattened to text for the second reader.
#[derive(Clone, Debug)]
pub enum Error {
	/// The request was understood but policy does not permit it.
	Refused(Cow<'static, str>),
	/// Caller-supplied arguments, or a retained document, failed validation.
	/// The same request will fail the same way. Only a different one can pass.
	Invalid(Cow<'static, str>),
	/// Work already admitted by the owner must finish before it can take more.
	/// The owner makes that progress itself, so the same request can retry soon.
	Busy(Cow<'static, str>),
	/// Retained capacity, a budget, or a namespace is exhausted. The same
	/// request needs the owning state to change before it can pass.
	Exhausted(Cow<'static, str>),
	/// The intent, generation, or context the request named has been
	/// superseded. Re-read the current state before asking again.
	Stale(Cow<'static, str>),
	/// A runtime owner or operation is no longer available.
	Closed(Cow<'static, str>),
	/// An effect was sent but its answer was lost, so whether it applied is
	/// unknown. Only a withdrawal or a fresh observation is safe.
	Uncertain(Cow<'static, str>),
	State(state::Error),
	/// The local CapTP binding failed: a session closed, a reference died, a
	/// deferred turn could not be taken.
	Captp(Rc<glowcap::Error>),
	/// A Rooms peer refused the call, missed its deadline, or was lost.
	Peer(Rc<rooms_glowcap::client::Error>),
	WorkerEnded {
		worker: Worker,
		cause: Option<Box<Self>>,
	},
	/// A platform-independent storage owner failed. The adapter's concrete
	/// error remains available as the source without coupling runtime to it.
	Storage(Rc<dyn std::error::Error>),
	Cleanup {
		primary: Box<Self>,
		cleanup: Box<Self>,
	},
}

impl Error {
	pub fn fold(primary: Result<(), Self>, cleanup: Result<(), Self>) -> Result<(), Self> {
		match (primary, cleanup) {
			(Ok(()), result) => result,
			(Err(error), result) => Err(error.retain_result(result)),
		}
	}
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
	pub fn uncertain(text: impl Into<Cow<'static, str>>) -> Self {
		Self::Uncertain(text.into())
	}
	/// A typed validation failure from below, classed here because the caller
	/// (not the validator) knows the input came from a request.
	pub fn invalid_by(error: impl fmt::Display) -> Self {
		Self::Invalid(error.to_string().into())
	}
	/// A typed capacity refusal from below: the bound is the owner's, the
	/// text is the bound's own.
	pub fn exhausted_by(error: impl fmt::Display) -> Self {
		Self::Exhausted(error.to_string().into())
	}
	/// A typed report from below that the state the request named has moved.
	pub fn stale_by(error: impl fmt::Display) -> Self {
		Self::Stale(error.to_string().into())
	}
	/// A typed report from below that an owner is gone.
	pub fn closed_by(error: impl fmt::Display) -> Self {
		Self::Closed(error.to_string().into())
	}
	/// The one place a classed failure becomes CapTP refusal text: the edge
	/// where a hosted behavior answers its caller. Nothing inside the runtime
	/// reads the text back.
	///
	/// The result is bounded here rather than at each break, because a refusal
	/// crosses a broken promise to a partner and a retained cleanup chain has
	/// no length of its own. Bounding it once means no caller has to remember.
	pub fn into_refusal(self) -> String {
		let mut text = self.to_string();
		text.truncate(rooms_application::failure::reason_prefix(&text).len());
		text
	}
	pub fn storage(error: impl std::error::Error + 'static) -> Self {
		Self::Storage(Rc::new(error))
	}
	pub fn storage_message(text: impl Into<String>) -> Self {
		Self::storage(TextError(text.into()))
	}
	/// A Rooms client failure, split by whose fault the caller must act on. The
	/// binding arm is this process's own CapTP owner giving way, so it belongs
	/// beside every other local binding failure rather than being reported as
	/// something the partner did.
	pub fn peer(error: rooms_glowcap::client::Error) -> Self {
		match error {
			rooms_glowcap::client::Error::Binding(error) if error.kind() != glowcap::ErrorKind::Broken => {
				Self::Captp(Rc::from(error))
			}
			error => Self::Peer(Rc::new(error)),
		}
	}
	/// The durable grant ledger's own refusal, classed by what it says about
	/// the ledger rather than by its sentence. A document that will not parse
	/// needs a different document, a ceiling reached needs room, an id that
	/// names nothing needs the caller to read the ledger again, and a storage
	/// outcome nobody observed stays uncertain until recovery reads it back.
	pub fn ledger(error: rooms_application::grants::Error) -> Self {
		use rooms_application::grants::Error as Ledger;
		let text = error.to_string();
		match error {
			Ledger::MalformedDocument
			| Ledger::UnsupportedVersion
			| Ledger::InvalidGrant
			| Ledger::DuplicateId
			| Ledger::Conflict => Self::Invalid(text.into()),
			Ledger::DocumentTooLarge | Ledger::ActiveLimit | Ledger::LifetimeLimit => Self::Exhausted(text.into()),
			Ledger::Busy => Self::Busy(text.into()),
			Ledger::Revoked => Self::Refused(text.into()),
			Ledger::Missing | Ledger::WrongOwner => Self::Stale(text.into()),
			Ledger::RecoveryRequired => Self::Uncertain(text.into()),
		}
	}
	/// An archive's own refusal, classed by what the caller can do about it.
	/// A full archive can take the same record once it has room. A widening
	/// that policy will not grant never can. Everything else names a request
	/// or a document that has to change.
	pub fn archive(error: rooms_application::archive::Error) -> Self {
		use rooms_application::archive::Error as Archive;
		let text = error.to_string();
		match error {
			Archive::Capacity => Self::Exhausted(text.into()),
			Archive::Access => Self::Refused(text.into()),
			Archive::Record
			| Archive::Filter
			| Archive::Revision
			| Archive::Page
			| Archive::Method
			| Archive::Document
			| Archive::Blob => Self::Invalid(text.into()),
		}
	}
	/// A grant view the runtime built but could not answer with. Only the
	/// policy arm carries the ledger's own verdict. The rest are this
	/// projection's shape.
	pub fn grant_view(error: rooms_application::grants::protocol::Refusal) -> Self {
		use rooms_application::grants::protocol::Refusal;
		match error {
			Refusal::Policy(error) => Self::ledger(error),
			Refusal::Access => Self::Refused(error.to_string().into()),
			Refusal::Arguments | Refusal::Capability | Refusal::View => Self::Invalid(error.to_string().into()),
		}
	}
	/// A session snapshot the runtime could not project. One that outgrew its
	/// budget can be answered once the session holds less. The rest say the
	/// gathered state itself is wrong.
	pub fn snapshot(error: rooms_application::session::snapshot::Refusal) -> Self {
		use rooms_application::session::snapshot::Refusal;
		let text = error.to_string();
		match error {
			Refusal::Budget => Self::Exhausted(text.into()),
			Refusal::Shape | Refusal::Text | Refusal::Json | Refusal::Relation | Refusal::Checkpoint => {
				Self::Invalid(text.into())
			}
		}
	}
	/// The command envelope separates held-facet policy from request shape.
	/// Preserve that distinction instead of turning every parser verdict into
	/// a policy refusal at the service edge.
	pub fn command(error: rooms_application::session::command::Refusal) -> Self {
		use rooms_application::session::command::Refusal;
		let text = error.to_string();
		match error {
			Refusal::Access | Refusal::Administration => Self::Refused(text.into()),
			Refusal::Arguments
			| Refusal::OperationId
			| Refusal::Count
			| Refusal::MaterialSize
			| Refusal::ArgumentSize
			| Refusal::Unknown => Self::Invalid(text.into()),
		}
	}
	/// When asking again can succeed, in the wire taxonomy's own words. A
	/// class answers this without its text, which is the point of having one.
	pub fn retry(&self) -> Retry {
		match self {
			Self::Refused(_) => Retry::Never,
			Self::State(error) => state_retry(error),
			Self::Invalid(_) => Retry::AfterRequestChange,
			Self::Busy(_) => Retry::Soon,
			Self::Exhausted(_) => Retry::AfterStateChange,
			Self::Stale(_) | Self::Closed(_) | Self::Uncertain(_) | Self::WorkerEnded { .. } => Retry::AfterStateChange,
			Self::Captp(error) => rooms_glowcap::client::binding_retry(error),
			Self::Storage(_) => Retry::AfterStateChange,
			Self::Peer(error) => error.retry(),
			Self::Cleanup { primary, .. } => primary.retry(),
		}
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
			Err(error) => self.retain(error),
		}
	}
}

/// When asking again can help after the session state machine refused.
///
/// Spelled out rather than folded into one answer, because these arms differ
/// in exactly the way a caller acts on: a borrowed state clears by itself, a
/// full ledger clears when something drains, and an operation id that was
/// already used never becomes free again.
fn state_retry(error: &state::Error) -> Retry {
	use state::Error as State;
	match error {
		// Nobody has to do anything; the borrow or the in-flight result ends.
		State::Busy | State::ResultInFlight | State::Full => Retry::Soon,
		// A monotonic revision or identifier space cannot drain by waiting.
		State::Exhausted => Retry::AfterStateChange,
		// The durable state has to be read again before this can be judged.
		State::RecoveryRequired
		| State::ResultNeedsRecovery
		| State::Unresolved
		| State::Abandoned
		| State::Revision
		| State::ResultChanged
		| State::AdoptionClosed => Retry::AfterStateChange,
		// The request names something this session will not accept under that
		// name again, whatever the state does.
		State::Reused | State::WrongOwner | State::OtherLedger => Retry::AfterRequestChange,
		// Either a different name or a state that has it would do.
		State::Missing => Retry::AfterRequestOrStateChange,
		// The command itself does not validate.
		State::Command(_) | State::Document | State::Checkpoint | State::Relation => Retry::AfterRequestChange,
	}
}

#[derive(Debug)]
struct TextError(String);
impl fmt::Display for TextError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(&self.0)
	}
}
impl std::error::Error for TextError {}

impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Refused(error)
			| Self::Invalid(error)
			| Self::Busy(error)
			| Self::Exhausted(error)
			| Self::Stale(error)
			| Self::Closed(error)
			| Self::Uncertain(error) => f.write_str(error),
			Self::State(error) => error.fmt(f),
			Self::Captp(error) => error.fmt(f),
			Self::Peer(error) => error.fmt(f),
			Self::Storage(error) => error.fmt(f),
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
			Self::State(error) => Some(error),
			Self::Captp(error) => Some(error.as_ref()),
			Self::Peer(error) => Some(error.as_ref()),
			Self::Storage(error) => Some(error.as_ref()),
			Self::Cleanup { primary, .. } => Some(primary.as_ref()),
			Self::WorkerEnded { cause, .. } => cause.as_deref().map(|error| error as _),
			Self::Refused(_)
			| Self::Invalid(_)
			| Self::Busy(_)
			| Self::Exhausted(_)
			| Self::Stale(_)
			| Self::Closed(_)
			| Self::Uncertain(_) => None,
		}
	}
}

impl From<state::Error> for Error {
	fn from(error: state::Error) -> Self {
		Self::State(error)
	}
}
impl From<glowcap::Error> for Error {
	fn from(error: glowcap::Error) -> Self {
		Self::Captp(Rc::new(error))
	}
}
impl From<Box<glowcap::Error>> for Error {
	fn from(error: Box<glowcap::Error>) -> Self {
		Self::Captp(Rc::from(error))
	}
}
impl From<rooms_glowcap::client::Error> for Error {
	fn from(error: rooms_glowcap::client::Error) -> Self {
		Self::peer(error)
	}
}

#[cfg(test)]
mod tests {
	use super::Error;
	use rooms_application::failure::Retry;

	#[test]
	fn failure_classes_survive_without_reading_their_text() {
		assert!(matches!(Error::refused("not allowed"), Error::Refused(_)));
		assert!(matches!(Error::invalid("wrong shape"), Error::Invalid(_)));
		assert!(matches!(Error::busy("already working"), Error::Busy(_)));
		assert!(matches!(Error::exhausted("namespace is full"), Error::Exhausted(_)));
		assert!(matches!(Error::stale("intent changed"), Error::Stale(_)));
		assert!(matches!(Error::closed("gone"), Error::Closed(_)));
		assert!(matches!(Error::uncertain("answer lost"), Error::Uncertain(_)));
		let storage = Error::storage_message("disk stopped");
		assert!(matches!(storage, Error::Storage(_)));
	}

	#[test]
	fn each_class_names_when_a_retry_can_help() {
		assert_eq!(Error::refused("no").retry(), Retry::Never);
		assert_eq!(Error::invalid("bad").retry(), Retry::AfterRequestChange);
		assert_eq!(Error::busy("working").retry(), Retry::Soon);
		assert_eq!(Error::exhausted("full").retry(), Retry::AfterStateChange);
		assert_eq!(Error::stale("moved").retry(), Retry::AfterStateChange);
		assert_eq!(Error::closed("gone").retry(), Retry::AfterStateChange);
		assert_eq!(Error::uncertain("lost").retry(), Retry::AfterStateChange);
		let cleanup = Error::invalid("bad").retain(Error::closed("gone"));
		assert_eq!(
			cleanup.retry(),
			Retry::AfterRequestChange,
			"the primary failure decides"
		);
	}

	#[test]
	fn command_policy_and_request_shape_keep_different_classes() {
		use rooms_application::session::command::Refusal;
		assert!(matches!(Error::command(Refusal::Access), Error::Refused(_)));
		assert!(matches!(Error::command(Refusal::Administration), Error::Refused(_)));
		assert!(matches!(Error::command(Refusal::Arguments), Error::Invalid(_)));
		assert!(matches!(Error::command(Refusal::Unknown), Error::Invalid(_)));
	}

	#[test]
	fn grant_mutation_busy_is_not_a_durable_ledger_ceiling() {
		use rooms_application::grants::Error as Grant;
		assert!(matches!(Error::ledger(Grant::Busy), Error::Busy(_)));
		assert!(matches!(Error::ledger(Grant::ActiveLimit), Error::Exhausted(_)));
		assert!(matches!(Error::ledger(Grant::LifetimeLimit), Error::Exhausted(_)));
	}

	/// The state machine's arms do not share one answer. Folding them into a
	/// single verdict told a caller that a momentarily borrowed state would
	/// never work again.
	#[test]
	fn a_busy_state_is_worth_asking_again_and_a_reused_id_never_is() {
		use rooms_application::session::state::Error as State;
		assert_eq!(Error::State(State::Busy).retry(), Retry::Soon);
		assert_eq!(Error::State(State::Full).retry(), Retry::Soon);
		assert_eq!(Error::State(State::Exhausted).retry(), Retry::AfterStateChange);
		assert_eq!(Error::State(State::RecoveryRequired).retry(), Retry::AfterStateChange);
		assert_eq!(Error::State(State::Reused).retry(), Retry::AfterRequestChange);
		assert_eq!(Error::State(State::Missing).retry(), Retry::AfterRequestOrStateChange);
	}

	#[test]
	fn cleanup_retains_both_typed_failures() {
		let error = Error::closed("owner stopped").retain(Error::storage_message("flush failed"));
		let Error::Cleanup { primary, cleanup } = error else {
			panic!("cleanup must retain both failures")
		};
		assert!(matches!(*primary, Error::Closed(_)));
		assert!(matches!(*cleanup, Error::Storage(_)));
	}

	/// A refusal crosses a broken promise to a partner, and a retained chain
	/// of causes has no length of its own, so the one text boundary bounds it.
	#[test]
	fn a_refusal_is_bounded_however_deep_its_causes_run() {
		use rooms_application::failure::MAX_REASON_BYTES;
		let mut error = Error::storage_message("x".repeat(MAX_REASON_BYTES));
		for _ in 0..4 {
			error = error.retain(Error::storage_message("y".repeat(MAX_REASON_BYTES)));
		}
		let refusal = error.into_refusal();
		assert!(refusal.len() <= MAX_REASON_BYTES, "{} bytes", refusal.len());
		assert!(refusal.starts_with("xxx"), "the primary cause still leads");
	}

	#[test]
	fn a_retained_completion_keeps_its_class_for_every_observer() {
		let first = Error::storage_message("disk stopped");
		let second = first.clone();
		assert!(matches!(second, Error::Storage(_)));
		assert_eq!(first.to_string(), second.to_string());
	}
}
