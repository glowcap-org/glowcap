//! The old access's line loop: settle each line the old access sent, one at a
//! time, until the replacement's deadline, a stop, or the old access ending.
//! A line left over stays as the old access recorded it.
use super::{Core, deliver, stopping};
use crate::bot::{error::Error, rooms::Rooms, words::OLD_ACCESS_STOPPED};
use tokio::{
	sync::watch,
	time::{Instant, sleep_until},
};

const REPLACEMENT_LATE: &str = "the replacement ran out of time";

/// Settle every line the old access sent and has not settled, until `ends`,
/// which the replacement fixes when it begins (`serve/replace.rs`). The old access
/// stopping or the limit leaves the rest to the new link without calling the
/// session again, and the log says why each was left. A stop leaves every
/// line still open as it is, for the old link to settle when the replacement
/// runs again. Returns how many lines are left unconfirmed in all, for
/// `status` to count.
pub async fn settle_old_lines<R: Rooms>(
	env: &Core<'_, R>,
	shutdown: &watch::Receiver<bool>,
	ends: Instant,
) -> Result<u64, Error> {
	let mut stop = shutdown.clone();
	let mut shutdown = shutdown.clone();
	let mut cut: Option<&'static str> = None;
	let open = env.ledger.borrow().open();
	for id in open {
		if !deliver::sent_unsettled(env, id) {
			continue;
		}
		let why = match cut {
			Some(why) => why,
			// `settle_sent` returns once the line is settled, so only a stop,
			// a halt, or the limit leaves a line for the new link.
			None => tokio::select! {
				biased;
				() = stopping(&mut shutdown) => return Ok(env.facts.borrow().unconfirmed),
				() = env.halted.notified() => OLD_ACCESS_STOPPED,
				() = sleep_until(ends) => REPLACEMENT_LATE,
				step = deliver::settle_sent(env, id, &mut stop) => {
					step?;
					continue;
				}
			},
		};
		cut = Some(why);
		env.store.log(&format!(
			"turn {}: {why}, so a line it sent is not settled before the new link serves. A new link settles it by its echo, and \
			 sends it again only when the session holds no receipt of it and a complete read shows no echo",
			id.0
		));
	}
	Ok(env.facts.borrow().unconfirmed)
}
