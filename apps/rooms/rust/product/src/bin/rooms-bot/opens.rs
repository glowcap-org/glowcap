//! The direct-message opens the bot sent and has not seen settle. A `--dm`
//! open writes its note, `opens/<operation>.json` in the bot directory and
//! outside every agent's working directory, atomically before it sends, and
//! removes it once the open settles. The note holds the base and
//! introduction the open sent, so a look again sends that same one, and the
//! conversation and ledger id of the turn that sent it. At most [`MAX_OPENS`]
//! notes of the serving access, live and unsettled together, are held, so the
//! opens leave the rest of the session's receipt places to the bot's replies,
//! and a `--dm` that would open past that is refused.
//!
//! A note belongs to the turn that wrote it until that turn's agent stops, and
//! to the serving loop after, even while the turn's reply is still going out.
//! Ownership is read from the ledger (`Ledger::running`): the loop never looks
//! at a note whose turn still runs there, so a verb that writes a note and
//! then forgets it, or keeps it, is never raced by a look. A turn the bot
//! was killed in stops running as the ledger records it, and the loop takes
//! its note then.
//!
//! While the bot serves, [`settle`] alone looks at the notes, one look at a
//! time on a timer of its own, once the agent of the turn that sent a note has stopped. A
//! look sends the same open under the same operation and base,
//! which the session answers from that open's first receipt. An open still
//! pending, or a session that is paused or unreachable, is looked at again
//! later, less often while it stays so.
//!
//! The bot gives an open up only on the session's verdict that this access
//! can never settle it: the session cannot say whether it committed, because
//! the work that would settle it ended, or it refuses the open. Giving up
//! first renames the note `<operation>.json.giving`, and only then asks the
//! session to give the receipt back, so the open is never sent again: a look
//! at a given-up note asks for the receipt back and nothing else. The session
//! keeps a released receipt, settled as given up, so a released open's
//! answer stays final. A release answered released drops the note. One the
//! session cannot answer yet keeps it, and the next look asks again. Only a
//! refusal renames it `<operation>.json.unsettled`, logged once and counted
//! in `status.unsettled_opens`. The loop never looks at an unsettled note:
//! the session keeps that open's receipt until the access that sent it is
//! revoked and then releases it. Once the receipt leaves the session's
//! bounded window of receipts, the session says it holds nothing for the
//! operation, and the next start drops the note (`docs/rooms/bot.md`). A note
//! that cannot be read becomes unsettled the same way.
//!
//! The session knows which access sent an open, and the bot asks it once at
//! each start about every note it did not write (`serve/access.rs`). A note
//! another access sent is replaced, as a line is (`ledger/replaced.rs`), and
//! gains the suffix `.replaced`, so it is not counted
//! against the serving access's [`MAX_OPENS`], is counted in
//! `status.replaced_opens`, and is never looked at. A note the session holds
//! no receipt for is dropped, whatever state it was in. A note the
//! serving access sent has no suffix beyond its own state, so one a replaced
//! access held returns to it when its link serves again. Before a replacement
//! link is stored, the old access takes [`Pass::Last`] at the notes it sent,
//! which settles what it can, so a replacement that stops or is refused
//! changes no note it could not settle.
//!
//! The agent's actions keep only claims, and the session's list of held
//! receipts decides them (`action.rs`). The same loop asks for that list.
use super::{
	engine::{
		Backoff, Env,
		receipt::{self, Receipt, Running},
	},
	error::Error,
	ledger::TurnId,
	rooms::{Base, ConversationId, Holder, OpenSettled, Rooms, RoomsError},
	store::Store,
	words,
};
use rooms_application::{content::session::custody::MAX_EFFECTS, room::inbox::same_nick};
use rooms_platform::storage::StorageError;
use rooms_services::session::attached::Introduction;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, convert::Infallible, path::Path, time::Duration};
use tokio::time::Instant;

pub mod action;
mod look;
mod note;
pub use look::Waiting;
use look::{Subject, Verdict, failed};
use note::{Custody, Name, Notes, State, minted};

/// The most opens the serving access holds at once, live, given up, or
/// unsettled. Each can hold one of the session's receipt places until it
/// settles or its access is revoked.
pub const MAX_OPENS: usize = 4;
// This access's opens take at most half the session's places.
const _: () = assert!(MAX_OPENS * 2 <= MAX_EFFECTS);
/// How long the owner waits between looks while no open is pending.
const IDLE: Duration = Duration::from_secs(1);
/// How long the owner waits between lists of held receipts while nothing it
/// listed is settling and no turn's agent has stopped. A request whose verb died can
/// land at any time after, and only a list finds it, so this bounds how long
/// such a receipt goes unsettled. Each list is one read of the session.
const SWEEP: Duration = Duration::from_secs(60);
/// The notes of the opens, beside the directory whose lease counts them.
const OPENS: Notes = Notes::new("opens", "opens-count", words::note);

