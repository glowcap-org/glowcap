//! When asking again can help, read from a failure's class and typed cause
//! alone. The answers use the same `Retry` vocabulary the wire's failure
//! codes use, so an owner that only knows the class still answers "try
//! again, or not?" correctly.
use super::Error;
use rooms_application::failure::Retry;

impl Error {
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
			Self::Coded { code, .. } => own_change(*code),
			Self::Captp(error) => binding_standing_retry(error),
			Self::Peer(error) => match error.as_ref() {
				rooms_glowcap::client::Error::Binding(error) | rooms_glowcap::client::Error::Unsent(error) => {
					binding_standing_retry(error)
				}
				// A lost observation forbids replaying that one effect. The
				// worker's next attempt is a new request.
				rooms_glowcap::client::Error::Observation(_) => None,
				// A refused receipt keeps its line and drops the cause, so it
				// stands by its code alone, and a line with no code names no
				// change to wait for.
				refused @ rooms_glowcap::client::Error::RefusedObservation(_) => {
					refused.failure_code().and_then(own_change)
				}
				// The attached session did not answer this side, which time clears.
				rooms_glowcap::client::Error::Unreached { .. } => None,
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
			Self::Captp(error) => rooms_glowcap::client::binding_retry(error),
			// Each of these waits for the state it found to change.
			Self::Exhausted(_)
			| Self::Stale(_)
			| Self::Closed(_)
			| Self::Uncertain(_)
			| Self::Storage(_)
			| Self::Platform(_) => Retry::AfterStateChange,
			Self::Peer(error) => error.retry(),
			Self::Cleanup { primary, .. } => primary.retry(),
		}
	}
}

/// The change a catalog code waits for, or none when it asks for a retry
/// soon: the recovery timer makes that attempt.
fn awaited_change(code: rooms_application::failure::FailureCode) -> Option<Retry> {
	let retry = code.definition().retry;
	(retry != Retry::Soon).then_some(retry)
}
/// The change a code waits for when this side wrote it, or a receipt kept it
/// without its cause. There a reach code says this side could not reach a
/// peer, which time clears. A peer's own line with that code says the peer
/// could not reach someone, so it waits for its catalog change instead.
fn own_change(code: rooms_application::failure::FailureCode) -> Option<Retry> {
	if code.reach() {
		return None;
	}
	awaited_change(code)
}
/// The retry condition when only a different request can succeed, so no
/// timer helps.
fn request_bound(retry: Retry) -> Option<Retry> {
	matches!(retry, Retry::Never | Retry::AfterRequestChange).then_some(retry)
}

/// A binding failure stands by its catalog code's retry condition, unless its
/// cause clears with time. The code still names that failure to a person.
fn binding_standing_retry(error: &glowcap::Error) -> Option<Retry> {
	match rooms_glowcap::client::binding_failure(error) {
		Some(failure) => coded_binding(error.cause(), failure.code),
		None if rooms_glowcap::client::clears_with_time(error.cause()) => None,
		None => request_bound(rooms_glowcap::client::binding_retry(error)),
	}
}
/// A coded binding failure's cause decides whether time clears it. A peer's
/// own line arrives with the partner's cause, so a reach code it carries
/// waits for its catalog change.
fn coded_binding(cause: glowcap::BreakCause, code: rooms_application::failure::FailureCode) -> Option<Retry> {
	if rooms_glowcap::client::clears_with_time(cause) {
		return None;
	}
	awaited_change(code)
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
		assert_eq!(receipt("session-unreachable: gone").standing_retry(), None);
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
	fn a_peer_that_could_not_reach_someone_stands_until_that_changes() {
		use glowcap::{BreakCause, BreakReason};
		for code in [
			FailureCode::MemberUnreachable,
			FailureCode::PeerUnreachable,
			FailureCode::SessionUnreachable,
		] {
			// A peer's line, which arrives with the partner's cause.
			assert_eq!(
				super::coded_binding(BreakCause::partner(), code),
				Some(Retry::AfterStateChange),
				"{code:?}"
			);
			// The same code where this side could not reach the peer.
			assert_eq!(
				super::coded_binding(BreakCause::local(BreakReason::PeerUnreachable), code),
				None
			);
			assert_eq!(Error::coded(code, "gone").standing_retry(), None, "{code:?}");
		}
	}

	#[test]
	fn an_unreached_session_clears_with_time_however_it_was_built() {
		use rooms_glowcap::client::Error as ClientError;
		let unreached = |cause| {
			Error::from(ClientError::Unreached {
				detail: "The session did not answer",
				cause,
			})
		};
		for error in [
			unreached(None),
			unreached(Some(Box::new(glowcap::loam::refusal("closed")))),
			Error::coded(FailureCode::SessionUnreachable, "The session did not answer"),
		] {
			assert_eq!(error.standing_retry(), None, "{error}");
			assert_eq!(error.with_context("restoring").standing_retry(), None);
		}
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
}
