//! The agent's actions and the receipts they leave. The session keeps a
//! receipt of each request under the access that sent it, and tells that
//! access which of its own receipts still keep a place (`held-effects`). That
//! list says which actions are unsettled, so a request that lands after its
//! verb died is found as surely as one the verb left pending.
//!
//! Each `say`, `send`, and `command` writes a claim,
//! `turn-actions/<operation>.json` in the bot directory, before its request
//! leaves. The claim holds the ledger id of the turn that sent it, the verb
//! and where it went as the agent named them, and how it ended, and nothing
//! the request says ([`claim`]). While it has no outcome it means that the
//! verb, not the serving loop, settles that operation while its turn's agent
//! runs, so two keepers never race over one result. A verb that settles its
//! action writes the outcome in one rewrite, and a claim stays until its turn
//! stops running, so the turn's next run reads what the earlier runs did. The
//! turn's agent has stopped once its reply is fixed, and from then on the loop
//! settles what the claims name, so an action that holds a place never holds
//! back the reply that follows it. At most [`MAX_EFFECTS`] claims are held,
//! which is how many receipts the session keeps, and an action past that is
//! refused before anything is written or sent.
//!
//! One keeper settles an action at a time: its verb while that verb runs, the
//! loop once no verb holds it, and never both. [`holder`] is the one place that
//! says which. A claim with an outcome is never asked. A claim with none names
//! the process that wrote it, and the loop reads the claim as cut once that
//! process is definitely gone: the harness ended the verb at its tool timeout,
//! or it crashed. A gone process never runs again, so the loop's settling
//! cannot race a live keeper. A process the loop cannot judge (a platform with
//! no evidence, another process-number namespace, a failed read) keeps its
//! claim with its verb and is shown in the status. A harness starts its tool
//! commands in sessions of their own, so ending a harness's group does not end
//! a verb, and neither does a restart: a verb runs on to its own budget and
//! writes its own end, and a claim whose verb survived a restart stays with
//! it.
//!
//! The serving loop asks the session for the list, then reads who owns each
//! operation: the ledger's lines, an open's note, or a claim of a turn still
//! open. Reading after the answer matters, because an owner records its
//! operation before the request leaves and lets go only once it settled. The
//! loop settles every other operation listed from the operation alone, as a
//! look at a note did: one that committed has what it returned kept, one
//! still running is asked about later, and one the session cannot settle has
//! its receipt given back (`engine/deliver/receipt.rs`). One the session will
//! not take back is logged once, left alone until the next start, and counted
//! in `status.unsettled_actions` while the list names it.
use super::{
	look::{Verdict, failed},
	note::{Name, Notes, State, minted},
};
use crate::bot::{
	engine::receipt::{self, Given, Receipt, Running},
	error::Error,
	group::{Presence, Verb},
	ledger::{Ledger, TurnId, Unlisted},
	rooms::{ActionSettled, Rooms, RoomsError, RoomsErrorKind, Standing},
	store::Store,
	words,
};
pub use claim::{Action, Label, Outcome, Place, What, says};
use rooms_application::content::session::custody::MAX_EFFECTS;
use rooms_platform::storage::StorageError;
use std::{
	cell::RefCell,
	collections::{BTreeMap, BTreeSet},
	path::Path,
};

/// The claims of the agent's actions, beside the directory whose lease counts
/// them.
pub(in crate::bot) const ACTIONS: Notes = Notes::new("turn-actions", "turn-actions-count", words::action);

/// Claim the action about to be sent under `operation`, before it is sent.
/// The count of held claims and the write are one step under the directory's
/// lease, so two verbs at once never both see room that only one fits, and a
/// claim past [`MAX_EFFECTS`] is refused before anything is written.
pub fn note(root: &Path, operation: &str, action: &Action) -> Result<(), Error> {
	if !minted(operation) {
		return Err(Error::Usage(format!("operation {operation} is not one the bot made")));
	}
	let _counting = match ACTIONS.counting(root) {
		Ok(held) => held,
		Err(StorageError::InUse(_)) => {
			return Err(Error::Usage(
				"another action is being noted and did not finish in time: run it again".into(),
			));
		}
		Err(error) => return Err(error.into()),
	};
	if held_except(root, operation)? >= MAX_EFFECTS as u64 {
		return Err(Error::Usage(format!(
			"{MAX_EFFECTS} actions are still settling, as many receipts as the session keeps: answer here, or act again once one settles"
		)));
	}
	ACTIONS.write(root, operation, action)
}

