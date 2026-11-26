//! Test-only fault points. In a build with the `test-support` feature,
//! `GLOWCAP_ROOMS_BOT_FAULT=<point>` arms one point by name, so a process test
//! can end the bot at an exact step of a turn or make one step fail. A
//! [`Kill`] point makes the bot kill itself with SIGKILL the first time it
//! reaches the point, and `<point>@<n>` kills it the n-th time. A [`Fail`]
//! point makes that one step fail and the bot goes on, and `<point>@*` makes it
//! fail every time. The two kinds are separate types, so a kill point cannot
//! be passed where a failing step is wanted. A name that is no point stops
//! the process at its first read. A build without the feature
//! contains no trace of this.
//!
//! The `points!` form generates each kind's enum, name table, and counts from
//! one list, as the session view's fault points do in
//! `services/src/session/attached/fault.rs`. Each crate keeps a copy because
//! the only crates both share are release crates, and a test-only macro does
//! not belong in one.

use super::error::Error;

/// The variables this build reads besides the settings: none in a release
/// build, which has no fault switch.
#[cfg(feature = "test-support")]
const FAULT_VARIABLE: &str = "GLOWCAP_ROOMS_BOT_FAULT";
#[cfg(feature = "test-support")]
pub const VARIABLES: &[&str] = &[FAULT_VARIABLE];
#[cfg(not(feature = "test-support"))]
pub const VARIABLES: &[&str] = &[];