/// One open sent under an operation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Open {
	pub base: Base,
	pub introduction: Introduction,
	/// The conversation of the turn that sent it.
	pub conversation: ConversationId,
	/// The turn that sent it, which owns the note until the ledger ends it.
	pub turn: TurnId,
}

/// Note the open about to be sent under `operation`, before it is sent. The
/// count of held notes and the write are one step under the directory's
/// lease, so two verbs at once never both see room that only one fits, and a
/// note past [`MAX_OPENS`] is refused before anything is written.
pub fn note(root: &Path, operation: &str, open: &Open) -> Result<(), Error> {
	if !minted(operation) {
		return Err(Error::Usage(format!("operation {operation} is not one the bot made")));
	}
	let _counting = match OPENS.counting(root) {
		Ok(held) => held,
		Err(StorageError::InUse(_)) => {
			return Err(Error::Usage(
				"another --dm is being noted and did not finish in time: use --dm again".into(),
			));
		}
		Err(error) => return Err(error.into()),
	};
	let listed = OPENS.listed(root)?;
	// An open to this peer already settling would be opened a second time, so
	// it is looked at, never sent again. The check is under the lease, so two
	// turns opening to one peer at once spend one place.
	if let Some((pending, base, owner)) = pending_to(root, &listed.live, &open.introduction.peer, operation) {
		return Err(Error::Usage(if owner == open.turn {
			format!(
				"a --dm open to {} is still settling: look at it again with --operation {pending} --base {base}",
				open.introduction.peer
			)
		} else {
			format!(
				"{}, so open nothing again: a plain --dm will use the conversation once it exists",
				words::settling(&open.introduction.peer)
			)
		}));
	}
	if listed.held_except(operation) >= MAX_OPENS as u64 {
		return Err(match listed.unsettled {
			0 => Error::Usage(format!(
				"{MAX_OPENS} direct-message opens are still settling, the most the bot keeps: answer here, or use --dm again once one settles"
			)),
			unsettled => Error::Usage(format!(
				"{MAX_OPENS} direct-message opens are still settling or unsettled ({unsettled} unsettled), the most the bot keeps: answer here. An unsettled open leaves when this access is revoked and the bot starts again"
			)),
		});
	}
	OPENS.write(root, operation, open)
}

/// The live note among `live`, other than `except`, that names `peer`, with
/// its operation, base, and owning turn, or none.
fn pending_to(root: &Path, live: &[String], peer: &str, except: &str) -> Option<(String, u64, TurnId)> {
	for operation in live.iter().filter(|operation| *operation != except) {
		// tolerant: an unreadable note names no peer, and the serving look
		// logs why and leaves it unsettled.
		let Some(open) = OPENS.read::<Open>(root, operation, State::Live).ok().flatten() else {
			continue;
		};
		if same_nick(&open.introduction.peer, peer) {
			return Some((operation.clone(), open.base.0, open.turn));
		}
	}
	None
}

/// The open noted under `operation`, or none once it settled.
pub fn noted(root: &Path, operation: &str) -> Result<Option<Open>, Error> {
	if !minted(operation) {
		return Ok(None);
	}
	OPENS.read(root, operation, State::Live)
}

/// Remove the note of the open under `operation`, which settled.
pub fn forget(root: &Path, operation: &str) -> Result<(), Error> {
	OPENS.remove(root, &Name::live(operation))?;
	Ok(())
}

/// Every note of an open, whichever access sent it and whatever state it is
/// in: the notes a start did not write, which the session says the sender of.
pub fn unplaced(root: &Path) -> Result<Vec<Unplaced>, Error> {
	Ok(OPENS
		.names(root)?
		.into_iter()
		.map(|name| Unplaced(OPENS, name))
		.collect())
}

/// A note a start did not write.
#[derive(Clone, Debug)]
pub struct Unplaced(Notes, Name);

impl Unplaced {
	/// The operation the note was sent under, which the session is asked about.
	pub fn operation(&self) -> &str {
		&self.1.operation
	}

