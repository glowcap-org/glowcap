//! The pacing of a delivery: the bounds on its tries, the waits between
//! them, what each step does next, and the deadline on a call to the session.
use super::{super::backoff::Backoff, receipt::Running};
use crate::bot::{
	rooms::{RoomsError, RoomsErrorKind},
	words::UNANSWERED,
};
use std::{future::Future, time::Duration};
use tokio::time::timeout;

/// How many times in a row a line may go out under a new operation after the
/// session committed nothing before the tries slow down. A conflict refuses
/// the base, not the line, and a failure line would meet the same writes, so
/// the line is never replaced.
pub(super) const MAX_REISSUES: u32 = 3;
/// How many looks may find a send still running before the looks slow down
/// and `status` reports the wait.
pub(super) const MAX_LOOKS: u32 = 20;

/// How often a reply held for the access to work again looks at it. The look
/// reads the recorded state and calls nothing.
pub(super) const ACCESS_POLL: Duration = Duration::from_secs(1);

/// What delivery does next.
pub(super) enum Next {
	Now,
	After(Duration),
	/// The access is not active. `drive` decides the wait, see [`Mode::access_wait`].
	Access,
	Finished,
}

/// The waits and counts one delivery keeps between steps.
pub(super) struct Tries {
	pub(super) standard: Backoff,
	pub(super) slow: Backoff,
	pub(super) reissues: u32,
	/// The next step sends the same operation at its base again instead of
	/// observing it, as this call. A send whose receipt the session does not
	/// hold, with no echo in a complete read of activity, goes out as
	/// `Call::Resend`. A refused resend is observed again first, as an
	/// uncertain send is.
	pub(super) again: Option<Call>,
	/// The refusal of this line's resend, which says nothing of its earlier
	/// send. It becomes the reason for a failure line only once a look shows
	/// that the operation did not post.
	pub(super) refused_resend: Option<RoomsError>,
	/// When the line's receipt first answered running to a release.
	pub(super) running: Running,
}

impl Tries {
	pub(super) fn new() -> Self {
		Self {
			standard: Backoff::standard(),
			slow: Backoff::slow(),
			reissues: 0,
			again: None,
			refused_resend: None,
			running: Running::default(),
		}
	}
	/// The call `again` repeats belongs to one operation of one line. A line
	/// abandoned for a failure line, or reissued under a new operation, owes
	/// no repeat, because a repeat would send the next call as a first send
	/// and skip the echo check that keeps a line from posting twice.
	pub(super) fn ended(&mut self) {
		self.again = None;
		self.refused_resend = None;
	}
	pub(super) fn settled(&mut self) {
		self.standard.reset();
		self.slow.reset();
		self.reissues = 0;
		self.refused_resend = None;
		self.running = Running::default();
	}
}

/// Which call of an operation an answer is for.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Call {
	/// The operation's first send, so a conflict means it committed nothing.
	FirstSend,
	/// The same operation sent again at its base after the session held no
	/// receipt for it and activity showed no echo. A conflict means the
	/// operation can never commit, but not that the line never posted under it.
	Resend,
	/// A look at an operation already sent. A conflict is its receipt saying
	/// it committed nothing.
	Observe,
}

/// What a delivery loop does with its turn's line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Mode {
	/// Send the line and settle it, only while the access is active.
	Deliver,
	/// Settle a line already sent and stop before sending another.
	SettleSent,
}

impl Mode {
	/// The wait after a call met an access that is not active. A delivery
	/// goes straight to the loop's own wait, which does not call the session.
	/// A settle skips that wait, so it backs off on the slow schedule between
	/// its calls.
	pub(super) fn access_wait(self, slow: &mut Backoff) -> Option<Duration> {
		match self {
			Self::Deliver => None,
			Self::SettleSent => Some(slow.next()),
		}
	}
}

/// A call to the session, failed as unreachable when it outlasts `limit`.
pub(in crate::bot::engine) async fn within<T>(
	limit: Duration,
	call: impl Future<Output = Result<T, RoomsError>>,
) -> Result<T, RoomsError> {
	timeout(limit, call).await.unwrap_or_else(|_| Err(late()))
}

pub(super) fn late() -> RoomsError {
	RoomsError::new(RoomsErrorKind::Unreachable, UNANSWERED)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_settle_backs_off_on_the_slow_schedule_and_a_reply_leaves_the_wait_to_the_delivery_loop() {
		let mut slow = Backoff::slow();
		let waits: Vec<u64> = (0..5)
			.map(|_| Mode::SettleSent.access_wait(&mut slow).unwrap().as_secs())
			.collect();
		assert_eq!(waits, [1, 2, 4, 8, 16]);
		assert!(Mode::Deliver.access_wait(&mut slow).is_none());
		assert_eq!(
			Mode::SettleSent.access_wait(&mut slow).unwrap().as_secs(),
			32,
			"a reply left the schedule alone"
		);
	}

	#[test]
	fn an_ended_line_owes_no_repeat_of_its_call() {
		for call in [Call::FirstSend, Call::Resend] {
			let mut tries = Tries::new();
			tries.again = Some(call);
			tries.ended();
			assert!(
				tries.again.is_none(),
				"the next line's call is observed, never sent blind"
			);
		}
	}
}
