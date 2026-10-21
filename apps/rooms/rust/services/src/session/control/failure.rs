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
		let class = match &error {
			Error::Refused(_) => "refused",
			Error::Invalid(_) => "invalid",
			Error::Busy(_) => "busy",
			Error::Exhausted(_) => "exhausted",
			Error::Stale(_) => "stale",
			Error::Closed(_) => "closed",
			Error::Uncertain(_) => "uncertain",
			Error::Captp(_) => "captp",
			Error::Peer(_) => "peer",
			Error::Storage(_) => "storage",
			Error::Cleanup { .. } => "cleanup",
		};
		Self::new(class, error.retry().wire(), error)
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
}
