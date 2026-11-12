//! JSON is a presentation boundary: retain failure class and retry advice.
use rooms_runtime::Error;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Failure {
	pub class: String,
	pub retry: String,
	pub message: String,
}
impl Failure {
	pub fn new(class: &str, retry: &str, message: impl ToString) -> Self {
		Self {
			class: class.into(),
			retry: retry.into(),
			message: message.to_string(),
		}
	}
	pub fn invalid(message: impl ToString) -> Self {
		Self::new("invalid", "after-request-change", message)
	}
	pub fn exhausted(message: impl ToString) -> Self {
		Self::new("exhausted", "after-state-change", message)
	}
	pub fn uncertain(message: impl ToString) -> Self {
		Self::new("uncertain", "after-state-change", message)
	}
	pub fn response(&self) -> Value {
		json!({"ok": false, "error": self})
	}
}
impl std::fmt::Display for Failure {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		self.message.fmt(f)
	}
}
impl std::error::Error for Failure {}
impl From<std::io::Error> for Failure {
	fn from(error: std::io::Error) -> Self {
		Self::new("io", "after-state-change", error)
	}
}
impl From<serde_json::Error> for Failure {
	fn from(error: serde_json::Error) -> Self {
		Self::invalid(error)
	}
}
impl From<rooms_platform::storage::StorageError> for Failure {
	fn from(error: rooms_platform::storage::StorageError) -> Self {
		use rooms_platform::storage::StorageError;
		let (class, retry) = match &error {
			StorageError::Pending => ("busy", "soon"),
			StorageError::InUse(_) => ("in-use", "after-state-change"),
			StorageError::Io(_) | StorageError::Document(_) => ("storage", "after-state-change"),
			StorageError::Worker(_) => ("worker", "after-state-change"),
			StorageError::Cleanup { .. } => ("cleanup", "after-state-change"),
		};
		Self::new(class, retry, error)
	}
}
impl From<Error> for Failure {
	fn from(error: Error) -> Self {
		Self::new(class(&error), error.retry().wire(), error)
	}
}
/// A failure the catalog names is classed by its code, whichever owner
/// carried it. Any other is classed by the owner that failed. Context and a
/// failed cleanup describe the failure inside them, as `Error::retry` reads
/// them. An admission class says nothing was sent, so text a peer wrote earns
/// one only as a validated refusal.
fn class(error: &Error) -> &'static str {
	let named = |failure: Option<rooms_application::failure::Failure<'_>>, owner| {
		failure
			.filter(|failure| !failure.code.admission() || failure.refused_before_dispatch())
			.map_or(owner, |failure| failure.code.wire())
	};
	match error {
		Error::Context { source, .. } => class(source),
		Error::Cleanup { primary, .. } => class(primary),
		Error::Admission { refusal, .. } => refusal.code().wire(),
		Error::Coded { code, .. } => code.wire(),
		Error::Captp(error) => named(rooms_glowcap::client::binding_failure(error), "captp"),
		Error::Peer(error) => named(error.failure(), "peer"),
		Error::Refused(_) => "refused",
		Error::Invalid(_) => "invalid",
		Error::Busy(_) => "busy",
		Error::Exhausted(_) => "exhausted",
		Error::Stale(_) => "stale",
		Error::Closed(_) => "closed",
		Error::Uncertain(_) => "uncertain",
		Error::Storage(_) => "storage",
		Error::Platform(_) => "platform",
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn a_filesystem_refusal_is_not_an_in_progress_operation() {
		use rooms_platform::storage::StorageError;
		let denied = Failure::from(StorageError::Io(std::io::ErrorKind::PermissionDenied.into()));
		assert_eq!(
			(denied.class.as_str(), denied.retry.as_str()),
			("storage", "after-state-change")
		);
		let held = Failure::from(StorageError::InUse("workspace".into()));
		assert_eq!(
			(held.class.as_str(), held.retry.as_str()),
			("in-use", "after-state-change")
		);
		let pending = Failure::from(StorageError::Pending);
		assert_eq!((pending.class.as_str(), pending.retry.as_str()), ("busy", "soon"));
	}
	#[test]
	fn transport_and_application_failures_keep_their_meaning() {
		for (error, class, retry) in [
			(Error::invalid("shape"), "invalid", "after-request-change"),
			(Error::busy("admitted"), "busy", "soon"),
			(Error::exhausted("full"), "exhausted", "after-state-change"),
			(Error::uncertain("sent"), "uncertain", "after-state-change"),
		] {
			let failure = Failure::from(error);
			assert_eq!(failure.class, class);
			assert_eq!(failure.retry, retry);
		}
		assert_eq!(
			Failure::from(std::io::Error::from(std::io::ErrorKind::BrokenPipe)).class,
			"io"
		);
	}
	/// One branch on the class serves a code this session named and a code a
	/// peer's refusal carried, through any context or cleanup around either.
	#[test]
	fn a_failure_the_catalog_names_is_classed_by_its_code() {
		use rooms_application::{admission, failure::FailureCode};
		let coded = Failure::from(Error::coded(FailureCode::LinkPreviewTimedOut, "the site was slow"));
		assert_eq!(coded.class, FailureCode::LinkPreviewTimedOut.wire());
		assert_eq!(coded.retry, FailureCode::LinkPreviewTimedOut.definition().retry.wire());
		let admission = || Error::Admission {
			refusal: admission::Refusal::Capacity,
			owner: None,
		};
		assert_eq!(Failure::from(admission()).class, FailureCode::AdmissionBusy.wire());
		assert_eq!(
			Failure::from(admission().with_context("posting")).class,
			FailureCode::AdmissionBusy.wire()
		);
		assert_eq!(
			Failure::from(admission().retain(Error::closed("release failed"))).class,
			FailureCode::AdmissionBusy.wire()
		);
		// A refusal Rooms retained reads the way a live one does.
		let peer = |text: &str| Error::peer(rooms_glowcap::client::Error::RefusedObservation(text.into()));
		assert_eq!(
			Failure::from(peer("nick-taken: Ann")).class,
			FailureCode::NickTaken.wire()
		);
		assert_eq!(
			Failure::from(peer("admission-busy: the server work queue is full")).class,
			FailureCode::AdmissionBusy.wire()
		);
		// A rate limit with no advice it can read is not proof nothing was sent.
		assert_eq!(Failure::from(peer("rate-limited: soon")).class, "peer");
		assert_eq!(Failure::from(peer("the member hung up")).class, "peer");
		let undialed = Error::Captp(std::rc::Rc::new(glowcap::Error::transport_unavailable("no provider")));
		assert_eq!(Failure::from(undialed).class, FailureCode::TransportNotDialed.wire());
	}
}