/// How many actions other than the one under `operation` may hold one of the
/// session's places: those with no outcome, or still being settled. A claim
/// that cannot be read counts, because it may.
fn held_except(root: &Path, operation: &str) -> Result<u64, Error> {
	let listed = ACTIONS.listed(root)?;
	let held = listed
		.live
		.iter()
		.filter(|live| *live != operation)
		.filter(|live| {
			ACTIONS
				.read::<Action>(root, live, State::Live)
				.ok()
				.flatten()
				.is_none_or(|action| action.held())
		})
		.count() as u64;
	Ok(held + listed.unsettled_now())
}

/// What the action under `operation` is, when `turn` claims it so its verbs
/// settle it, and none otherwise.
pub fn claimed(root: &Path, operation: &str, turn: TurnId) -> Result<Option<What>, Error> {
	if !minted(operation) {
		return Ok(None);
	}
	Ok(ACTIONS
		.read::<Action>(root, operation, State::Live)?
		.filter(|action| action.turn == turn && action.unsettled_by_verb())
		.map(|action| action.what))
}

/// Remove the claim of the action under `operation`, which committed nothing.
pub fn forget(root: &Path, operation: &str) -> Result<(), Error> {
	ACTIONS.remove(root, &Name::live(operation))?;
	Ok(())
}

/// Write how the action under `operation` ended, in one rewrite of its
/// claim. A claim that is gone, or whose end is already known, is left as it
/// is: the loop's later word replaces only an end it could not know.
pub fn finish(root: &Path, operation: &str, outcome: Outcome) -> Result<(), Error> {
	let Some(mut action) = ACTIONS.read::<Action>(root, operation, State::Live)? else {
		return Ok(());
	};
	if matches!(action.outcome, None | Some(Outcome::Cut | Outcome::Unknown)) {
		action.outcome = Some(outcome);
		ACTIONS.write(root, operation, &action)?;
	}
	Ok(())
}

/// The actions `turn` sent whose claims remain, in operation order, so a run
/// of the turn is told what the runs before it did.
pub fn earlier(root: &Path, turn: TurnId) -> Result<Vec<Action>, Error> {
	let mut found = Vec::new();
	for name in ACTIONS.names(root)? {
		if name.state == State::Live
			&& let Some(action) = ACTIONS.read::<Action>(root, &name.operation, State::Live)?
			&& action.turn == turn
		{
			found.push(action);
		}
	}
	Ok(found)
}

/// Who holds a claim's action while its outcome is unknown.
#[derive(Debug, PartialEq, Eq)]
enum Holder {
	/// Its verb runs, and settles it.
	Verb,
	/// Its verb cannot be told to run or not, for the reason given, so it stays
	/// with its verb and the status says so.
	Unjudged(String),
	/// No verb holds it: its outcome says so, or its verb's process is gone.
	Nobody,
}

/// Who holds `action`, the one place a claim's verb is judged. A claim with
/// an outcome never asks about the process, so a verb's own word and the
/// loop's are never second-guessed.
fn holder(action: &Action) -> Holder {
	if action.outcome.is_some() {
		return Holder::Nobody;
	}
	match action.verb.as_ref().map(Verb::presence) {
		Some(Presence::Alive) => Holder::Verb,
		Some(Presence::Gone) => Holder::Nobody,
		Some(Presence::Unknown(why)) => Holder::Unjudged(why),
		None => Holder::Unjudged("the verb wrote no identity of its process".into()),
	}
}

/// The claims cut loose: no verb holds them and the loop has not written
/// their ends. A claim that cannot be read counts as none. The loop lists at
/// once when a claim joins the set.
pub fn cut_set(root: &Path) -> BTreeSet<String> {
	// tolerant: a claim that cannot be read now is read, or removed, by the
	// next list, which is the only thing this set wakes.
	let Ok(names) = ACTIONS.names(root) else {
		return BTreeSet::new();
	};
	names
		.into_iter()
		.filter(|name| name.state == State::Live)
		.filter(|name| {
			ACTIONS
				.read::<Action>(root, &name.operation, State::Live)
				.ok()
				.flatten()
				.is_some_and(|action| action.held() && holder(&action) == Holder::Nobody)
		})
		.map(|name| name.operation)
		.collect()
}

