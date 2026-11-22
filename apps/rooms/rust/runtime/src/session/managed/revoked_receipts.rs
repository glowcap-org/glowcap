//! Receipts a revoked access left. A committed receipt nobody adopted belongs
//! to the access that sent it, and only that access can adopt or release it,
//! so the replay window never evicts it. Once that access is revoked nobody
//! can, and the receipt would hold one of the session's receipt places for
//! good. This owner releases each such receipt.
//!
//! The session's change feeds start it with themselves and close it with
//! themselves, so every host that opens a session runs it. It sweeps once at
//! start and again on every session change. A revocation changes the grant
//! inventory, and a receipt settled after its access was revoked changes
//! content, so both wake it. A sweep makes one private read of the receipts
//! waiting to be adopted, and one local access description per waiting
//! receipt.
//!
//! A failure goes to the session's failure owner, as `Revoked receipt
//! release`, once until a sweep succeeds or a different failure follows. A
//! failed feed restarts only on an explicit retry, as it does for every other
//! consumer, so this owner waits for the next change it publishes.
use super::{Membership, changes::Wake, executor::Writer, supervision};
use crate::Error;
use glowcap::{Argument, Ref, loam};
use rooms_glowcap::client::{Deadline, Tasks};
use std::rc::Rc;

type Result<T> = core::result::Result<T, Error>;

/// Start the owner in the feeds' own budget, which closes it with them.
pub(super) fn spawn<P: Tasks + Deadline + Clone + 'static>(
	platform: &P,
	budget: &Rc<supervision::Budget<P>>,
	writer: Rc<Writer>,
	mut wake: Wake,
) -> Membership<P> {
	supervision::spawn(
		platform,
		budget,
		"revoked-receipt-release".into(),
		None,
		move |mut signals| async move {
			signals.ready.send_replace(Some(Ok(())));
			let mut reported: Option<String> = None;
			loop {
				if *signals.stopping.borrow_and_update() {
					return Ok(());
				}
				let woke = tokio::select! {
					biased;
					_ = signals.stopping.changed() => return Ok(()),
					changed = wake.changed() => changed,
				};
				let swept = match woke {
					Ok(()) => tokio::select! {
						biased;
						_ = signals.stopping.changed() => return Ok(()),
						swept = sweep(&writer) => swept,
					},
					Err(error) => Err(error),
				};
				match swept {
					Ok(()) => reported = None,
					Err(error) => {
						let text = error.to_string();
						if reported.as_deref() != Some(text.as_str()) {
							writer.report("Revoked receipt release", &error);
							reported = Some(text);
						}
					}
				}
			}
		},
	)
}

/// Release every receipt waiting for adoption whose source's access is
/// revoked. A paused access may resume and adopt its result, so its receipt
/// stays. The release verb checks no revocation itself, because a content
/// callback cannot ask an access about its state, so this read is the check.
async fn sweep(writer: &Writer) -> Result<()> {
	let root = writer.root()?;
	let listed = writer.idempotent("unadopted-effects", &[root.clone().into()]).await?;
	let rows = listed
		.as_list()
		.ok_or_else(|| Error::invalid("invalid unadopted receipt list"))?;
	for row in rows {
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
	}
	Ok(())
}
