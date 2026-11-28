//! Moving a bot to a replacement link. The old link settles each line,
//! direct-message open, and agent's action it sent before the new link
//! serves. A line it could not settle stays as the old access recorded it, and
//! the new link decides it as `serve/access.rs` describes. An action it could
//! not settle is recorded in the ledger, which `status.replaced_actions`
//! counts, because only revoking the old access frees its place. A paused old
//! access cannot list, and one the session no longer holds says nothing of the
//! receipts it gave back. Once the new link is stored
//! `status.replaced_unlisted` says `paused` or `denied`.
//!
//! The new link is saved only after this settling, so a replacement that stops
//! before the save leaves the old link stored, and running it again finishes
//! it. This module owns that order: the old access settles its lines and opens
//! within one [`REPLACE_LIMIT`], then lists the agent's actions it holds,
//! then the start serves with the new link. Only the old access can list its
//! actions, so a list that fails refuses the replacement, unless that access is
//! revoked, paused, or no longer held by the session. The line loop is
//! `engine/settle_old.rs`, and
//! which access sent what is `serve/access.rs`.
use super::access;
use crate::bot::{
	engine::{self, Core, Publishing},
	error::{Error, LinkStage},
	ledger::{Ledger, TurnId, Unlisted},
	link::Link,
	opens::{self, action},
	rooms::{Rooms, captp},
	status::Facts,
	store::Store,
	words::OLD_ACCESS_STOPPED,
};
use std::{cell::RefCell, collections::BTreeSet, time::Duration};
use tokio::{
	sync::watch,
	time::{Instant, sleep_until, timeout_at},
};

/// How long the old access gets to settle what it sent.
pub const REPLACE_LIMIT: Duration = Duration::from_secs(60);

/// What the old access left: the ledger it settled, how many lines are left
/// unconfirmed in all, for `status` to count, and why its last list could not
/// list the agent's actions, which the start records once it stores the new
/// link.
pub struct OldSettled {
	pub ledger: Ledger,
	pub unconfirmed: u64,
	pub unlisted: Option<Unlisted>,
}

/// Let the old access settle the lines and the direct-message
/// opens it sent, within one [`REPLACE_LIMIT`], or nothing when the bot has no
/// ledger yet.
pub async fn replace_link(
	old: Link,
	store: &Store,
	shutdown: &watch::Receiver<bool>,
) -> Result<Option<OldSettled>, Error> {
	let Some(ledger) = Ledger::load(store)? else {
		return Ok(None);
	};
	let grant = old.fingerprint();
	let rooms = captp::Attached::open(store, old)?;
	let ends = Instant::now() + REPLACE_LIMIT;
	let settled = settle_old_access(&rooms, store, ledger, shutdown, ends).await;
	if settled.is_ok() && !*shutdown.borrow() {
		let cleanup = crate::bot::reminders::settle_receipts(store.root(), &rooms, &grant);
		if let Ok(Err(error)) = timeout_at(ends, cleanup).await {
			rooms.close().await;
			return Err(error);
		}
	}
	rooms.close().await;
	settled.map(Some)
}

/// The old access's settling through `rooms`. It first asks the session which
/// of what is left it sent, and settles only those, so it never sends again
/// a line another access holds. The access ending, or the limit, leaves what
/// is left to the new link. Unless a stop came, its last list follows, and a
/// list that fails is this function's error.
pub async fn settle_old_access<R: Rooms>(
	rooms: &R,
	store: &Store,
	ledger: Ledger,
	shutdown: &watch::Receiver<bool>,
	ends: Instant,
) -> Result<OldSettled, Error> {
	let mut leftovers = match ask_old_access(rooms, store, &ledger, shutdown, ends).await? {
		Old::Asked(leftovers) => leftovers,
		Old::Unasked => {
			let ledger = RefCell::new(ledger);
			let unlisted = last_list(rooms, store, &ledger, shutdown).await?;
			return Ok(OldSettled {
				ledger: ledger.into_inner(),
				unconfirmed: 0,
				unlisted,
			});
		}
	};
	let foreign = leftovers.foreign();
	let core = Core::new(
		rooms,
		store,
		ledger,
		Facts::default(),
		leftovers.take_by_echo(),
		Publishing::Nowhere,
	);
	let unconfirmed = engine::settle_old_lines(&core, shutdown, ends).await?;
	// A note whose turn still runs is that turn's to settle, under the new
	// link once it serves.
	let turns = core.ledger.borrow().running().into_iter().collect();
	last_look(rooms, store, foreign, &turns, shutdown, ends).await?;
	let unlisted = last_list(rooms, store, &core.ledger, shutdown).await?;
	Ok(OldSettled {
		ledger: core.ledger.into_inner(),
		unconfirmed,
		unlisted,
	})
}

