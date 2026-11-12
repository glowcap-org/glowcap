//! Typed failures shared by runtime owners and rendered only at a product edge.
//!
//! Every arm is a class a caller can act on without reading prose: the text a
//! class carries is for the person who finally sees it, never for a `match`.
//! The class also fixes when a retry can help, through the same [`Retry`]
//! vocabulary the wire's failure codes use, so an owner that only knows the
//! class still answers "try again, or not?" correctly.
use rooms_application::failure::Retry;
use std::{borrow::Cow, fmt, rc::Rc};

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
	/// Only an admission owner or a validated peer verdict authorizes cooldown.
	pub fn admission_retry(&self) -> Option<rooms_application::admission::RetryAdvice> {
		match self {
			Self::Admission { refusal, owner } => refusal.retry_advice(*owner),
			Self::Captp(error) => {
				rooms_glowcap::client::binding_admission_refusal(error).and_then(|failure| failure.retry_advice())
			}
			Self::Peer(error) => error.admission_refusal().and_then(|failure| failure.retry_advice()),
			Self::Cleanup { primary, .. } => primary.admission_retry(),
			Self::Context { source, .. } => source.admission_retry(),
			_ => None,
		}
	}
	/// The retry condition of a failure that stands until something changes,
	/// or none when the recovery timer owns the next attempt. A catalog code
	/// names the change it waits for, and one that asks for a retry soon
	/// waits for nothing. Without a code, a failure stands only when `retry`
	/// says no later attempt of the same request can succeed. A receipt is
	/// the exception: its `Never` forbids replaying that one effect, and the
	/// worker's next attempt is a new request.
	pub fn standing_retry(&self) -> Option<Retry> {
		match self {
			Self::Admission { refusal, .. } => awaited_change(refusal.code()),
			Self::Coded { code, .. } => awaited_change(*code),
			Self::Captp(error) => binding_standing_retry(error),
			Self::Peer(error) => match error.as_ref() {
				rooms_glowcap::client::Error::Binding(error) | rooms_glowcap::client::Error::Unsent(error) => {
					binding_standing_retry(error)
				}
				// A lost observation forbids replaying that one effect. The
				// worker's next attempt is a new request.
				rooms_glowcap::client::Error::Observation(_) => None,
				// A refused receipt keeps its line and drops the cause. A
				// reach code is a failure the timer reattempts, and a line
				// with no code names no change to wait for.
				refused @ rooms_glowcap::client::Error::RefusedObservation(_) => refused
					.failure_code()
					.filter(|code| !rooms_glowcap::client::reach_code(*code))
					.and_then(awaited_change),
				other => match other.failure_code() {
					Some(code) => awaited_change(code),
					None => request_bound(other.retry()),
				},
			},
			Self::Cleanup { primary, .. } => primary.standing_retry(),
			Self::Context { source, .. } => source.standing_retry(),
			_ => request_bound(self.retry()),
		}
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
	/// When asking again can succeed, in the wire taxonomy's own words. A
	/// class answers this without its text, which is the point of having one.
	pub fn retry(&self) -> Retry {
		match self {
			Self::Admission { refusal, .. } => refusal.code().definition().retry,
			Self::Context { source, .. } => source.retry(),
			Self::Coded { code, .. } => code.definition().retry,
			Self::Refused(_) => Retry::Never,
			Self::Invalid(_) => Retry::AfterRequestChange,
			Self::Busy(_) => Retry::Soon,
			Self::Exhausted(_) => Retry::AfterStateChange,
			Self::Stale(_) | Self::Closed(_) | Self::Uncertain(_) => Retry::AfterStateChange,
			Self::Captp(error) => rooms_glowcap::client::binding_retry(error),
			Self::Storage(_) | Self::Platform(_) => Retry::AfterStateChange,
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

/// The change a catalog code waits for, or none when it asks for a retry
/// soon: the recovery timer makes that attempt.
fn awaited_change(code: rooms_application::failure::FailureCode) -> Option<Retry> {
	let retry = code.definition().retry;
	(retry != Retry::Soon).then_some(retry)
}
/// The retry condition when only a different request can succeed, so no
/// timer helps.
fn request_bound(retry: Retry) -> Option<Retry> {
	matches!(retry, Retry::Never | Retry::AfterRequestChange).then_some(retry)
}

/// A binding failure stands by its catalog code's retry condition, unless its
/// cause clears with time. The code still names that failure to a person.
fn binding_standing_retry(error: &glowcap::Error) -> Option<Retry> {
	if rooms_glowcap::client::clears_with_time(error.cause()) {
		return None;
	}
	match rooms_glowcap::client::binding_failure(error) {
		Some(failure) => awaited_change(failure.code),
		None => request_bound(rooms_glowcap::client::binding_retry(error)),
	}
}

#[cfg(test)]
mod tests {
	use super::Error;
	use rooms_application::failure::{FailureCode, Retry};

	#[test]
	fn admission_evidence_survives_context_and_cleanup_but_diagnostics_cannot_create_it() {
		use rooms_application::admission::{Class, Refusal};
		let refusal = Refusal::Throttled {
			class: Class::Join,
			retry_ms: 100,
		};
		let reason = refusal.reason();
		let local = Error::admission(refusal, None);
		let advice = local.admission_retry().unwrap();
		let contextual = local
			.clone()
			.with_context("registering membership")
			.retain(Error::closed("cleanup ended"));
		assert_eq!(contextual.admission_retry(), Some(advice));
		let observed = Error::from(rooms_glowcap::client::Error::RefusedObservation(reason.clone()));
		assert_eq!(observed.admission_retry(), Some(advice));
		for unclassified in [
			Error::from(glowcap::loam::refusal(&reason)),
			Error::from(rooms_glowcap::client::Error::Observation(reason.clone())),
			Error::platform_message(reason),
		] {
			assert!(unclassified.admission_retry().is_none());
			assert!(unclassified.standing_retry().is_none());
			assert!(
				unclassified.retain(local.clone()).admission_retry().is_none(),
				"a cleanup refusal cannot authorize retry of the primary operation"
			);
		}
	}

	#[test]
	fn a_failure_stands_by_its_code_or_when_only_a_new_request_helps() {
		use rooms_application::admission::{Class, Refusal};
		let oversized = Error::admission(Refusal::TooLarge { class: Class::Join }, None);
		assert_eq!(oversized.standing_retry(), Some(Retry::AfterRequestChange));
		let throttled = Error::admission(
			Refusal::Throttled {
				class: Class::Join,
				retry_ms: 5,
			},
			None,
		);
		assert_eq!(throttled.standing_retry(), None, "the timer retries a rate refusal");
		assert!(oversized.with_context("joining").standing_retry().is_some());
		// No later attempt of the same request can succeed.
		assert_eq!(
			Error::invalid("Membership locator exceeds its bound").standing_retry(),
			Some(Retry::AfterRequestChange)
		);
		assert_eq!(Error::refused("not permitted").standing_retry(), Some(Retry::Never));
		// A refused receipt stands by its code alone. The timer reattempts a
		// reach failure and a refusal that names no code.
		let receipt = |line: &str| Error::from(rooms_glowcap::client::Error::RefusedObservation(line.into()));
		assert_eq!(receipt("host queue full").standing_retry(), None);
		assert_eq!(receipt("peer-unreachable: no route").standing_retry(), None);
		assert_eq!(receipt("member-unreachable: gone").standing_retry(), None);
		assert_eq!(
			receipt("nick-taken: Ann").standing_retry(),
			Some(FailureCode::NickTaken.definition().retry)
		);
		// These clear when a deadline passes, a slot frees, or a worker
		// returns, and none of them wakes the loop: the recovery timer does.
		for timed in [
			Error::uncertain("Membership admission remains pending"),
			Error::closed("Membership retry owner closed"),
			Error::exhausted("retained capacity is full"),
			Error::stale("moved"),
			Error::busy("working"),
			Error::from(rooms_glowcap::client::Error::Timeout("late")),
		] {
			assert!(timed.standing_retry().is_none(), "{timed}");
		}
	}

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
		// A coded failure answers with its catalog row, and its text is the
		// line a peer would read for that code.
		let coded = Error::coded(FailureCode::LinkPreviewTimedOut, "the site was slow");
		assert_eq!(coded.retry(), Retry::Soon);
		assert_eq!(coded.standing_retry(), None);
		assert_eq!(coded.to_string(), "link-preview-timed-out: the site was slow");
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