	/// Put the note where the session's answer says it belongs, and log a
	/// change. A note already there, or already gone, changes nothing, so a
	/// start that stopped part way finishes by asking again.
	pub fn place(&self, store: &Store, holder: Holder) -> Result<(), Error> {
		let (root, notes, name) = (store.root(), self.0, &self.1);
		let operation = &name.operation;
		let said = |what: &str| store.log(&format!("{} {what}", notes.label(operation)));
		match holder {
			Holder::Mine if name.custody == Custody::Another => {
				if notes.rename(root, name, &name.with(name.state, Custody::Serving), "restoring a note")? {
					said("was sent by this access, so the bot looks after it again");
				}
			}
			Holder::Another if name.custody == Custody::Serving => {
				if notes.rename(
					root,
					name,
					&name.with(name.state, Custody::Another),
					"marking a note replaced",
				)? {
					said("was sent by another access, which holds its receipt, so the bot leaves it alone");
				}
			}
			Holder::Nobody => {
				if notes.remove(root, name)? {
					said(&format!("is one {}, so the bot drops its note", words::HOLDS_NOTHING));
				}
			}
			Holder::Mine | Holder::Another => {}
		}
		Ok(())
	}
}

/// Whether any note is held, live or unsettled, whichever access sent it.
/// An open's note sends its introduction again, so a first start refuses an
/// earlier link's. An action's claim sends nothing, so only the opens' notes
/// are asked about.
pub fn held(root: &Path) -> Result<bool, Error> {
	Ok(!OPENS.names(root)?.is_empty())
}

/// The operation of every open's note, whatever its state and whichever
/// access sent it: the opens their own look settles.
fn opened(root: &Path) -> Result<Vec<String>, Error> {
	Ok(OPENS.names(root)?.into_iter().map(|name| name.operation).collect())
}

/// Which pass over the notes the bot takes.
pub enum Pass {
	/// The serving bot's, which looks again later at a note still pending and
	/// decides one it can never settle.
	Serving,
	/// The old access's, before the new link serves, at the notes
	/// outside `foreign`, the ones the session says another access sent or
	/// holds nothing for. It settles what it can, gives back the receipt of an
	/// open this access had given up, and leaves the rest as it is: a
	/// replacement the session refuses leaves them to this access.
	Last { foreign: BTreeSet<String> },
}

/// What one look at every note did.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Looked {
	/// Whether a note is still pending.
	pub pending: bool,
	/// How many notes this look left unsettled.
	pub unsettled_now: u64,
}

fn verdict(answer: Result<OpenSettled, RoomsError>) -> Verdict {
	match answer {
		Ok(OpenSettled::Opened(conversation)) => {
			Verdict::Settled(format!("{}, as conversation {conversation}", words::KEPT_ROUTE))
		}
		Ok(OpenSettled::Reused(conversation)) => Verdict::Settled(format!(
			"gave its route back, because conversation {conversation} already reaches them"
		)),
		Ok(OpenSettled::Unapplied) => Verdict::Settled("this look committed nothing".into()),
		Ok(OpenSettled::Released) => Verdict::Settled("could not keep its route, and the session gave it back".into()),
		Ok(OpenSettled::Pending) => Verdict::Later("it is still running in the session".into()),
		Ok(OpenSettled::Unknown) => {
			Verdict::give_up("the session cannot say whether it committed, because the work that would settle it ended")
		}
		Err(error) => failed(error, Verdict::give_up),
	}
}

/// Look once at every note the serving access sent whose turn is not in
/// `turns`, the turns still running in the ledger.
pub async fn look<R: Rooms>(
	rooms: &R,
	store: &Store,
	kind: &Pass,
	turns: &BTreeSet<TurnId>,
	waiting: &mut Waiting,
) -> Result<Looked, Error> {
	let root = store.root();
	let mut looked = Looked::default();
	let listed = OPENS.listed(root)?;
	// A given-up open is only given back, by the access that sent it: the
	// serving one, or the old one at its last look.
	for operation in listed.giving {
		if let Pass::Last { foreign } = kind
			&& foreign.contains(&operation)
		{
			continue;
		}
		match (OPENS.read::<Open>(root, &operation, State::Giving), kind) {
			(Ok(Some(open)), Pass::Serving) => {
				let (subject, receipt) = (subject(&operation, &open), receipt(&operation, &open));
				look::hand_back(rooms, store, &mut looked, waiting, &subject, receipt, None).await?;
			}
			(Ok(Some(open)), Pass::Last { .. }) => last_give_back(rooms, store, &operation, &open).await?,
			(Ok(None), _) => {}
			(Err(error), Pass::Serving) => {
				look::unreadable(store, &mut looked, OPENS, &operation, State::Giving, &error)?;
			}
			// tolerant: a last look decides nothing it cannot read, and the
			// serving look logs why and leaves the note unsettled.
			(Err(_), Pass::Last { .. }) => {}
		}
	}
	for operation in listed.live {
		if let Pass::Last { foreign } = kind
			&& foreign.contains(&operation)
		{
			continue;
		}
		let open = match (OPENS.read::<Open>(root, &operation, State::Live), kind) {
			(Ok(Some(open)), _) => open,
			(Ok(None), _) => continue,
			(Err(error), Pass::Serving) => {
				look::unreadable(store, &mut looked, OPENS, &operation, State::Live, &error)?;
				continue;
			}
			// tolerant: a last look decides nothing it cannot read, and the
			// serving look logs why and leaves the note unsettled.
			(Err(_), Pass::Last { .. }) => continue,
		};
		if turns.contains(&open.turn) {
			continue;
		}
		match kind {
			Pass::Serving => {
				let verdict = verdict(rooms.settle_open(&operation, open.base, &open.introduction).await);
				let (subject, receipt) = (subject(&operation, &open), receipt(&operation, &open));
				look::serving(rooms, store, &mut looked, waiting, &subject, receipt, verdict).await?;
			}
			Pass::Last { .. } => last_look(rooms, store, &operation, &open).await?,
		}
	}
	Ok(looked)
}

