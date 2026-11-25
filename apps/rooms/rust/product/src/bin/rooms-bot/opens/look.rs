//! What one look at a note decides, for a `--dm` open and for an agent's
//! action alike. A look reads the session's answer as a [`Verdict`]: the
//! request settled and its note goes, it is still settling and is looked at
//! later, or this access can never settle it and gives its receipt back.
//! Giving back runs the receipt rule (`engine/deliver/receipt.rs`), and only
//! the session's refusal leaves a note unsettled.
use super::{
	Looked,
	note::{Name, Notes, State},
};
use crate::bot::{
	engine::receipt::{self, Given, Receipt, Running},
	error::Error,
	fault::{self, Fail},
	rooms::{Rooms, RoomsError, RoomsErrorKind},
	store::Store,
	words,
};
use std::collections::{BTreeMap, BTreeSet};

/// How a log line says the bot leaves a note unsettled for good.
pub(super) const LEFT_UNSETTLED: &str = "so the bot leaves it unsettled";

/// What one look at a request says to do with its note.
pub(super) enum Verdict {
	Settled(String),
	Later(String),
	/// This access can never settle the request. `refused` is why the session
	/// would not give its receipt back, once it was asked.
	GiveUp {
		why: String,
		refused: Option<String>,
	},
}

impl Verdict {
	pub(super) fn give_up(why: impl Into<String>) -> Self {
		Self::GiveUp {
			why: why.into(),
			refused: None,
		}
	}
}

/// What a failed call to the session says of a request.
/// - `Revoked`: the access is over for good, so the note is forgotten. The
///   session gives each receipt of a revoked access back once it can no longer
///   change (`runtime/src/session/managed/revoked_receipts.rs`).
/// - `Denied`: the session no longer holds this access, which ends serving
///   as `env::access_of` says. Nothing says the session gave the access's
///   receipts back, so the note stays unsettled, worded by `refused`, until
///   a new link replaces this one.
/// - `Refused`: the session's verdict on this request. The access still holds
///   its receipt, so the note stays unsettled, worded by `refused`.
/// - Anything else is no verdict, so the note stays live and the next look
///   asks again.
pub(super) fn failed(error: RoomsError, refused: impl FnOnce(String) -> Verdict) -> Verdict {
	match error.kind {
		RoomsErrorKind::Revoked => Verdict::Settled(
			"ended with the revoked access, and the session gives its receipt back once the receipt can no longer change"
				.into(),
		),
		RoomsErrorKind::Refused | RoomsErrorKind::Denied => refused(error.to_string()),
		_ => Verdict::Later(error.to_string()),
	}
}

/// What the session's answer to giving a receipt back says of the note. Only
/// a refusal leaves the note unsettled, because only that is the session's
/// verdict: a session that cannot be reached or an access that is paused has
/// not been asked yet.
pub(super) fn given_back(why: String, answer: Given) -> Verdict {
	match answer {
		Given::Back => Verdict::Settled(format!(
			"{} ({why}), so the session gave its receipt back and the bot drops the note",
			words::DID_NOT_SETTLE
		)),
		Given::Left(error) => Verdict::GiveUp {
			why,
			refused: Some(error.to_string()),
		},
		Given::Running => Verdict::Later("it is still running in the session".into()),
		Given::Failed(error) => failed(error, |refused| Verdict::GiveUp {
			why,
			refused: Some(refused),
		}),
	}
}

/// What one serving loop's looks remember between them.
#[derive(Default)]
pub struct Waiting {
	/// The operations already logged as pending, so each is logged once.
	logged: BTreeSet<String>,
	/// When each given-up request's release first answered running.
	running: BTreeMap<String, Running>,
}

/// The note one look decides: its directory, its operation, and how its log
/// lines begin.
pub(super) struct Subject<'a> {
	pub(super) notes: Notes,
	pub(super) operation: &'a str,
	pub(super) said: String,
}