/// What the loop reads of the other owners once the list has answered.
struct Owners {
	/// The operations some owner other than the loop settles: the ledger's
	/// sent, left, and replaced lines, every open's note, and the claims a
	/// verb of a turn still running holds.
	owned: BTreeSet<String>,
	/// The claims of turns still running that no verb holds any more, which
	/// the loop settles and writes the outcome of.
	cut: Vec<String>,
	/// Why a claim whose verb could not be judged stays with its verb, for the
	/// first such claim.
	unjudged: Option<String>,
}

/// Read the owners. A claim whose turn stopped running, or that cannot be
/// read, is removed and owns nothing, and a claim whose turn runs stays.
fn owners(store: &Store, ledger: &RefCell<Ledger>) -> Result<Owners, Error> {
	let root = store.root();
	let (mut owned, running): (BTreeSet<String>, BTreeSet<TurnId>) = {
		let ledger = ledger.borrow();
		let lines = ledger.sent().into_iter().chain(ledger.left_lines().iter().cloned());
		let replaced = ledger.replaced().iter().map(|line| line.operation.clone());
		(lines.chain(replaced).collect(), ledger.running().into_iter().collect())
	};
	owned.extend(super::opened(root)?);
	let mut cut = Vec::new();
	let mut unjudged = None;
	for name in ACTIONS.names(root)? {
		let claim = ACTIONS.read::<Action>(root, &name.operation, name.state);
		match claim {
			Ok(Some(action)) if name.state == State::Live && running.contains(&action.turn) => match holder(&action) {
				Holder::Verb => {
					owned.insert(name.operation);
				}
				Holder::Unjudged(why) => {
					unjudged.get_or_insert(why);
					owned.insert(name.operation);
				}
				Holder::Nobody if action.held() => cut.push(name.operation),
				Holder::Nobody => {}
			},
			// A claim gone since it was named owns nothing.
			Ok(None) => {}
			Ok(Some(action)) => {
				let unsettled = name.state != State::Live || action.held();
				if ACTIONS.remove(root, &name)? && unsettled {
					store.log(&format!(
						"{} was left by a turn whose agent stopped before it settled, so the session's list of held receipts decides it",
						words::action(&name.operation)
					));
				}
			}
			Err(_) => {
				if ACTIONS.remove(root, &name)? {
					store.log(&format!(
						"{} was left by a turn whose agent stopped before it settled, so the session's list of held receipts decides it",
						words::action(&name.operation)
					));
				}
			}
		}
	}
	Ok(Owners { owned, cut, unjudged })
}

/// What the serving loop remembers between its lists.
#[derive(Default)]
pub struct Strays {
	/// The operations already logged as still settling, so each is logged once.
	logged: BTreeSet<String>,
	/// When each given-up action's release first answered running.
	running: BTreeMap<String, Running>,
	/// The operations whose receipts the session would not take back, which
	/// this serve asks about no more.
	left: BTreeSet<String>,
}

impl Strays {
	fn settled(&mut self, operation: &str) {
		self.logged.remove(operation);
		self.running.remove(operation);
	}
}

/// What one list came to.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Listed {
	/// Whether an unowned action is still settling, so the loop asks again on
	/// its backoff.
	pub pending: bool,
	/// The first listed action that waits for a cause other than its work
	/// still running, such as a committed line the bot could not keep yet. The
	/// serving loop shows it in `status.last_error` until it settles.
	pub waiting: Option<String>,
	/// How many listed actions the session would not take back.
	pub unsettled: u64,
}

/// Why an action settles later when its work is still running, which is no
/// failure to show.
const RUNNING: &str = "it is still running in the session";

/// What one look at an action came to, and how the action ended when that is
/// known.
struct Settled {
	verdict: Verdict,
	outcome: Option<Outcome>,
}

impl Settled {
	fn later(why: &str) -> Self {
		Self::of(Verdict::Later(why.into()))
	}

	/// A verdict with no outcome of its own: a settled or given-up action
	/// ended in a way nobody can learn, and a later one has not ended.
	fn of(verdict: Verdict) -> Self {
		let outcome = match verdict {
			Verdict::Later(_) => None,
			Verdict::Settled(_) | Verdict::GiveUp { .. } => Some(Outcome::Unknown),
		};
		Self { verdict, outcome }
	}

	fn ended(what: impl Into<String>, outcome: Outcome) -> Self {
		Self {
			verdict: Verdict::Settled(what.into()),
			outcome: Some(outcome),
		}
	}
}

