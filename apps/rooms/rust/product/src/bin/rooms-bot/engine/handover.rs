//! Moving a bot to a replacement link. The receipts of lines the old access
//! sent belong to it, and only it can keep or release them, so the old link
//! settles each such line before the new link serves. A line it could not
//! settle is left to the new link, which decides it by its echo alone and
//! never sends it again. Its receipt stays with the session until the old
//! access is revoked, and the session then releases it.
use super::{
	Env,
	deliver::{self, Handed},
	stopping,
};
use crate::bot::{error::Error, rooms::Rooms};
use std::time::Duration;
use tokio::{
	sync::watch,
	time::{Instant, sleep_until},
};

/// How long the old access gets to settle the lines it sent.
pub const HANDOVER_LIMIT: Duration = Duration::from_secs(60);

const HALTED: &str = "the old access stopped working";
const LATE: &str = "the hand-over ran out of time";

/// Settle every line the old access sent and has not settled, within
/// [`HANDOVER_LIMIT`]. The old access stopping or the limit leaves the rest
/// to the new link without calling the session again, and the log says what
/// became of each line. A stop leaves every line still open as it is, for
/// the old link to settle when the hand-over runs again. Returns how many
/// lines were given up on, for `status` to count.
pub async fn hand_over<R: Rooms>(env: &Env<'_, R>, shutdown: &watch::Receiver<bool>) -> Result<u64, Error> {
	let ends = Instant::now() + HANDOVER_LIMIT;
	let (_never, mut stop) = watch::channel(false);
	let mut shutdown = shutdown.clone();
	let mut cut: Option<&str> = None;
	let open = env.ledger.borrow().open();
	for id in open {
		if !deliver::sent_unsettled(env, id) {
			continue;
		}
		let why = match cut {
			Some(why) => why,
			// `settle_sent` returns once the line is settled, so only a stop,
			// a halt, or the limit leaves a line to hand over.
			None => tokio::select! {
				biased;
				() = stopping(&mut shutdown) => return Ok(env.facts.borrow().unconfirmed),
				() = env.halted.notified() => HALTED,
				() = sleep_until(ends) => LATE,
				step = deliver::settle_sent(env, id, &mut stop) => {
					step?;
					continue;
				}
			},
		};
		cut = Some(why);
		if let Some(said) = said(&deliver::hand(env, id, why)?) {
			env.store.log(&format!("turn {}: {said}", id.0));
		}
	}
	Ok(env.facts.borrow().unconfirmed)
}

/// The log line for what `hand` did, before the new link takes over.
fn said(handed: &Handed) -> Option<String> {
	const REVOKED: &str = "The session releases its receipt once the old access is revoked";
	Some(match handed {
		Handed::Nothing => return None,
		Handed::ToEcho { operation } => format!(
			"the old access had not settled operation {operation}. The new link decides it by its echo and never \
			 sends it again. {REVOKED}"
		),
		Handed::Held { operation, why } => {
			format!("the old access left the receipt of operation {operation}, because {why}. {REVOKED}")
		}
	})
}