/// What asking the old access came to.
enum Old {
	/// The session said which of what is left the old access sent.
	Asked(access::Leftovers),
	/// The old access stopped working, a stop came first, or the limit ran
	/// out before the session answered, so it settles no line or open.
	Unasked,
}

/// What the session says the old access sent. The log says when the access
/// stopped working or the limit ran out.
async fn ask_old_access<R: Rooms>(
	rooms: &R,
	store: &Store,
	ledger: &Ledger,
	shutdown: &watch::Receiver<bool>,
	ends: Instant,
) -> Result<Old, Error> {
	let asked = timeout_at(
		ends,
		access::ask(
			rooms,
			store,
			ledger,
			LinkStage::Replacing,
			access::Paused::Leave,
			shutdown,
		),
	)
	.await;
	match asked {
		Ok(Ok(Some(leftovers))) => Ok(Old::Asked(leftovers)),
		Ok(Ok(None)) => Ok(Old::Unasked),
		Ok(Err(Error::Access { cause, .. })) => {
			store.log(&format!(
				"{OLD_ACCESS_STOPPED} ({cause}), so it settles no line or open before the new link serves"
			));
			Ok(Old::Unasked)
		}
		Ok(Err(error)) => Err(error),
		Err(_) => {
			store.log("the old access ran out of time before the session said which receipts are its own");
			Ok(Old::Unasked)
		}
	}
}

/// The old access's last look at the opens it sent outside `turns`, the turns
/// still open in the ledger, until `ends`.
async fn last_look<R: Rooms>(
	rooms: &R,
	store: &Store,
	foreign: BTreeSet<String>,
	turns: &BTreeSet<TurnId>,
	shutdown: &watch::Receiver<bool>,
	ends: Instant,
) -> Result<(), Error> {
	let mut stop = shutdown.clone();
	let mut waiting = Default::default();
	let last = opens::Pass::Last { foreign };
	tokio::select! {
		biased;
		() = engine::stopping(&mut stop) => Ok(()),
		() = sleep_until(ends) => {
			store.log(
				"the old access's last look at its direct-message opens ran out of time, so the rest stay with the old access",
			);
			Ok(())
		}
		looked = opens::look(rooms, store, &last, turns, &mut waiting) => looked.map(drop),
	}
}

/// The old access's last list of the agent's actions it holds, past the limit
/// because no later serve lists through it. Each request is bounded by its
/// own deadline. The actions it could not settle are recorded in `ledger`,
/// and why it could not list is returned for the start to record with the
/// new link. A stop records nothing, and the start ends before it stores the
/// new link.
async fn last_list<R: Rooms>(
	rooms: &R,
	store: &Store,
	ledger: &RefCell<Ledger>,
	shutdown: &watch::Receiver<bool>,
) -> Result<Option<Unlisted>, Error> {
	let mut stop = shutdown.clone();
	let snapshot = ledger.borrow().clone();
	let listed = tokio::select! {
		biased;
		() = engine::stopping(&mut stop) => return Ok(None),
		listed = action::last(rooms, store, &snapshot) => listed?,
	};
	let (left, unlisted) = match listed {
		action::LastList::Left(left) => (left, None),
		action::LastList::Unlisted(why) => (Vec::new(), Some(why)),
	};
	if !left.is_empty() {
		store.log(&format!(
			"the old access could not settle {} of its agent's actions, which hold places in the session until it is revoked",
			left.len()
		));
	}
	ledger.borrow_mut().replace_actions(store, &left)?;
	Ok(unlisted)
}

#[cfg(test)]
#[cfg(feature = "test-support")]
mod tests;