fn verdict(answer: Result<ActionSettled, RoomsError>) -> Settled {
	match answer {
		Ok(ActionSettled::Gone) => Settled::ended("keeps no place any more", Outcome::Unknown),
		Ok(ActionSettled::Kept(standing)) => Settled::ended(words::ACTION_KEPT, Outcome::Posted(standing)),
		Ok(ActionSettled::Unapplied) => Settled::ended("committed nothing", Outcome::Nothing),
		Ok(ActionSettled::Released) => Settled::ended(
			"committed, could not keep what it returned, and the session took its receipt back",
			Outcome::Posted(Standing::Unknown),
		),
		Ok(ActionSettled::Pending) => Settled::later(RUNNING),
		Ok(ActionSettled::Unknown) => Settled::of(Verdict::give_up(
			"the session cannot say whether it committed, because the work that would settle it ended",
		)),
		Err(error) => Settled::of(failed(error, Verdict::give_up)),
	}
}

/// Settle `operation` once: keep what it committed, or give its receipt back
/// when the session can never settle it. `running` remembers when a release
/// first answered running.
async fn settle_one<R: Rooms>(rooms: &R, operation: &str, running: &mut Running) -> Settled {
	let settled = verdict(rooms.settle_action(operation).await);
	let Verdict::GiveUp { why, .. } = settled.verdict else {
		return settled;
	};
	match receipt::give_back(rooms, Receipt::Action { operation }, running).await {
		Given::Back => Settled::of(Verdict::Settled(format!(
			"{} ({why}), so the session took its receipt back",
			words::DID_NOT_SETTLE
		))),
		Given::Running => Settled::later(RUNNING),
		Given::Left(error) => Settled::of(Verdict::GiveUp {
			why,
			refused: Some(error.to_string()),
		}),
		Given::Failed(error) => Settled::of(failed(error, |refused| Verdict::GiveUp {
			why,
			refused: Some(refused),
		})),
	}
}

/// Ask the session which of this access's receipts keep a place, and settle
/// every one listed that no other owner settles. The list also decides the
/// ledger's records of lines the session would not take back: a record from
/// before the list whose receipt the list does not name holds no place any
/// more, so it goes, and a record written while the list was asked waits for
/// the next. A list that fails settles nothing and is the caller's failure.
pub async fn settle<R: Rooms>(
	rooms: &R,
	store: &Store,
	ledger: &RefCell<Ledger>,
	strays: &mut Strays,
) -> Result<Listed, Error> {
	let recorded: BTreeSet<String> = ledger.borrow().left_lines().iter().cloned().collect();
	let held = match rooms.held().await {
		Ok(held) => held,
		// The receipts a failed list would name keep their places, so the
		// failure goes to the loop, which records it in `status.last_error`
		// and asks again on its backoff until one list answers.
		Err(error) => return Err(Error::Rooms(error)),
	};
	let cleared = recorded
		.into_iter()
		.filter(|operation| !held.contains(operation))
		.collect();
	ledger.borrow_mut().forget_left(store, &cleared)?;
	let Owners { owned, cut, unjudged } = owners(store, ledger)?;
	let root = store.root();
	// A claim cut off at a start that the session does not list holds no
	// place and never will: the session cannot say what it did.
	for operation in cut.iter().filter(|operation| !held.contains(*operation)) {
		store.log(&format!(
			"{} was cut off and the session no longer lists it, so the bot cannot say what it did",
			words::action(operation)
		));
		wrote(store, operation, finish(root, operation, Outcome::Unknown));
	}
	let mut listed = Listed::default();
	if let Some(why) = unjudged {
		listed.waiting = Some(format!(
			"an agent's action stays with its verb, which cannot be told to run or not: {why}"
		));
	}
	for operation in held.iter().filter(|operation| !owned.contains(*operation)) {
		if strays.left.contains(operation) {
			continue;
		}
		let said = words::action(operation);
		let running = strays.running.entry(operation.clone()).or_default();
		let Settled { verdict, outcome } = settle_one(rooms, operation, running).await;
		if let Some(outcome) = outcome {
			wrote(store, operation, finish(root, operation, outcome));
		}
		match verdict {
			Verdict::Settled(what) => {
				strays.settled(operation);
				store.log(&format!("{said} {what}"));
			}
			Verdict::Later(why) => {
				listed.pending = true;
				if why != RUNNING && listed.waiting.is_none() {
					listed.waiting = Some(format!("{said} is not settled, and the bot asks again: {why}"));
				}
				if strays.logged.insert(operation.clone()) {
					store.log(&format!(
						"{said} {} ({why}). Looking again later",
						words::STILL_SETTLING
					));
				}
			}
			Verdict::GiveUp { why, refused } => {
				strays.settled(operation);
				strays.left.insert(operation.clone());
				let back = refused.map_or_else(String::new, |refused| {
					format!(", and the session would not take its receipt back ({refused})")
				});
				store.log(&format!(
					"{said} {} ({why}){back}. It holds one of the session's places until this access is revoked",
					words::DID_NOT_SETTLE
				));
			}
		}
	}
	// What the session no longer lists needs no memory.
	strays.left.retain(|operation| held.contains(operation));
	strays.logged.retain(|operation| held.contains(operation));
	strays.running.retain(|operation, _| held.contains(operation));
	listed.unsettled = strays.left.len() as u64;
	Ok(listed)
}

