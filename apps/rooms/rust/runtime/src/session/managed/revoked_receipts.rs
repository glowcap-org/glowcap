//! Receipts a revoked access left. A committed receipt nobody adopted belongs
//! to the access that sent it, and only that access can adopt or release it,
//! so the replay window never evicts it. Once that access is revoked nobody
//! can, and the receipt would hold one of the session's receipt places for
//! good. This owner releases each such receipt.
//!
//! The session's change feeds start it with themselves, so every host that
//! opens a session runs it. It sweeps once at
//! start and again on every session change. A revocation changes the grant
//! inventory, and a receipt settled after its access was revoked changes
//! content, so both wake it. A sweep makes one private read of the receipts
//! waiting to be adopted, and one local access description per waiting
//! receipt.
//!
//! A sweep skips a receipt it cannot check or release and goes on with the
//! rest. A failed sweep goes to the session's failure owner, as `Revoked
//! receipt release`, once until a sweep succeeds or a different failure
//! follows, and the owner sweeps again on a bounded backoff as well as on the
//! next change, because a session whose receipt places are full may make no
//! further change. A failed feed is reported by the feed, and until it
//! recovers the owner sweeps on the same backoff.
//!
//! A platform's wait returns `None` at once when it refuses the wait, and
//! `None` on time when it runs out, so only the clock tells the two apart.
//! The host and browser platforms never refuse a wait. The proofs platform
//! refuses one while a proof refuses observation. A backoff whose wait came
//! back early is dropped, and reported once like a failed sweep, so the owner
//! sweeps again on the next change only and never loops without giving a
//! single-threaded host a turn.
//!
//! `Session::close` closes this owner before anything else it closes, so no
//! sweep runs while the session shuts down.
use super::{Membership, changes::Wake, executor::Writer, supervision};
use crate::Error;
use glowcap::{Argument, Ref, loam};
use rooms_glowcap::client::{Deadline, Tasks};
use std::rc::Rc;

type Result<T> = core::result::Result<T, Error>;

/// The first wait before sweeping again after a failure, doubled after each
/// failure up to `LAST_RETRY_MS`.
const FIRST_RETRY_MS: u64 = 1_000;
const LAST_RETRY_MS: u64 = 60_000;

/// Start the owner in the feeds' own budget, which closes it with them.
pub(super) fn spawn<P: Tasks + Deadline + Clone + 'static>(
	platform: &P,
	budget: &Rc<supervision::Budget<P>>,
	writer: Rc<Writer>,
	mut wake: Wake,
) -> Membership<P> {
	let timer = platform.clone();
	supervision::spawn(
		platform,
		budget,
		"revoked-receipt-release".into(),
		None,
		move |mut signals| async move {
			signals.ready.send_replace(Some(Ok(())));
			let mut schedule = Schedule::default();
			loop {
				if *signals.stopping.borrow_and_update() {
					return Ok(());
				}
				let armed = schedule.retry.map(|wait| (wait, timer.monotonic_millis()));
				let backoff = async {
					match armed {
						Some((wait, _)) => timer.within(wait, core::future::pending::<()>()).await,
						None => core::future::pending().await,
					}
				};
				let woke = tokio::select! {
					biased;
					_ = signals.stopping.changed() => return Ok(()),
					changed = wake.changed() => Woke::Changed(changed.is_ok()),
					_ = backoff => Woke::Backoff {
						early: armed.is_some_and(|(wait, at)| early(wait, timer.monotonic_millis().saturating_sub(at))),
					},
				};
				match schedule.woke(woke) {
					Next::Sweep => {}
					Next::Wait => continue,
					Next::Dropped(error) => {
						writer.report("Revoked receipt release", &error);
						continue;
					}
				}
				let swept = tokio::select! {
					biased;
					_ = signals.stopping.changed() => return Ok(()),
					swept = sweep(&writer) => swept,
				};
				if let Some(error) = schedule.swept(&swept) {
					writer.report("Revoked receipt release", error);
				}
			}
		},
	)
}

/// What woke the owner.
#[derive(Clone, Copy, Debug)]
enum Woke {
	/// The feed reported a change, or its own failure when false.
	Changed(bool),
	/// The backoff a failure asked for ran out, or its timer returned in
	/// under half its wait when `early`.
	Backoff { early: bool },
}

/// Whether a timer that returned after `elapsed` of a `wait` refused it. A
/// timer may return a little before its wait on a coarse clock, and one that
/// refuses returns at once.
fn early(wait: u64, elapsed: u64) -> bool {
	elapsed.saturating_mul(2) < wait
}