/// The note of the open under `operation`, as a look names it.
fn subject<'a>(operation: &'a str, open: &Open) -> Subject<'a> {
	Subject {
		notes: OPENS,
		operation,
		said: words::looked(operation, &open.introduction.peer),
	}
}

/// The receipt of the open under `operation`.
fn receipt<'a>(operation: &'a str, open: &'a Open) -> Receipt<'a> {
	Receipt::Open {
		operation,
		introduction: &open.introduction,
		base: open.base,
	}
}

/// The old access's look at one open. It forgets an open that
/// settled and decides nothing it cannot settle.
async fn last_look<R: Rooms>(rooms: &R, store: &Store, operation: &str, open: &Open) -> Result<(), Error> {
	let peer = &open.introduction.peer;
	if let Verdict::Settled(what) = verdict(rooms.settle_open(operation, open.base, &open.introduction).await) {
		store.log(&format!("{} {what}", words::looked(operation, peer)));
		forget(store.root(), operation)?;
	}
	Ok(())
}

/// The old access's give-back of an open it gave up before the replacement.
/// It forgets the note once the session took the receipt back, and decides
/// nothing else: a refusal leaves the note as it is.
async fn last_give_back<R: Rooms>(rooms: &R, store: &Store, operation: &str, open: &Open) -> Result<(), Error> {
	let (subject, receipt) = (subject(operation, open), receipt(operation, open));
	let answer = receipt::give_back(rooms, receipt, &mut Running::default()).await;
	if let Verdict::Settled(what) = look::given_back(words::GIVEN_UP.into(), answer) {
		store.log(&format!("{} {what}", subject.said));
		OPENS.remove(store.root(), &Name::serving(operation, State::Giving))?;
	}
	Ok(())
}

