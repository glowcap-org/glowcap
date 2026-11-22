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
			let mut reported: Option<String> = None;
			// The wait before the next sweep a failure asks for, if any, and
			// whether the feed that wakes this owner has failed.
			let mut retry: Option<u64> = None;
			let mut feed_failed = false;
			loop {
				if *signals.stopping.borrow_and_update() {
					return Ok(());
				}
				let backoff = async {
					match retry {
						Some(wait) => timer.within(wait, core::future::pending::<()>()).await,
						None => core::future::pending().await,
					}
				};
				let woke = tokio::select! {
					biased;
					_ = signals.stopping.changed() => return Ok(()),
					changed = wake.changed() => Some(changed.is_ok()),
					_ = backoff => None,
				};
				match woke {
					Some(true) => feed_failed = false,
					// The feed reported its own failure. Sweep on the backoff
					// until it recovers.
					Some(false) => {
						feed_failed = true;
						retry.get_or_insert(FIRST_RETRY_MS);
						continue;
					}
					None => {}
				}
				let swept = tokio::select! {
					biased;
					_ = signals.stopping.changed() => return Ok(()),
					swept = sweep(&writer) => swept,
				};
				match swept {
					Ok(()) => {
						reported = None;
						retry = feed_failed.then(|| later(retry));
					}
					Err(error) => {
						let text = error.to_string();
						if reported.as_deref() != Some(text.as_str()) {
							writer.report("Revoked receipt release", &error);
							reported = Some(text);
						}
						retry = Some(later(retry));
					}
				}
			}
		},
	)
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
	let mut failed = None;
	for row in rows {
		if let Err(error) = release_if_revoked(writer, &root, row).await {
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
