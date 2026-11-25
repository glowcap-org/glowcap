//! Which access sent what a start did not write. The session keeps a receipt
//! under the access that sent an operation, so it alone knows whether the
//! serving access is that one: a link to the same access in another form, or
//! back to an earlier link that was never revoked, serves what that access
//! sent. Only that access can keep or release a receipt, so another access's
//! line is never sent again and its receipt stays with it until it is revoked
//! (`rooms-runtime`'s `revoked_receipts.rs` says why).
//!
//! A start asks the session once about every direct-message note in `opens/`,
//! every reply line already sent, and every replaced line and replaced action
//! the ledger records (`ledger/replaced.rs`), none of which this start wrote. The answers are
//! held in memory until the link is stored, so a stop before the save writes
//! nothing. Then each note and record is placed and each line decided by
//! them, and a start that stopped between the two asks again. A line another
//! access sent is settled by its echo alone and recorded as replaced. One the
//! session holds no receipt of is settled as any line is, by its echo, and
//! sent again only when a complete read of activity shows none.
use crate::bot::{
	engine::{self, Backoff},
	error::{Error, LinkStage},
	fault::{self, Fail},
	ledger::{Ledger, Replaced},
	opens::{self, Unplaced},
	rooms::{Holder, Rooms, RoomsError, RoomsErrorKind},
	status::{Activity, Facts},
	store::Store,
	words,
};
use std::{collections::BTreeSet, time::Duration};
use tokio::sync::watch;

/// What an ask does when the access it asks through is paused, and what it
/// tells `bot status` while it waits.
pub enum Paused<'a> {
	/// Ask again until it resumes, as the serving link does. The serving
	/// process's facts, which the ask publishes as the session answers.
	Wait(&'a mut Facts),
	/// End the ask, as the old access's courtesy look does: it would wait
	/// past its bound for an access its owner may never resume. The old
	/// access's answers are no fact of the serving link, so nothing is
	/// published.
	Leave,
}

/// The session's answers about what a start did not write.
#[derive(Default)]
pub struct Leftovers {
	notes: Vec<(Unplaced, Holder)>,
	/// The operations of lines the session says another access sent.
	by_echo: BTreeSet<String>,
	/// The replaced lines whose receipts this access holds again.
	mine: Vec<Replaced>,
	/// The operations of replaced lines the session holds no receipt of.
	gone: BTreeSet<String>,
	/// The operations of replaced actions no other access holds now: this
	/// access holds them again, and its list of held receipts settles them,
	/// or nobody does.
	actions_back: BTreeSet<String>,
}

impl Leftovers {
	/// The lines another access holds the receipt of, which only their echo
	/// settles.
	pub fn take_by_echo(&mut self) -> BTreeSet<String> {
		std::mem::take(&mut self.by_echo)
	}

	/// The replaced lines this access holds the receipts of again, which it
	/// keeps or releases.
	pub fn take_mine(&mut self) -> Vec<Replaced> {
		std::mem::take(&mut self.mine)
	}

	/// The notes this access did not send, which a look of its own leaves
	/// alone.
	pub fn foreign(&self) -> BTreeSet<String> {
		self.notes
			.iter()
			.filter(|(_, holder)| *holder != Holder::Mine)
			.map(|(note, _)| note.operation().to_owned())
			.collect()
	}

	/// Put every note where its answer says it belongs, and drop the records
	/// of replaced lines nobody holds and of replaced actions no other access
	/// holds. Each step is safe to repeat, so a failure is tried again.
	pub fn place(&self, store: &Store, ledger: &mut Ledger) -> Result<(), Error> {
		for (note, holder) in &self.notes {
			note.place(store, *holder)?;
		}
		ledger.drop_replaced(store, &self.gone)?;
		ledger.drop_replaced_actions(store, &self.actions_back)
	}
}

