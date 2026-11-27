//! Typed failures shared by runtime owners and rendered only at a product edge.
//!
//! Every arm is a class a caller can act on without reading prose: the text a
//! class carries is for the person who finally sees it, never for a `match`.
//! The class also fixes when a retry can help, which the `retry` module answers.
use std::{borrow::Cow, fmt, rc::Rc};

mod retry;

/// One failure, classed. `Clone` because a completion is retained for every
/// concurrent observer of the owner that failed, so the typed sources sit
/// behind `Rc` rather than being flattened to text for the second reader.
#[derive(Clone, Debug)]
pub enum Error {
	/// A local admission owner rejected this attempt before dispatch.
	Admission {
		refusal: rooms_application::admission::Refusal,
		owner: Option<rooms_application::admission::Owner>,
	},
	Context {
		operation: Cow<'static, str>,
		source: Box<Self>,
	},
	/// A local owner reached a failure the catalog names. The code is the
	/// fact, and the detail says what this owner saw.
	Coded {
		code: rooms_application::failure::FailureCode,
		detail: &'static str,
	},
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
	/// The local CapTP binding failed: a session closed, a reference died, a
	/// deferred turn could not be taken.
	Captp(Rc<glowcap::Error>),
	/// A Rooms peer refused the call, missed its deadline, or was lost.
	Peer(Rc<rooms_glowcap::client::Error>),
	/// A platform-independent storage owner failed. The adapter's concrete
	/// error remains available as the source without coupling runtime to it.
	Storage(Rc<dyn std::error::Error>),
	/// A platform operation or task failed outside protocol and storage owners.
	Platform(Rc<dyn std::error::Error>),
	Cleanup {
		primary: Box<Self>,
		cleanup: Box<Self>,
	},
}

