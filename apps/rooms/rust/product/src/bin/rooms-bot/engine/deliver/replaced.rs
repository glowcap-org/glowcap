//! What a start does with the replaced lines whose receipts it finds this
//! access holds again (`ledger/replaced.rs`): the line was finished by its
//! echo while another access served, and this access is serving once more.
//! Each receipt is kept or released the way a line of this access's own is,
//! and the record is dropped once the session has taken it.
//!
//! The session's own state decides which: a receipt that committed is kept,
//! one that is still running is looked at again, and one that settled
//! without committing is released. A keep the session refuses releases the
//! receipt instead, and a release it keeps refusing leaves the receipt with
//! the session and the log says so. Every step is safe to repeat, so a stop
//! at any point finishes at the next start, which asks the session again.
use super::{
	pace::within,
	receipt::{self, Given, Left, Look, Receipt, Running},
};
use crate::bot::{
	engine::{Backoff, Core, Env},
	ledger::Replaced,
	rooms::{Base, Outcome, Outgoing, Rooms, RoomsError, RoomsErrorKind, SEND_DEADLINE},
	status::Activity,
	words::{LINE_KEPT, LINE_RELEASED, NOT_KEPT},
};
use std::{collections::BTreeSet, convert::Infallible, future::pending, time::Duration};
use tokio::time::sleep;

/// Settle each of `lines`, once the link is reached, and then wait forever
/// beside the serving loop, which ends it.
pub async fn settle<R: Rooms>(env: &Env<'_, R>, lines: Vec<Replaced>) -> Infallible {
	env.until_linked().await;
	for line in lines {
		let mut wait = Backoff::standard();
		let mut running = Running::default();
		while let Some(after) = step(env, &line, &mut wait, &mut running).await {
			sleep(after).await;
		}
	}
	pending().await
}

/// How a replaced line's record is spent: its receipt is settled, or the
/// session keeps it and it is logged once the record is dropped. A receipt
/// still holding a place is in the ledger before then (`receipt::leave`).
enum Spent {
	Settled,
	/// The session refused the look or the release, and the error, when there
	/// is one, says why. A refused look is logged where it is read, and its
	/// receipt is not counted, because nothing says whether it holds a place.
	Left(Option<RoomsError>),
}

/// What one call for a replaced line came to.
enum Stepped {
	Wait(Duration),
	Spent(Spent),
}

/// One call for `line`, and how long to wait before the next, or none once
/// the record is dropped.
async fn step<R: Rooms>(
	env: &Core<'_, R>,
	line: &Replaced,
	wait: &mut Backoff,
	running: &mut Running,
) -> Option<Duration> {
	let outgoing = Outgoing {
		conversation: &line.conversation,
		text: &line.text,
		operation: &line.operation,
	};
	let said = |what: &str| env.store.log(&format!("operation {} {what}", line.operation));
	let stepped = match receipt::look(env, &outgoing, line.base).await {
		Look::Seen(Outcome::Pending) => Stepped::Wait(wait.next()),
		Look::Seen(Outcome::Committed) => match within(SEND_DEADLINE, env.rooms.keep(&outgoing, line.base)).await {
			Ok(()) => {
				said(LINE_KEPT);
				Stepped::Spent(Spent::Settled)
			}
			Err(error) if error.kind == RoomsErrorKind::Refused => {
				said(&format!("posted, but {NOT_KEPT}: {error}. Releasing its receipt"));
				release(env, &outgoing, line.base, wait, running, &said).await
			}
			Err(error) => Stepped::Wait(failed(env, &error, wait)),
		},
		Look::Seen(Outcome::Unknown | Outcome::Conflict) => {
			release(env, &outgoing, line.base, wait, running, &said).await
		}
		Look::Seen(Outcome::Absent) => {
			said("has no receipt in the session any more");
			Stepped::Spent(Spent::Settled)
		}
		// The receipt is left as it is, and asking again would not change the
		// look's answer, which `receipt::look` logged.
		Look::Refused => Stepped::Spent(Spent::Left(None)),
		Look::Failed(error) => Stepped::Wait(failed(env, &error, wait)),
	};
	let spent = match stepped {
		Stepped::Wait(after) => return Some(after),
		Stepped::Spent(spent) => spent,
	};
	// The session has taken the receipt or holds none, so the record is spent.
	let operations = BTreeSet::from([line.operation.clone()]);
	let dropped = env.ledger.borrow_mut().drop_replaced(env.store, &operations);
	if let Err(error) = dropped {
		env.store.log(&format!(
			"dropping the record of operation {}: {error}. Trying again",
			line.operation
		));
		env.facts.borrow_mut().failed(Activity::Saving, &error);
		env.publish();
		return Some(wait.next());
	}
	env.facts.borrow_mut().recovered(Activity::Saving);
	match spent {
		Spent::Settled => env.publish(),
		Spent::Left(Some(error)) => receipt::left(env, &line.operation, &error),
		Spent::Left(None) => env.publish(),
	}
	None
}

async fn release<R: Rooms>(
	env: &Core<'_, R>,
	outgoing: &Outgoing<'_>,
	base: Base,
	wait: &mut Backoff,
	running: &mut Running,
	said: &impl Fn(&str),
) -> Stepped {
	match receipt::give_back(env.rooms, Receipt::Line(outgoing, base), running).await {
		Given::Back => {
			said(LINE_RELEASED);
			Stepped::Spent(Spent::Settled)
		}
		Given::Left(error) => match receipt::leave(env, outgoing, base).await {
			Ok(()) => Stepped::Spent(Spent::Left(Some(error))),
			Err(Left::Looking(error)) => Stepped::Wait(failed(env, &error, wait)),
			Err(Left::Saving(error)) => {
				env.store.log(&format!(
					"recording the receipt of operation {} left: {error}. Trying again",
					outgoing.operation
				));
				env.facts.borrow_mut().failed(Activity::Saving, &error);
				env.publish();
				Stepped::Wait(wait.next())
			}
		},
		Given::Running => Stepped::Wait(wait.next()),
		Given::Failed(error) => Stepped::Wait(failed(env, &error, wait)),
	}
}

/// Record what a failed call says about the access, and how long to wait.
fn failed<R: Rooms>(env: &Core<'_, R>, error: &RoomsError, wait: &mut Backoff) -> Duration {
	env.store.log(&format!("settling a replaced line: {error}"));
	env.access_failed(Activity::Sending, error);
	env.publish();
	error.retry_after.unwrap_or(Duration::ZERO).max(wait.next())
}

#[cfg(test)]
mod tests;