/// What the owner does after a wake.
#[derive(Debug)]
enum Next {
	Sweep,
	Wait,
	/// The platform refused the backoff's wait, so the owner waits for the
	/// next change and reports this, once, to the session's failure owner.
	Dropped(Error),
}

/// The text of the report a dropped backoff makes.
const DROPPED: &str =
	"the platform refused the wait before sweeping again, so the next sweep waits for a session change";

/// When the owner sweeps again on its own, and the failure it reported last.
#[derive(Debug, Default)]
struct Schedule {
	reported: Option<String>,
	/// The wait before the next sweep a failure asks for, if any.
	retry: Option<u64>,
	/// The feed that wakes this owner has failed, so it sweeps on the backoff
	/// until the feed recovers.
	feed_failed: bool,
	/// A dropped backoff was reported since the last sweep that succeeded.
	dropped: bool,
}
impl Schedule {
	/// Note what woke the owner, and say what to do. A failed feed starts the
	/// backoff and is not itself a reason to sweep. A timer that returned
	/// early drops the backoff, and the owner sweeps again on the next change
	/// only, so a platform that refuses a wait cannot make the owner sweep
	/// without ever yielding. The first drop after a sweep that succeeded is
	/// reported.
	fn woke(&mut self, woke: Woke) -> Next {
		match woke {
			Woke::Changed(true) => self.feed_failed = false,
			Woke::Changed(false) => {
				self.feed_failed = true;
				self.retry.get_or_insert(FIRST_RETRY_MS);
				return Next::Wait;
			}
			Woke::Backoff { early: true } => {
				self.retry = None;
				if std::mem::replace(&mut self.dropped, true) {
					return Next::Wait;
				}
				return Next::Dropped(Error::refused(DROPPED));
			}
			Woke::Backoff { early: false } => {}
		}
		Next::Sweep
	}
	/// Note a sweep's outcome, and return its failure when it is not the one
	/// reported last.
	fn swept<'a>(&mut self, swept: &'a Result<()>) -> Option<&'a Error> {
		match swept {
			Ok(()) => {
				self.reported = None;
				self.dropped = false;
				self.retry = self.feed_failed.then(|| later(self.retry));
				None
			}
			Err(error) => {
				let text = error.to_string();
				let new = self.reported.as_deref() != Some(text.as_str());
				self.reported = Some(text);
				self.retry = Some(later(self.retry));
				new.then_some(error)
			}
		}
	}
}

/// The wait after `retry`, doubling from `FIRST_RETRY_MS` up to
/// `LAST_RETRY_MS`.
fn later(retry: Option<u64>) -> u64 {
	retry.map_or(FIRST_RETRY_MS, |wait| wait.saturating_mul(2).min(LAST_RETRY_MS))
}

/// Release every receipt waiting for adoption whose source's access is
/// revoked. A paused access may resume and adopt its result, so its receipt
/// stays. The release verb checks no revocation itself, because a content
/// callback cannot ask an access about its state, so this read is the check.
/// A receipt that fails is skipped, and the first failure is the sweep's.
async fn sweep(writer: &Writer) -> Result<()> {
	let root = writer.root()?;
	let listed = writer.idempotent("unadopted-effects", &[root.clone().into()]).await?;
	let rows = listed
		.as_list()
		.ok_or_else(|| Error::invalid("invalid unadopted receipt list"))?;
	each(rows, |row| release_if_revoked(writer, &root, row)).await
}

/// Run `release` on every row, past any that fail, and return the first
/// failure.
async fn each<'a, F: Future<Output = Result<()>>>(
	rows: &'a [Argument],
	release: impl Fn(&'a Argument) -> F,
) -> Result<()> {
	let mut failed = None;
	for row in rows {
		if let Err(error) = release(row).await {
			failed.get_or_insert(error);
		}
	}
	failed.map_or(Ok(()), Err)
}