/// Settle the notes of the opens and the agent's actions the session lists
/// while the bot serves. Only this owner settles them in the serving process,
/// so no two looks race, and `status` counts what is unsettled. It looks at
/// nothing until the link has answered and every note a start did not write
/// is placed by the session's answer, so a link that has not answered, or a
/// replacement the session refuses, never acts on a note. It lists the held
/// receipts at once, after any turn's agent stops or a verb leaves an action
/// to it, on its backoff while a listed
/// action is settling, and every [`SWEEP`] otherwise. A `serve` that ends
/// first drops this without a look. It never returns: the serving loop's end
/// drops it.
pub async fn settle<R: Rooms>(env: &Env<'_, R>) -> Infallible {
	env.until_linked().await;
	let mut wait = Backoff::standard();
	let mut listing = Backoff::standard();
	let mut waiting = Waiting::default();
	let mut strays = action::Strays::default();
	let mut failing = None;
	// What `status.last_error` says of an action still waiting to be kept.
	let mut unkept: Option<String> = None;
	let mut list_at = Instant::now();
	let mut stopped = env.ledger.borrow().ended();
	let mut cut = BTreeSet::new();
	loop {
		let (turns, ended): (BTreeSet<TurnId>, u64) = {
			let ledger = env.ledger.borrow();
			(ledger.running().into_iter().collect(), ledger.ended())
		};
		// A turn whose agent stopped may have left an action only the list
		// names, and its reply cannot go out while that action holds a place.
		if ended != stopped {
			stopped = ended;
			list_at = Instant::now();
		}
		// An action a verb left to the bot, or whose verb is gone, while its
		// turn runs is listed at the next pass, not at the next sweep. The
		// set is compared, so a claim that joins it as another leaves is not
		// hidden by an equal count.
		let cuts = action::cut_set(env.store.root());
		if !cuts.is_subset(&cut) {
			list_at = Instant::now();
		}
		cut = cuts;
		let list = Instant::now() >= list_at;
		// The look, the list, and the count each run whatever the others did,
		// so a failure in one directory of notes never stops the list.
		let opens = look(env.rooms, env.store, &Pass::Serving, &turns, &mut waiting).await;
		let actions = match list {
			true => Some(action::settle(env.rooms, env.store, &env.ledger, &mut strays).await),
			false => None,
		};
		let held = OPENS.listed(env.store.root());
		match &actions {
			Some(Ok(actions)) if !actions.pending => {
				listing.reset();
				list_at = Instant::now() + SWEEP;
			}
			Some(_) => list_at = Instant::now() + listing.next(),
			None => {}
		}
		let (changed, newly, failed) = {
			let mut facts = env.facts.borrow_mut();
			let before = (facts.unsettled_opens, facts.replaced_opens, facts.unsettled_actions);
			if let Ok(held) = &held {
				(facts.unsettled_opens, facts.replaced_opens) = (held.unsettled_now(), held.replaced);
			}
			let newly = match &actions {
				Some(Ok(actions)) => {
					let newly = actions.unsettled > facts.unsettled_actions;
					facts.unsettled_actions = actions.unsettled;
					newly
				}
				_ => false,
			};
			let mut changed = before != (facts.unsettled_opens, facts.replaced_opens, facts.unsettled_actions);
			if let Ok(opens) = &opens
				&& opens.unsettled_now > 0
			{
				facts.failed(
					super::status::Activity::Sending,
					format!("{} direct-message opens did not settle", opens.unsettled_now),
				);
				changed = true;
			}
			changed |= show_waiting(
				&mut facts,
				&mut unkept,
				actions.as_ref().and_then(|list| list.as_ref().ok()),
			);
			if newly {
				let unsettled = facts.unsettled_actions;
				facts.failed(
					super::status::Activity::Sending,
					format!("{unsettled} of the agent's actions did not settle"),
				);
			}
			let failure = [
				opens.as_ref().err(),
				actions.as_ref().and_then(|actions| actions.as_ref().err()),
				held.as_ref().err(),
			]
			.into_iter()
			.flatten()
			.next();
			match (failure, &failing) {
				(Some(error), _) => {
					let text = error.to_string();
					let during = match error {
						Error::Rooms(_) => super::status::Activity::Sending,
						_ => super::status::Activity::Saving,
					};
					// Recorded on every pass, because another activity's success
					// clears what it shares with this one while this still fails.
					let was = facts.last_error.clone();
					facts.failed(during, &text);
					changed |= facts.last_error != was;
					if failing.as_ref().is_none_or(|(_, failed)| *failed != text) {
						env.store.log(&format!(
							"settling the direct-message opens and the agent's actions: {text}"
						));
						failing = Some((during, text));
					}
				}
				(None, Some((during, text))) => {
					// Only this loop's own failure clears: a delivery's error of the
					// same activity may have replaced it since.
					facts.cleared(*during, text);
					failing = None;
					changed = true;
				}
				(None, None) => {}
			}
			(changed, newly, failure.is_some())
		};
		if changed || newly {
			env.publish();
		}
		let pending = failed || opens.as_ref().is_ok_and(|opens| opens.pending);
		let delay = if pending {
			wait.next()
		} else {
			wait.reset();
			IDLE
		};
		tokio::time::sleep(delay.min(list_at.saturating_duration_since(Instant::now()))).await;
	}
}

/// Show in `status.last_error` why an action's line is still unkept, and
/// clear it once a list no longer names one. `shown` is what this loop put
/// there. A pass that did not list leaves it as it is. Whether the status
/// changed.
fn show_waiting(facts: &mut super::status::Facts, shown: &mut Option<String>, listed: Option<&action::Listed>) -> bool {
	let Some(listed) = listed else {
		return false;
	};
	match (&listed.waiting, shown.take()) {
		(Some(text), _) => {
			let was = facts.last_error.clone();
			facts.failed(super::status::Activity::Sending, text);
			*shown = Some(text.clone());
			facts.last_error != was
		}
		(None, Some(text)) => {
			facts.cleared(super::status::Activity::Sending, text);
			true
		}
		(None, None) => false,
	}
}

#[cfg(test)]
mod tests;