/// One kind of fault point as an enum, with the name the variable arms it by
/// and the count of times this process reached it.
macro_rules! points {
	($(#[$meta:meta])* $kind:ident { $($(#[$doc:meta])* $variant:ident = $name:literal,)* }) => {
		$(#[$meta])*
		#[derive(Clone, Copy, Debug, PartialEq, Eq)]
		#[cfg_attr(not(feature = "test-support"), allow(dead_code, reason = "only test-support code reaches a point"))]
		pub enum $kind {
			$($(#[$doc])* $variant,)*
		}

		#[cfg(feature = "test-support")]
		impl $kind {
			const ALL: &'static [Self] = &[$(Self::$variant,)*];

			fn name(self) -> &'static str {
				match self {
					$(Self::$variant => $name,)*
				}
			}

			/// Whether the variable arms this point at this count.
			fn armed(self) -> bool {
				static COUNTS: [std::sync::atomic::AtomicU32; <$kind>::ALL.len()] =
					[const { std::sync::atomic::AtomicU32::new(0) }; <$kind>::ALL.len()];
				armed(self.name(), &COUNTS[self as usize])
			}
		}
	};
}

points! {
	/// A step where the bot kills itself when armed.
	Kill {
		/// The ledger holds a line's base and the line is not sent yet.
		BeforeSend = "before-send",
		/// The session answered a send and the ledger does not know the answer.
		AfterSend = "after-send",
		/// The ledger records a line committed and the line is not kept yet.
		AfterCommit = "after-commit",
		/// The ledger records the line as sent and the turn has more to do.
		AfterRecord = "after-record",
		/// The session released a line's receipt and the ledger still owes the
		/// release.
		AfterRelease = "after-release",
		/// The first start stored its settings and not yet its link.
		BeforeLink = "before-link",
		/// A start stored its link, and the session's answers about what an
		/// earlier link left have not yet been written.
		AfterLink = "after-link",
		/// An agent's action claimed its operation and has not sent it yet.
		AfterNote = "after-note",
	}
}

points! {
	/// A step that fails once, or every time, when armed.
	Fail {
		/// The ledger write that fixes the harness's answer.
		AnswerWrite = "answer-write",
		/// The ledger write that fixes a reply, which fails with a refused
		/// permission, as waiting does not clear.
		AnswerRefused = "answer-refused",
		/// The ledger write that records a run that ended in a retry, which
		/// fails as a disk error does, so the turn thinks again after a wait.
		RetryWrite = "retry-write",
		/// The ledger write that records a run the bot's own stop cut off,
		/// which fails as a disk error does.
		CutOffWrite = "cut-off-write",
		/// A send the session answered, read as one that outlasted its deadline.
		LateSend = "late-send",
		/// The write of the settings and link once the session has answered, which
		/// a serving bot tries again.
		LinkWrite = "link-write",
		/// A look at a direct-message open or an agent's action that answers
		/// still pending, so the session's own answer is not asked.
		SettlePending = "settle-pending",
		/// A look at a direct-message open that answers the session cannot say
		/// whether it committed, so the bot gives up on it.
		SettleUnknown = "settle-unknown",
		/// The ask of the session whose receipt an operation is, which answers
		/// unreachable.
		HolderLook = "holder-look",
		/// The ask of the session whose receipt an operation is, answered
		/// "another" whatever the session holds, so a proof sees what a wrong
		/// answer does.
		HolderAnother = "holder-another",
		/// The ask of the session whose receipt an operation is, refused for good
		/// whatever the session holds.
		HolderRefused = "holder-refused",
		/// The removal of the note of an open whose receipt the session gave
		/// back, which fails so the note stays given up.
		Forget = "forget",
		/// The removal of the note of an open a verb settled, which fails so
		/// the note stays for the serving loop.
		DropNote = "drop-note",
		/// A `status` probe holding the lease as a reader, which makes the probe
		/// hold it until a contender has met it or a proof releases it.
		ProbeHeld = "probe-held",
		/// The wait before a reply's next try after a refusal, which holds until
		/// a proof writes `retry-go` and then tries at once. `hold-retry@4`
		/// holds after the fourth wait.
		HoldRetry = "hold-retry",
		/// An agent's action after it claimed its operation and before it sends,
		/// which holds until a proof writes `note-go`, so a proof acts on the
		/// verb while its claim stands.
		HoldNote = "hold-note",
		/// The list of the receipts this access holds, which answers
		/// unreachable.
		HeldList = "held-list",
		/// A verb's budget, spent as it dials the session.
		SpentAttach = "spent-attach",
		/// A verb's budget, spent as it reaches the conversation `--dm` names.
		SpentOpen = "spent-open",
		/// A verb's budget, spent as its call to the session starts, so the
		/// call is never sent.
		SpentCall = "spent-call",
		/// A verb's budget, spent before its look at the session.
		SpentLook = "spent-look",
	}
}

/// Whether the variable arms the point named `name`, counting this reach in
/// `reached`.
#[cfg(feature = "test-support")]
fn armed(name: &str, reached: &std::sync::atomic::AtomicU32) -> bool {
	let Ok(armed) = std::env::var(FAULT_VARIABLE) else {
		return false;
	};
	let (armed_name, nth) = armed.split_once('@').unwrap_or((armed.as_str(), "1"));
	// A name that is no point would arm nothing and let the test pass, so it
	// stops the process at the first read.
	let known = Kill::ALL
		.iter()
		.map(|point| point.name())
		.chain(Fail::ALL.iter().map(|point| point.name()));
	assert!(
		known.clone().any(|point| point == armed_name),
		"{FAULT_VARIABLE} names {armed_name:?}, which is no fault point: {}",
		known.collect::<Vec<_>>().join(", ")
	);
	let reached = reached
		.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
		.saturating_add(1);
	armed_name == name && (nth == "*" || nth.parse::<u32>().is_ok_and(|nth| nth == reached))
}

/// End the process at `point` when it is armed.
#[cfg(feature = "test-support")]
pub fn hit(point: Kill) {
	if point.armed() {
		// best-effort: a signal that cannot be delivered to ourselves leaves
		// abort as the only way to stop without running any cleanup.
		let _ = nix::sys::signal::raise(nix::sys::signal::Signal::SIGKILL);
		std::process::abort();
	}
}

/// Whether `point` is armed, so its step fails.
#[cfg(feature = "test-support")]
pub fn fails(point: Fail) -> bool {
	point.armed()
}

/// How long a hold waits for the proof's signal before it gives up, so a
/// proof that never signals ends.
#[cfg(feature = "test-support")]
const HOLD_BOUND: std::time::Duration = std::time::Duration::from_secs(60);

/// Hold a `status` probe's shared lease while a proof starts the contender it
/// must not stop, when it asks, and leave `probe-held` in `root` to say the
/// probe holds it. The hold ends when a contender has met it, which the
/// contender says by leaving `lease-met` ([`lease_met`]), or when a proof that
/// needs no contender writes `probe-release`. A hold that nothing ends
/// fails the probe after [`HOLD_BOUND`].
#[cfg(feature = "test-support")]
pub fn hold(root: &std::path::Path) -> std::io::Result<()> {
	if fails(Fail::ProbeHeld) {
		std::fs::write(root.join("probe-held"), b"")?;
		let until = std::time::Instant::now() + HOLD_BOUND;
		while !root.join("lease-met").exists() && !root.join("probe-release").exists() {
			if std::time::Instant::now() >= until {
				return Err(std::io::Error::new(
					std::io::ErrorKind::TimedOut,
					"no contender met the probe's hold",
				));
			}
			std::thread::sleep(std::time::Duration::from_millis(10));
		}
	}
	Ok(())
}

/// Say that this start found the bot directory's lease held, before it waits
/// for it, by leaving `lease-met` in `root`.
#[cfg(feature = "test-support")]
pub fn lease_met(root: &std::path::Path) {
	// best-effort: a marker that is not written leaves the proof that waits
	// for it to fail at its own bound.
	let _ = std::fs::write(root.join("lease-met"), b"");
}

/// Hold a verb after its claim, when armed, until a proof writes `note-go` in
/// `root`, and leave `note-held` there to say it holds. The hold is bounded,
/// so a proof that never signals ends.
#[cfg(feature = "test-support")]
pub async fn held_note(root: &std::path::Path) {
	if !fails(Fail::HoldNote) {
		return;
	}
	// best-effort: a marker that is not written leaves the proof that waits
	// for it to fail at its own bound.
	let _ = std::fs::write(root.join("note-held"), b"");
	let until = tokio::time::Instant::now() + HOLD_BOUND;
	while !root.join("note-go").exists() && tokio::time::Instant::now() < until {
		tokio::time::sleep(std::time::Duration::from_millis(10)).await;
	}
}

#[cfg(not(feature = "test-support"))]
pub async fn held_note(_root: &std::path::Path) {}

/// Hold a reply's next try, when armed, until a proof writes `retry-go` in
/// `root`, and leave `retry-held` there to say it holds. Whether it held, so
/// the caller tries at once and not after its backoff. A stop ends the hold.
#[cfg(feature = "test-support")]
pub async fn held_retry(root: &std::path::Path, stop: &tokio::sync::watch::Receiver<bool>) -> bool {
	if !fails(Fail::HoldRetry) {
		return false;
	}
	// best-effort: a marker that is not written leaves the proof that waits
	// for it to fail at its own bound.
	let _ = std::fs::write(root.join("retry-held"), b"");
	let until = tokio::time::Instant::now() + HOLD_BOUND;
	while !root.join("retry-go").exists() && !*stop.borrow() && tokio::time::Instant::now() < until {
		tokio::time::sleep(std::time::Duration::from_millis(10)).await;
	}
	true
}

#[cfg(not(feature = "test-support"))]
pub async fn held_retry(_root: &std::path::Path, _stop: &tokio::sync::watch::Receiver<bool>) -> bool {
	false
}

#[cfg(not(feature = "test-support"))]
pub fn hold(_root: &std::path::Path) -> std::io::Result<()> {
	Ok(())
}

#[cfg(not(feature = "test-support"))]
pub fn hit(_point: Kill) {}

#[cfg(not(feature = "test-support"))]
pub fn fails(_point: Fail) -> bool {
	false
}

/// The write of the settings and link, which the fault `link-write` makes
/// fail with the error a full or failing disk gives.
#[cfg(feature = "test-support")]
pub fn link_write() -> Result<(), Error> {
	if fails(Fail::LinkWrite) {
		return Err(Error::Storage(rooms_platform::storage::StorageError::Io(
			std::io::Error::from_raw_os_error(5),
		)));
	}
	Ok(())
}

#[cfg(not(feature = "test-support"))]
pub fn link_write() -> Result<(), Error> {
	Ok(())
}

#[cfg(all(test, feature = "test-support"))]
mod tests {
	use super::{Fail, Kill};

	#[test]
	fn no_name_arms_two_points() {
		let names: Vec<_> = Kill::ALL
			.iter()
			.map(|point| point.name())
			.chain(Fail::ALL.iter().map(|point| point.name()))
			.collect();
		for name in &names {
			assert_eq!(
				names.iter().filter(|other| *other == name).count(),
				1,
				"{name} is repeated"
			);
		}
	}
}
