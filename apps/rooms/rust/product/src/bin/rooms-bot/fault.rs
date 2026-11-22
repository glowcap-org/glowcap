//! Test-only fault points. In a build with the `test-support` feature,
//! `GLOWCAP_ROOMS_BOT_FAULT=<point>`
//! makes the bot kill itself with SIGKILL the first time it reaches that
//! point, and `<point>@<n>` the n-th time, so a process test can end the bot
//! at an exact step of a turn. A point reached through [`fails`] instead
//! makes that one step fail and the bot goes on. A build without the feature
//! contains no trace of this.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Point {
	/// The ledger holds a line's base and the line is not sent yet.
	BeforeSend,
	/// The session answered a send and the ledger does not know the answer.
	AfterSend,
	/// The ledger records a line committed and the line is not kept yet.
	AfterCommit,
	/// The ledger records the line as sent and the turn has more to do.
	AfterRecord,
	/// The session released a line's receipt and the ledger still owes the
	/// release.
	AfterRelease,
	/// The ledger write that fixes the harness's answer. Reached through
	/// [`fails`].
	AnswerWrite,
	/// A send the session answered, read as one that outlasted its deadline.
	/// Reached through [`fails`].
	LateSend,
}

#[cfg(feature = "test-support")]
mod armed {
	use super::Point;
	use std::sync::atomic::{AtomicU32, Ordering};

	static BEFORE_SEND: AtomicU32 = AtomicU32::new(0);
	static AFTER_SEND: AtomicU32 = AtomicU32::new(0);
	static AFTER_COMMIT: AtomicU32 = AtomicU32::new(0);
	static AFTER_RECORD: AtomicU32 = AtomicU32::new(0);
	static AFTER_RELEASE: AtomicU32 = AtomicU32::new(0);
	static ANSWER_WRITE: AtomicU32 = AtomicU32::new(0);
	static LATE_SEND: AtomicU32 = AtomicU32::new(0);

	/// Whether the armed point is this one, at this count.
	fn armed(point: Point) -> bool {
		let (name, count) = match point {
			Point::BeforeSend => ("before-send", &BEFORE_SEND),
			Point::AfterSend => ("after-send", &AFTER_SEND),
			Point::AfterCommit => ("after-commit", &AFTER_COMMIT),
			Point::AfterRecord => ("after-record", &AFTER_RECORD),
			Point::AfterRelease => ("after-release", &AFTER_RELEASE),
			Point::AnswerWrite => ("answer-write", &ANSWER_WRITE),
			Point::LateSend => ("late-send", &LATE_SEND),
		};
		let Ok(armed) = std::env::var("GLOWCAP_ROOMS_BOT_FAULT") else {
			return false;
		};
		let (armed_name, nth) = armed.split_once('@').unwrap_or((armed.as_str(), "1"));
		let reached = count.fetch_add(1, Ordering::Relaxed).saturating_add(1);
		armed_name == name && nth.parse::<u32>().is_ok_and(|nth| nth == reached)
	}

	pub fn fails(point: Point) -> bool {
		armed(point)
	}

	pub fn hit(point: Point) {
		if armed(point) {
			// best-effort: a signal that cannot be delivered to ourselves leaves
			// abort as the only way to stop without running any cleanup.
			let _ = nix::sys::signal::raise(nix::sys::signal::Signal::SIGKILL);
			std::process::abort();
		}
	}
}

#[cfg(feature = "test-support")]
pub use armed::{fails, hit};

#[cfg(not(feature = "test-support"))]
pub fn hit(_point: Point) {}

#[cfg(not(feature = "test-support"))]
pub fn fails(_point: Point) -> bool {
	false
}
