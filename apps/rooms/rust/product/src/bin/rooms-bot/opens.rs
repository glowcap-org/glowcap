//! The direct-message opens the bot sent and has not seen settle. A `--dm`
//! open writes its note, `opens/<operation>.json` in the bot directory and
//! outside every agent's working directory, atomically before it sends, and
//! removes it once the open settles. The note holds the base and
//! introduction the open sent, so a look again sends that same one, and the
//! conversation of the turn that sent it. At most [`MAX_OPENS`] notes are
//! live, half the session's receipt places, so pending opens leave the rest
//! to the bot's replies, and a `--dm` that would open past that is refused.
//!
//! While the bot serves, [`settle`] alone looks at the notes, one look at a
//! time on a timer of its own. It looks at a note even while the turn that
//! sent it is thinking: a look sends the same open under the same operation
//! and base, which the session answers from that open's first receipt, so
//! the look and the turn settle it once, and either one removing the note is
//! right. A look that read the note just before the turn removed it may send
//! the open once more after its receipt is given back. The session takes
//! that as a new open, whose route it gives back while the member's
//! conversation is open and keeps otherwise, as the turn's next `--dm` would.
//!
//! An open still pending, or a session that is paused or unreachable, is
//! looked at again later, less often while it stays so. A note is given up
//! only on evidence that this access can never settle it: the session cannot
//! say whether it committed, because the work that would settle it ended, or
//! it refuses the open. A note given up, and one that cannot be read, is set
//! aside as `<operation>.json.unsettled`, logged once, and counted in
//! `status.unsettled_opens`. The bot never reads or removes a note set aside:
//! the session keeps a given-up open's receipt until the access that sent it
//! is revoked, which the bot cannot see, so the operator removes the note
//! (`docs/rooms/bot.md`). A replaced link's access takes
//! [`Look::Last`] at every note before the new link serves, because only the
//! access that sent an open can settle it, and sets aside what that look
//! leaves.
use super::{
	engine::Env,
	error::Error,
	rooms::{Base, ConversationId, Rooms, RoomsError, RoomsErrorKind, Settled},
	store::{self, Store},
};
use crate::bot::engine::Backoff;
use rooms_application::content::session::custody::MAX_EFFECTS;
use rooms_services::session::attached::Introduction;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, convert::Infallible, io::ErrorKind, path::Path, time::Duration};

/// The most opens the bot keeps unsettled at once: half the session's
/// receipt places, since each pending open holds one.
pub const MAX_OPENS: usize = MAX_EFFECTS / 2;
/// How long the owner waits between looks while no open is pending.
const IDLE: Duration = Duration::from_secs(1);

const DIRECTORY: &str = "opens";
const NOTE: &str = ".json";
const SET_ASIDE: &str = ".json.unsettled";

/// One open sent under an operation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Open {
	pub base: Base,
	pub introduction: Introduction,
	/// The conversation of the turn that sent it.
	pub conversation: ConversationId,
}

/// Whether `operation` is one the bot mints, 32 hexadecimal digits, so it
/// can name a file.
fn minted(operation: &str) -> bool {
	operation.len() == 32 && operation.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Note the open about to be sent under `operation`, before it is sent. A
/// note past [`MAX_OPENS`] is removed again and refused, so nothing sends it.
pub fn note(root: &Path, operation: &str, open: &Open) -> Result<(), Error> {
	if !minted(operation) {
		return Err(Error::Usage(format!("operation {operation} is not one the bot made")));
	}
	store::write_unleased(root, DIRECTORY, &format!("{operation}{NOTE}"), open)?;
	let refused = match listed(root) {
		Ok((live, _)) if live.len() <= MAX_OPENS => return Ok(()),
		Ok(_) => Error::Usage(format!(
			"{MAX_OPENS} direct-message opens are still settling, the most the bot keeps: answer here, or use --dm again once one settles"
		)),
		Err(error) => error,
	};
	forget(root, operation)?;
	Err(refused)
}

/// The open noted under `operation`, or none once it settled.
pub fn noted(root: &Path, operation: &str) -> Result<Option<Open>, Error> {
	if !minted(operation) {
		return Ok(None);
	}
	store::read_unleased(&root.join(DIRECTORY), &format!("{operation}{NOTE}"))
}

/// Remove the note of the open under `operation`, which settled.
pub fn forget(root: &Path, operation: &str) -> Result<(), Error> {
	let path = root.join(DIRECTORY).join(format!("{operation}{NOTE}"));
	match std::fs::remove_file(path) {
		Err(error) if error.kind() != ErrorKind::NotFound => Err(Error::io("removing a settled open's note")(error)),
		_ => Ok(()),
	}
}

/// Set the note under `operation` aside. Returns whether it was still there.
fn set_aside(root: &Path, operation: &str) -> Result<bool, Error> {
	let directory = root.join(DIRECTORY);
	let from = directory.join(format!("{operation}{NOTE}"));
	match std::fs::rename(from, directory.join(format!("{operation}{SET_ASIDE}"))) {
		Ok(()) => Ok(true),
		Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
		Err(error) => Err(Error::io("setting an unsettled open aside")(error)),
	}
}

/// The operations of the live notes in name order, and how many notes are
/// set aside.
fn listed(root: &Path) -> Result<(Vec<String>, u64), Error> {
	let entries = match std::fs::read_dir(root.join(DIRECTORY)) {
		Ok(entries) => entries,
		Err(error) if error.kind() == ErrorKind::NotFound => return Ok((Vec::new(), 0)),
		Err(error) => return Err(Error::io("listing the direct-message opens")(error)),
	};
	let (mut live, mut aside) = (Vec::new(), 0);
	for entry in entries {
		let name = entry
			.map_err(Error::io("listing the direct-message opens"))?
			.file_name();
		let Some(name) = name.to_str() else { continue };
		if name.strip_suffix(SET_ASIDE).is_some_and(minted) {
			aside += 1;
		} else if let Some(operation) = name.strip_suffix(NOTE).filter(|operation| minted(operation)) {
			live.push(operation.to_owned());
		}
	}
	live.sort();
	Ok((live, aside))
}

/// Which look the bot takes.
pub enum Look {
	/// The serving bot's, which looks again later at a note still pending.
	Serving,
	/// A replaced link's access's, which sets aside every note it does not
	/// settle.
	Last,
}

/// What one look at every note left.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Looked {
	/// Whether a note is still pending.
	pub pending: bool,
	/// How many notes this look set aside.
	pub set_aside: u64,
	/// How many notes are set aside in all.
	pub unsettled: u64,
}