/// Log a claim whose outcome could not be written. The session already
/// settled the action, and the claim keeps what it had until its turn stops
/// running, so the prompt of the next run says the bot has not yet learned how it ended.
fn wrote(store: &Store, operation: &str, written: Result<(), Error>) {
	// tolerant: the claim keeps its earlier word, and the turn's end removes it.
	if let Err(error) = written {
		store.log(&format!(
			"{} settled, but its outcome could not be written to its claim: {error}",
			words::action(operation)
		));
	}
}

/// What the old access's last list came to.
pub enum LastList {
	/// The operations it listed and could not settle.
	Left(Vec<String>),
	/// It could not list, for the reason given.
	Unlisted(Unlisted),
}

/// The old access's last list before a replacement: settle what it can of
/// every listed action outside the ledger's lines and the opens' notes, and
/// answer the operations it could not. No verb runs then, so no claim owns
/// anything. The list is part of the replacement's preparation, because no
/// later serve lists through the old access: a list that fails refuses the
/// replacement before its link is stored. A revoked access holds nothing to
/// list, since revoking it gave back every receipt it held. A paused one and
/// a denied one are answered as unlisted: only its operator can resume a
/// paused access, and the session's answer that it no longer holds an access
/// says nothing about the receipts it gave back, as `opens::look::failed`
/// reads the same answer for an open's note.
pub async fn last<R: Rooms>(rooms: &R, store: &Store, ledger: &Ledger) -> Result<LastList, Error> {
	let held = match rooms.held().await {
		Ok(held) => held,
		Err(error) if error.kind == RoomsErrorKind::Revoked => {
			store.log(&format!(
				"the old access can no longer list the receipts it held ({error}), and revoking it gave every one back"
			));
			return Ok(LastList::Left(Vec::new()));
		}
		Err(error) if error.kind == RoomsErrorKind::Denied => {
			store.log(&format!(
				"the session no longer holds the old access ({error}), so the agent's actions it holds are not listed, and each can hold a place in the session until it is revoked"
			));
			return Ok(LastList::Unlisted(Unlisted::Denied));
		}
		Err(error) if error.kind == RoomsErrorKind::Paused => {
			store.log(
				"the old access is paused, so the agent's actions it holds are not listed, and each can hold a place in the session until it is revoked",
			);
			return Ok(LastList::Unlisted(Unlisted::Paused));
		}
		Err(error) => return Err(Error::Unlisted(error)),
	};
	let mut owned: BTreeSet<String> = ledger.sent().into_iter().collect();
	owned.extend(ledger.left_lines().iter().cloned());
	owned.extend(ledger.replaced().iter().map(|line| line.operation.clone()));
	owned.extend(super::opened(store.root())?);
	let mut left = Vec::new();
	for operation in held.into_iter().filter(|operation| !owned.contains(operation)) {
		let Settled { verdict, outcome } = settle_one(rooms, &operation, &mut Running::default()).await;
		// A running turn's claim keeps how its action ended, as the serving
		// loop writes it, so the turn's next run is told.
		if let Some(outcome) = outcome {
			wrote(store, &operation, finish(store.root(), &operation, outcome));
		}
		match verdict {
			Verdict::Settled(what) => store.log(&format!("{} {what}", words::action(&operation))),
			Verdict::Later(_) | Verdict::GiveUp { .. } => left.push(operation),
		}
	}
	Ok(LastList::Left(left))
}

mod claim;
#[cfg(test)]
mod tests;
