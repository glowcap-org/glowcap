//! What the session's answers about one receipt mean to the bot, decided once
//! for a reply line this access sent (`deliver.rs`), a replaced line it holds
//! again (`replaced.rs`), a `--dm` open (`opens.rs`), and an agent's action
//! (`opens/action.rs`).
//!
//! A receipt is the session's record of one request. The session runs each
//! request in an executor, which settles the receipt or, when one of its
//! observations misses the session's deadline, stops and pauses. Only the
//! access that sent a request can resume its paused executor, and the bot
//! never does. Giving a receipt back (`release-effect`) answers like this:
//!
//! | Executor | `effect-status` | `release-effect` |
//! | --- | --- | --- |
//! | running | pending | running, and the session changes nothing |
//! | filling | pending | running, until the fill ends |
//! | paused | unknown | released: the session retires the executor and settles the receipt unknown |
//! | none | the receipt's outcome | released |
//!
//! A released receipt frees its place, and the session keeps it, answering
//! for its operation, until newer receipts push it out.
//!
//! The bot's rule follows:
//!
//! - A release answered running is asked again after a wait. Every executor
//!   run settles, pauses, or stops within the session's running bound
//!   (`RUNNING_BOUND_MS` in the Rooms application's `effects.rs`), archive
//!   shares and bridges included, and only a resume, which the bot never
//!   sends, starts another run. The one longer run is a room upload filling
//!   its files after its post is acknowledged: it settles when its fill ends,
//!   and no path of the bot releases such a receipt, because the verb that
//!   posted it waits for it and the serving loop's list asks `settle`, which
//!   gives a running receipt back only when it cannot settle (`opens/action.rs`).
//!   A receipt still running past the bound is therefore treated as one the
//!   session refused, and the caller counts it.
//! - A release the session refuses, for a request that no longer matches its
//!   receipt, ends the asking: the receipt stays with the session, and the
//!   caller logs it. A line's receipt that a look then finds committed,
//!   still running, or unknown may hold one of the session's places, so the
//!   ledger records it once (`Ledger::leave`) before the caller saves its own
//!   record of the line, and `status.unreleased_lines` counts the records.
//!   The serving loop's list of the receipts this access holds
//!   (`opens/action.rs`) is the authority: it drops each record whose
//!   receipt it does not name. A paused executor's receipt reads unknown,
//!   holds its place, and is listed until released, and a released one
//!   holds none. A receipt gone or unsent, or one the look cannot read, is
//!   not recorded.
use super::pace::within;
use crate::bot::{
	engine::Core,
	rooms::{Base, Handback, Outcome, Outgoing, Rooms, RoomsError, RoomsErrorKind, SEND_DEADLINE},
	words::{RECEIPT_LEFT, REFUSED_LOOK},
};
use rooms_application::content::session::effects::RUNNING_BOUND_MS;
use rooms_services::session::attached::Introduction;
use std::time::Duration;
use tokio::time::Instant;

/// One receipt this access holds with the session.
#[derive(Clone, Copy)]
pub(crate) enum Receipt<'a> {
	/// A line sent at its base.
	Line(&'a Outgoing<'a>, Base),
	Open {
		operation: &'a str,
		introduction: &'a Introduction,
		base: Base,
	},
	/// An agent's action, which the session names by its operation alone.
	Action { operation: &'a str },
}

impl Receipt<'_> {
	async fn hand_back<R: Rooms>(self, rooms: &R) -> Result<Handback, RoomsError> {
		match self {
			Self::Line(line, base) => rooms.release(line, base).await,
			Self::Open {
				operation,
				introduction,
				base,
			} => rooms.release_open(operation, base, introduction).await,
			Self::Action { operation } => rooms.release_action(operation).await,
		}
	}
}

/// What giving a receipt back came to.
pub(crate) enum Given {
	/// The session holds no receipt now.
	Back,
	/// The session refused to take the receipt back. It stays with the session,
	/// and the caller counts it.
	Left(RoomsError),
	/// The session's executor still runs the request. The caller asks again
	/// after a wait.
	Running,
	/// The call did not settle, and the caller asks again after a wait.
	Failed(RoomsError),
}