/// What one look at an open says to do with its note.
enum Verdict {
	Settled(String),
	Later(String),
	GiveUp(String),
}

fn verdict(answer: Result<Settled, RoomsError>) -> Verdict {
	match answer {
		Ok(Settled::Opened(conversation)) => {
			Verdict::Settled(format!("kept its route, as conversation {conversation}"))
		}
		Ok(Settled::Reused(conversation)) => Verdict::Settled(format!(
			"gave its route back, because conversation {conversation} already reaches them"
		)),
		Ok(Settled::Unapplied) => Verdict::Settled("committed nothing".into()),
		Ok(Settled::Released) => Verdict::Settled("could not keep its route, and the session gave it back".into()),
		Ok(Settled::Pending) => Verdict::Later("it is still running in the session".into()),
		Ok(Settled::Unknown) => Verdict::GiveUp(
			"the session cannot say whether it committed, because the work that would settle it ended".into(),
		),
		Err(error) if error.kind == RoomsErrorKind::Revoked => {
			Verdict::Settled("ended with the revoked access, and the session gives its receipt back".into())
		}
		Err(error) if error.kind == RoomsErrorKind::Refused => Verdict::GiveUp(error.to_string()),
		Err(error) => Verdict::Later(error.to_string()),
	}
}

/// Look once at every note. `waiting` holds the operations already logged
/// as pending, so a pending open is logged once.
pub async fn look<R: Rooms>(
	rooms: &R,
	store: &Store,
	kind: &Look,
	waiting: &mut BTreeSet<String>,
) -> Result<Looked, Error> {
	let root = store.root();
	let mut looked = Looked::default();
	for operation in listed(root)?.0 {
		let said = |what: &str| store.log(&format!("the direct-message open under operation {operation} {what}"));
		let open = match store.read_in::<Open>(DIRECTORY, &format!("{operation}{NOTE}")) {
			Ok(Some(open)) => open,
			Ok(None) => continue,
			Err(error) => {
				if set_aside(root, &operation)? {
					said(&format!("could not be read ({error}), so it is set aside"));
					looked.set_aside += 1;
				}
				continue;
			}
		};
		let peer = &open.introduction.peer;
		match verdict(rooms.settle_open(&operation, open.base, &open.introduction).await) {
			Verdict::Settled(what) => {
				said(&format!("to {peer} {what}"));
				forget(root, &operation)?;
				waiting.remove(&operation);
			}
			Verdict::Later(why) if matches!(kind, Look::Serving) => {
				looked.pending = true;
				if waiting.insert(operation.clone()) {
					said(&format!("to {peer} has not settled ({why}). Looking again later"));
				}
			}
			Verdict::Later(why) | Verdict::GiveUp(why) => {
				if set_aside(root, &operation)? {
					said(&format!(
						"to {peer} did not settle ({why}), so the bot gives up on it and sets it aside. The session keeps its receipt until the access that sent it is revoked"
					));
					looked.set_aside += 1;
				}
				waiting.remove(&operation);
			}
		}
	}
	looked.unsettled = listed(root)?.1;
	Ok(looked)
}

/// Settle the notes while the bot serves. Only this owner looks at them in
/// the serving process, so no two looks race, and `status` counts the notes
/// set aside. It never returns: the serving loop's end drops it.
pub async fn settle<R: Rooms>(env: &Env<'_, R>) -> Infallible {
	let mut wait = Backoff::standard();
	let mut waiting = BTreeSet::new();
	let mut failing = None;
	loop {
		let pending = match look(env.rooms, env.store, &Look::Serving, &mut waiting).await {
			Ok(looked) => {
				failing = None;
				let mut facts = env.facts.borrow_mut();
				let changed = facts.unsettled_opens != looked.unsettled;
				facts.unsettled_opens = looked.unsettled;
				if looked.set_aside > 0 {
					let given_up = format!("{} direct-message opens did not settle", looked.set_aside);
					facts.failed(super::status::Activity::Sending, given_up);
				}
				drop(facts);
				if changed || looked.set_aside > 0 {
					env.publish();
				}
				looked.pending
			}
			Err(error) => {
				let text = error.to_string();
				if failing.as_ref() != Some(&text) {
					env.store.log(&format!("settling the direct-message opens: {text}"));
					failing = Some(text);
				}
				true
			}
		};
		let delay = if pending {
			wait.next()
		} else {
			wait.reset();
			IDLE
		};
		tokio::time::sleep(delay).await;
	}
}

#[cfg(test)]
mod tests;