impl Error {
	pub fn with_context(self, operation: impl Into<Cow<'static, str>>) -> Self {
		Self::Context {
			operation: operation.into(),
			source: Box::new(self),
		}
	}
	pub fn admission(
		refusal: rooms_application::admission::Refusal,
		owner: Option<rooms_application::admission::Owner>,
	) -> Self {
		Self::Admission { refusal, owner }
	}
	pub fn coded(code: rooms_application::failure::FailureCode, detail: &'static str) -> Self {
		Self::Coded { code, detail }
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
	/// The one place a classed failure becomes CapTP refusal text: the edge
	/// where a hosted behavior answers its caller. Nothing inside the runtime
	/// reads the text back.
	///
	/// A failure the catalog names is written as its line alone, so the
	/// partner reads the code first whatever context or cleanup surrounds it
	/// here. Any other failure is written whole.
	///
	/// The result is bounded here rather than at each break, because a refusal
	/// crosses a broken promise to a partner and a retained cleanup chain has
	/// no length of its own. Bounding it once means no caller has to remember.
	pub fn into_refusal(self) -> String {
		let mut text = self.failure_line().unwrap_or_else(|| self.to_string());
		text.truncate(rooms_application::failure::reason_prefix(&text).len());
		text
	}
	fn failure_line(&self) -> Option<String> {
		match self {
			Self::Admission { .. } | Self::Coded { .. } => Some(self.to_string()),
			Self::Context { source, .. } => source.failure_line(),
			Self::Cleanup { primary, .. } => primary.failure_line(),
			Self::Captp(error) => rooms_glowcap::client::binding_failure(error).map(|failure| failure.to_string()),
			Self::Peer(error) => error.failure().map(|failure| failure.to_string()),
			_ => None,
		}
	}
	pub fn storage(error: impl std::error::Error + 'static) -> Self {
		Self::Storage(Rc::new(error))
	}
	pub fn platform(error: impl std::error::Error + 'static) -> Self {
		Self::Platform(Rc::new(error))
	}
	pub fn platform_message(text: impl Into<String>) -> Self {
		Self::platform(TextError(text.into()))
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
			rooms_glowcap::client::Error::Binding(error)
				if error.kind() != glowcap::ErrorKind::Broken
					|| error.cause().origin != glowcap::BreakOrigin::Partner =>
			{
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
	/// Operator responses bound both shape and retained inventory size.
	pub fn operator(error: rooms_application::server::operations::operator::view::Refusal) -> Self {
		match error {
			rooms_application::server::operations::operator::view::Refusal::Budget => {
				Self::exhausted(error.to_string())
			}
			_ => Self::invalid_by(error),
		}
	}
	pub fn retain(self, cleanup: Self) -> Self {
		Self::Cleanup {
			primary: Box::new(self),
			cleanup: Box::new(cleanup),
		}
	}
	/// Separate the failed operation from the outcome of retiring its resources.
	/// Nested owners may each have retained a cleanup error on the way out.
	pub fn split_cleanup(self) -> (Self, Result<(), Self>) {
		match self {
			Self::Cleanup { primary, cleanup } => {
				let (failure, prior) = primary.split_cleanup();
				(failure, crate::cleanup::combine(prior, Err(*cleanup)))
			}
			Self::Context { operation, source } => {
				let (failure, closed) = source.split_cleanup();
				(
					failure.with_context(operation.clone()),
					closed.map_err(|error| error.with_context(operation)),
				)
			}
			failure => (failure, Ok(())),
		}
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
			Self::Admission { refusal, owner } => f.write_str(&refusal.line(*owner)),
			Self::Context { operation, source } => write!(f, "{operation}: {source}"),
			Self::Coded { code, detail } => f.write_str(&code.line(detail)),
			Self::Refused(error)
			| Self::Invalid(error)
			| Self::Busy(error)
			| Self::Exhausted(error)
			| Self::Stale(error)
			| Self::Closed(error)
			| Self::Uncertain(error) => f.write_str(error),
			Self::Captp(error) => error.fmt(f),
			Self::Peer(error) => error.fmt(f),
			Self::Storage(error) | Self::Platform(error) => error.fmt(f),
			Self::Cleanup { primary, cleanup } => write!(f, "{primary}; cleanup also failed: {cleanup}"),
		}
	}
}

impl std::error::Error for Error {
	fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
		match self {
			Self::Admission { .. } | Self::Coded { .. } => None,
			Self::Context { source, .. } => Some(source.as_ref()),
			Self::Captp(error) => Some(error.as_ref()),
			Self::Peer(error) => Some(error.as_ref()),
			Self::Storage(error) | Self::Platform(error) => Some(error.as_ref()),
			Self::Cleanup { primary, .. } => Some(primary.as_ref()),
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

	#[test]
	fn cleanup_retains_both_typed_failures() {
		let error = Error::closed("owner stopped").retain(Error::storage_message("flush failed"));
		let Error::Cleanup { primary, cleanup } = error else {
			panic!("cleanup must retain both failures")
		};
		assert!(matches!(*primary, Error::Closed(_)));
		assert!(matches!(*cleanup, Error::Storage(_)));
	}

	#[test]
	fn close_observes_only_retained_cleanup_failures() {
		let (refused, closed) = Error::busy("workspace occupied").split_cleanup();
		assert!(matches!(refused, Error::Busy(_)));
		assert!(closed.is_ok());

		let (refused, closed) = refused
			.retain(Error::closed("store close failed"))
			.with_context("opening the store")
			.retain(Error::closed("host close failed"))
			.split_cleanup();
		assert_eq!(refused.to_string(), "opening the store: workspace occupied");
		assert_eq!(
			closed.unwrap_err().to_string(),
			"opening the store: store close failed; cleanup also failed: host close failed"
		);
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

	/// The partner branches on the code at the head of the line, so context
	/// and a failed cleanup around a named failure do not come before it.
	#[test]
	fn a_refusal_the_catalog_names_leads_with_its_code() {
		use rooms_application::{
			admission,
			failure::{Failure, FailureCode},
		};
		let busy = Error::admission(admission::Refusal::Capacity, None)
			.with_context("posting")
			.retain(Error::storage_message("flush failed"));
		let line = busy.into_refusal();
		let failure = Failure::parse(&line).expect("a coded line");
		assert_eq!(failure.code, FailureCode::AdmissionBusy);
		assert!(failure.refused_before_dispatch());
		let relayed = Error::peer(rooms_glowcap::client::Error::RefusedObservation(
			"nick-taken: Ann".into(),
		))
		.with_context("registering");
		assert_eq!(relayed.into_refusal(), "nick-taken: Ann");
		assert_eq!(
			Error::closed("owner stopped").with_context("posting").into_refusal(),
			"posting: owner stopped"
		);
	}

	#[test]
	fn a_retained_completion_keeps_its_class_for_every_observer() {
		let first = Error::storage_message("disk stopped");
		let second = first.clone();
		assert!(matches!(second, Error::Storage(_)));
		assert_eq!(first.to_string(), second.to_string());
	}
}