/// When the session first answered that one receipt's executor runs, so the
/// asking stops at the session's running bound.
#[derive(Default)]
pub(crate) struct Running(Option<Instant>);

impl Running {
	/// Whether a receipt that answered running may be asked about again.
	fn within_bound(&mut self) -> bool {
		self.0.get_or_insert_with(Instant::now).elapsed() < Duration::from_millis(RUNNING_BOUND_MS)
	}
}

/// Give `receipt` back to the session. `running` remembers when it first
/// answered running, and past the session's running bound that answer is a
/// refusal.
pub(crate) async fn give_back<R: Rooms>(rooms: &R, receipt: Receipt<'_>, running: &mut Running) -> Given {
	match within(SEND_DEADLINE, receipt.hand_back(rooms)).await {
		Ok(Handback::Taken) => Given::Back,
		Ok(Handback::Running) if running.within_bound() => Given::Running,
		Ok(Handback::Running) => Given::Left(RoomsError::new(
			RoomsErrorKind::Refused,
			format!("its executor still runs after the session's bound of {RUNNING_BOUND_MS} ms"),
		)),
		Err(error) if error.kind == RoomsErrorKind::Refused => Given::Left(error),
		Err(error) => Given::Failed(error),
	}
}

/// What a look at an operation came to.
pub(super) enum Look {
	Seen(Outcome),
	/// The session refused the look itself, which is logged. Waiting or asking
	/// again does not change that answer, and the line may have posted, so the
	/// line is given up on and never replaced.
	Refused,
	/// The look did not answer or may be asked again.
	Failed(RoomsError),
}

/// Look at `line`'s operation. The session answers a look at a receipt it
/// does not hold with `Absent`, and `rooms/captp/map.rs::observed` reads every
/// refusal that waiting will not clear that way. A look still refused is
/// logged and given up on as unconfirmed ([`Look::Refused`]), because the same
/// call was prepared and sent before and no later look would answer
/// differently.
pub(super) async fn look<R: Rooms>(env: &Core<'_, R>, line: &Outgoing<'_>, base: Base) -> Look {
	match within(SEND_DEADLINE, env.rooms.observe(line, base)).await {
		Ok(outcome) => Look::Seen(outcome),
		Err(error) if error.kind == RoomsErrorKind::Refused => {
			env.store.log(&format!("{REFUSED_LOOK} {}: {error}", line.operation));
			Look::Refused
		}
		Err(error) => Look::Failed(error),
	}
}

/// Record a line's receipt the session refused to take back in the ledger
/// when a look finds it still holds a place. A look that does not answer
/// fails, and the caller asks again.
pub(super) async fn leave<R: Rooms>(env: &Core<'_, R>, line: &Outgoing<'_>, base: Base) -> Result<(), Left> {
	match look(env, line, base).await {
		// An unknown receipt may be a paused executor's, which holds its
		// place, so it is recorded too, and the serving loop's next list of
		// held receipts drops the record if it holds none.
		Look::Seen(Outcome::Committed | Outcome::Pending | Outcome::Unknown) => env
			.ledger
			.borrow_mut()
			.leave(env.store, line.operation)
			.map_err(Left::Saving),
		Look::Seen(Outcome::Absent | Outcome::Conflict) | Look::Refused => Ok(()),
		Look::Failed(error) => Err(Left::Looking(error)),
	}
}

/// Why a refused receipt could not be recorded yet.
pub(super) enum Left {
	Looking(RoomsError),
	Saving(crate::bot::error::Error),
}

/// Log a receipt of `operation` the session refused to take back, once the
/// caller has saved what it decided about the line or open, and publish the
/// count the ledger holds.
pub(super) fn left<R: Rooms>(env: &Core<'_, R>, operation: &str, error: &RoomsError) {
	env.store.log(&format!("{RECEIPT_LEFT} {operation}: {error}"));
	env.publish();
}