/// Ask the session, through `rooms`, whose receipt each note and sent line is.
/// A failed ask that time can clear is asked again on a backoff, and nothing
/// is stored meanwhile. `None` means a stop came first.
pub async fn ask<R: Rooms>(
	rooms: &R,
	store: &Store,
	ledger: &Ledger,
	stage: LinkStage,
	paused: Paused<'_>,
	shutdown: &watch::Receiver<bool>,
) -> Result<Option<Leftovers>, Error> {
	let mut asking = Asking {
		rooms,
		store,
		stage,
		paused,
		stop: shutdown.clone(),
		wait: Backoff::standard(),
	};
	let mut found = Leftovers::default();
	for note in opens::unplaced(store.root())? {
		let Some(holder) = asking.whose(note.operation()).await? else {
			return Ok(None);
		};
		found.notes.push((note, holder));
	}
	for operation in ledger.sent() {
		let Some(holder) = asking.whose(&operation).await? else {
			return Ok(None);
		};
		// Another access's receipt may still land, so this access never sends
		// that line again and only its echo settles it. A receipt the session
		// released still answers for its sender, so a line the old access sent
		// lands here even after a sweep gave its receipt back. Nobody means the
		// line was never sent or its receipt left the session's bounded replay
		// window, so the line is decided as any line is: a complete read of
		// activity showing no echo is the evidence that it may be sent.
		if holder == Holder::Another {
			found.by_echo.insert(operation);
		}
	}
	for line in ledger.replaced() {
		let Some(holder) = asking.whose(&line.operation).await? else {
			return Ok(None);
		};
		match holder {
			Holder::Mine => found.mine.push(line.clone()),
			Holder::Nobody => {
				found.gone.insert(line.operation.clone());
			}
			Holder::Another => {}
		}
	}
	for operation in ledger.replaced_actions() {
		let Some(holder) = asking.whose(operation).await? else {
			return Ok(None);
		};
		if holder != Holder::Another {
			found.actions_back.insert(operation.clone());
		}
	}
	Ok(Some(found))
}

struct Asking<'a, R: Rooms> {
	rooms: &'a R,
	store: &'a Store,
	stage: LinkStage,
	paused: Paused<'a>,
	stop: watch::Receiver<bool>,
	wait: Backoff,
}

impl<R: Rooms> Asking<'_, R> {
	/// Whose receipt `operation` is, asked again until the session answers.
	async fn whose(&mut self, operation: &str) -> Result<Option<Holder>, Error> {
		loop {
			match ask_once(self.rooms, operation).await {
				Ok(holder) => return Ok(Some(holder)),
				Err(error) if error.kind == RoomsErrorKind::Refused => return Err(Error::Asked(error.to_string())),
				Err(error)
					if engine::ends_serving(error.kind)
						|| (matches!(self.paused, Paused::Leave) && error.kind == RoomsErrorKind::Paused) =>
				{
					return Err(Error::access_ended(self.stage, error.to_string()));
				}
				Err(error) => {
					self.store.log(&format!(
						"asking the session whose receipt operation {operation} is {}: {error}",
						words::TRYING_AGAIN
					));
					if let Paused::Wait(facts) = &mut self.paused {
						// The ask has not reached the serving loop, so the
						// status says what this process knows of its access.
						if let Some(access) = engine::access_of(error.kind) {
							facts.access = access;
						}
						facts.failed(Activity::Receiving, &error);
						facts.publish(self.store);
					}
					let delay = error.retry_after.unwrap_or(Duration::ZERO).max(self.wait.next());
					if !engine::waited(delay, &mut self.stop).await {
						return Ok(None);
					}
				}
			}
		}
	}
}

async fn ask_once<R: Rooms>(rooms: &R, operation: &str) -> Result<Holder, RoomsError> {
	if fault::fails(Fail::HolderLook) {
		return Err(RoomsError::new(
			RoomsErrorKind::Unreachable,
			"a fault made the ask fail",
		));
	}
	if fault::fails(Fail::HolderRefused) {
		return Err(RoomsError::new(RoomsErrorKind::Refused, words::ASK_REFUSED_FAULT));
	}
	if fault::fails(Fail::HolderAnother) {
		return Ok(Holder::Another);
	}
	rooms.holder(operation).await
}

#[cfg(test)]
mod tests;