async fn release_if_revoked(writer: &Writer, root: &Ref, row: &Argument) -> Result<()> {
	let Some([Argument::String(id), source]) = row.as_list() else {
		return Err(Error::invalid("invalid unadopted receipt row"));
	};
	let source = Ref::try_from(source).map_err(|_| Error::invalid("an unadopted receipt names no source"))?;
	let described = writer.host.send(&source, "describe-access", &[]).await?;
	if matches!(loam::UseDescription::read(&described)?, loam::UseDescription::Revoked) {
		writer
			.idempotent(
				"release-unadopted-effect",
				&[root.clone().into(), id.as_str().into(), source.into()],
			)
			.await?;
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::cell::RefCell;

	#[tokio::test]
	async fn a_sweep_goes_past_every_row_that_fails_and_keeps_the_first_failure() {
		let rows = ["a", "b", "c"].map(|row| Argument::String(row.into()));
		let seen = RefCell::new(Vec::new());
		let swept = each(&rows, |row| {
			let Argument::String(row) = row else { unreachable!() };
			seen.borrow_mut().push(row.clone());
			let failed = row != "b";
			let row = row.clone();
			async move { if failed { Err(Error::invalid(row)) } else { Ok(()) } }
		})
		.await;
		assert_eq!(*seen.borrow(), ["a", "b", "c"]);
		assert_eq!(swept.unwrap_err().to_string(), Error::invalid("a").to_string());
	}

	#[test]
	fn a_failure_is_reported_once_and_retried_on_a_doubling_backoff_up_to_its_bound() {
		let mut schedule = Schedule::default();
		assert!(matches!(schedule.woke(Woke::Changed(true)), Next::Sweep));
		let failed: Result<()> = Err(Error::invalid("full"));
		assert!(schedule.swept(&failed).is_some(), "the first failure is reported");
		assert_eq!(schedule.retry, Some(FIRST_RETRY_MS));
		for _ in 0..8 {
			assert!(matches!(schedule.woke(Woke::Backoff { early: false }), Next::Sweep));
			assert!(schedule.swept(&failed).is_none(), "the same failure is reported once");
		}
		assert_eq!(schedule.retry, Some(LAST_RETRY_MS));
		let other: Result<()> = Err(Error::invalid("other"));
		assert!(schedule.swept(&other).is_some(), "a different failure is reported");
		assert!(schedule.swept(&Ok(())).is_none());
		assert_eq!(schedule.retry, None, "a sweep that succeeds stops the backoff");
		assert!(
			schedule.swept(&failed).is_some(),
			"a failure after a success is reported again"
		);
	}

	#[test]
	fn a_timer_that_returns_early_drops_the_backoff_until_the_next_change_and_says_so_once() {
		assert!(early(1_000, 0) && early(1_000, 499));
		assert!(!early(1_000, 500) && !early(1_000, 999) && !early(1_000, 1_000));
		let mut schedule = Schedule::default();
		assert!(matches!(schedule.woke(Woke::Changed(true)), Next::Sweep));
		assert!(schedule.swept(&Err(Error::invalid("full"))).is_some());
		let Next::Dropped(error) = schedule.woke(Woke::Backoff { early: true }) else {
			panic!("a refused wait is reported, and is no reason to sweep");
		};
		assert_eq!(error.to_string(), Error::refused(DROPPED).to_string());
		assert_eq!(schedule.retry, None, "the next wake is the next change");
		assert!(matches!(schedule.woke(Woke::Changed(true)), Next::Sweep));
		assert!(
			schedule.swept(&Err(Error::invalid("full"))).is_none(),
			"the same failure stays reported"
		);
		assert!(
			matches!(schedule.woke(Woke::Backoff { early: true }), Next::Wait),
			"a drop is reported once until a sweep succeeds"
		);
		assert!(matches!(schedule.woke(Woke::Changed(true)), Next::Sweep));
		assert!(schedule.swept(&Ok(())).is_none());
		assert!(
			matches!(schedule.woke(Woke::Backoff { early: true }), Next::Dropped(_)),
			"a drop after a success is reported again"
		);
	}

	#[test]
	fn a_failed_feed_sweeps_on_the_backoff_until_it_recovers() {
		let mut schedule = Schedule::default();
		assert!(
			matches!(schedule.woke(Woke::Changed(false)), Next::Wait),
			"a failed feed is no change to sweep for"
		);
		assert_eq!(schedule.retry, Some(FIRST_RETRY_MS));
		assert!(matches!(schedule.woke(Woke::Backoff { early: false }), Next::Sweep));
		assert!(schedule.swept(&Ok(())).is_none());
		assert_eq!(schedule.retry, Some(2 * FIRST_RETRY_MS), "the feed is still down");
		assert!(matches!(schedule.woke(Woke::Changed(true)), Next::Sweep));
		assert!(schedule.swept(&Ok(())).is_none());
		assert_eq!(schedule.retry, None, "the recovered feed wakes the owner again");
	}
}