/// Ask the session to give back `receipt`, of the given-up request `subject`
/// notes, and decide the note by the answer. `why` is why it was given up,
/// when this look found it.
pub(super) async fn hand_back<R: Rooms>(
	rooms: &R,
	store: &Store,
	looked: &mut Looked,
	waiting: &mut Waiting,
	subject: &Subject<'_>,
	receipt: Receipt<'_>,
	why: Option<String>,
) -> Result<(), Error> {
	// Only the access that sent a request can give its receipt back, and the
	// serving look is that access's own. A paused executor's request answers
	// unknown, and giving it back retires that executor with the receipt.
	let why = why.unwrap_or_else(|| words::GIVEN_UP.into());
	let running = waiting.running.entry(subject.operation.to_owned()).or_default();
	let verdict = given_back(why, receipt::give_back(rooms, receipt, running).await);
	decide(store, looked, waiting, subject, State::Giving, verdict)
}

/// Act on one look's `verdict` for the note `subject` names, in `state`.
pub(super) fn decide(
	store: &Store,
	looked: &mut Looked,
	waiting: &mut Waiting,
	subject: &Subject<'_>,
	state: State,
	verdict: Verdict,
) -> Result<(), Error> {
	let operation = subject.operation;
	let said = |what: &str| store.log(&format!("{} {what}", subject.said));
	if !matches!(verdict, Verdict::Later(_)) {
		waiting.logged.remove(operation);
		waiting.running.remove(operation);
	}
	match verdict {
		Verdict::Settled(what) => {
			said(&what);
			if fault::fails(Fail::Forget) {
				return Err(Error::io("removing a settled note")(std::io::Error::other(
					"a fault made the removal fail",
				)));
			}
			subject.notes.remove(store.root(), &Name::serving(operation, state))?;
		}
		Verdict::Later(why) => {
			looked.pending = true;
			if waiting.logged.insert(operation.to_owned()) {
				said(&format!("{} ({why}). Looking again later", words::STILL_SETTLING));
			}
		}
		Verdict::GiveUp { why, refused } => {
			let back = refused.map_or_else(String::new, |refused| {
				format!(", and the session would not give its receipt back ({refused})")
			});
			give_up(
				store,
				looked,
				subject.notes,
				operation,
				state,
				&format!(
					"{} {} ({why}){back}, {LEFT_UNSETTLED}. The session keeps the receipt until the access that sent it is revoked",
					subject.said,
					words::DID_NOT_SETTLE
				),
			)?;
		}
	}
	Ok(())
}

/// Leave the note in `state` unsettled as the serving access's give-up, and
/// log `line`.
pub(super) fn give_up(
	store: &Store,
	looked: &mut Looked,
	notes: Notes,
	operation: &str,
	state: State,
	line: &str,
) -> Result<(), Error> {
	if notes.restate(store.root(), operation, state, State::Unsettled)? {
		store.log(line);
		looked.unsettled_now += 1;
	}
	Ok(())
}

/// Look at the live note `subject` names once its turn has ended: settle it,
/// ask again later, or give it up and hand back `receipt`. A give-up first
/// renames the note given back, so no later look sends the request again,
/// whatever the session answers.
pub(super) async fn serving<R: Rooms>(
	rooms: &R,
	store: &Store,
	looked: &mut Looked,
	waiting: &mut Waiting,
	subject: &Subject<'_>,
	receipt: Receipt<'_>,
	verdict: Verdict,
) -> Result<(), Error> {
	match verdict {
		Verdict::GiveUp { why, .. } => {
			if subject
				.notes
				.restate(store.root(), subject.operation, State::Live, State::Giving)?
			{
				hand_back(rooms, store, looked, waiting, subject, receipt, Some(why)).await?;
			}
			Ok(())
		}
		verdict => decide(store, looked, waiting, subject, State::Live, verdict),
	}
}

/// The line for a note in `state` that could not be read, which the look
/// leaves unsettled.
pub(super) fn unreadable(
	store: &Store,
	looked: &mut Looked,
	notes: Notes,
	operation: &str,
	state: State,
	error: &Error,
) -> Result<(), Error> {
	let line = format!(
		"{} {} ({error}), {LEFT_UNSETTLED}",
		notes.label(operation),
		words::COULD_NOT_BE_READ
	);
	give_up(store, looked, notes, operation, state, &line)
}
