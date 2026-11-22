//! The bound on what one turn's agent may do in Rooms. The bot opens a
//! budget for a turn before its agent runs and closes it when the turn stops
//! thinking. Each `say`, `send`, or new `command` the agent runs takes one of
//! [`MAX_ACTIONS_PER_TURN`] places first, and a verb that finds no place, or
//! no budget open, refuses before it reaches the session.
//!
//! A budget is the directory `actions/<conversation>` in the bot directory,
//! outside every agent's working directory. Its `turn` file names the turn
//! that opened it, and each place taken is a file named by its number, made
//! with an exclusive create, so verbs running at once never take one place
//! twice. Its `members` file names, one per line, the members whose room
//! lines the turn was shown, the only ones `--dm` reaches from a room. An
//! `open-<operation>.json` file keeps the base and introduction a `--dm` open
//! sent, so looking again at that open in the same turn sends the same one.
//! The note is dropped once the open settles, and closing the budget hands a
//! note still there to the serving bot to settle (`opens`).
use super::{
	error::Error,
	ledger::TurnId,
	opens::{self, Open},
	rooms::ConversationId,
	store,
};
use std::{
	io::{ErrorKind, Write},
	path::{Path, PathBuf},
};

/// The most `say`, `send`, and `command` effects one turn may have.
pub const MAX_ACTIONS_PER_TURN: usize = 12;

const TURN: &str = "turn";
const MEMBERS: &str = "members";

fn budget(root: &Path, conversation: &ConversationId) -> PathBuf {
	root.join("actions").join(store::file_stem(conversation))
}

/// Open the budget of turn `id`, shown room lines from `senders`, unless
/// that turn already holds it, so the runs of one turn share one budget. The
/// members are written before the `turn` file that opens the budget.
pub fn open<'a>(
	root: &Path,
	conversation: &ConversationId,
	id: TurnId,
	senders: impl IntoIterator<Item = Option<&'a str>>,
) -> Result<(), Error> {
	let path = budget(root, conversation);
	let held = std::fs::read_to_string(path.join(TURN)).ok();
	if held.as_deref().map(str::trim) == Some(id.0.to_string().as_str()) {
		return Ok(());
	}
	close(root, conversation)?;
	let senders: std::collections::BTreeSet<&str> = senders.into_iter().flatten().collect();
	let members = senders.into_iter().collect::<Vec<_>>().join("\n");
	std::fs::create_dir_all(&path)
		.and_then(|()| std::fs::write(path.join(MEMBERS), members))
		.and_then(|()| std::fs::write(path.join(TURN), id.0.to_string()))
		.map_err(Error::io("opening a turn's action budget"))
}

/// The members whose room lines the turn running in `conversation` was
/// shown, each nickname once.
pub fn members(root: &Path, conversation: &ConversationId) -> Result<Vec<String>, Error> {
	match std::fs::read_to_string(budget(root, conversation).join(MEMBERS)) {
		Ok(members) => Ok(members.lines().map(str::to_owned).collect()),
		Err(error) if error.kind() == ErrorKind::NotFound => Err(Error::Usage(
			"--dm reaches someone only while a turn in this conversation is running".into(),
		)),
		Err(error) => Err(Error::io("reading the members a turn was shown")(error)),
	}
}

/// Close the conversation's budget, so no verb acts for it until a turn
/// opens one again. Every open still noted in it moves to the opens the
/// serving bot settles first, and a budget whose note cannot move stays.
pub fn close(root: &Path, conversation: &ConversationId) -> Result<(), Error> {
	let path = budget(root, conversation);
	let entries = match std::fs::read_dir(&path) {
		Ok(entries) => entries,
		Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
		Err(error) => return Err(Error::io("closing a turn's action budget")(error)),
	};
	for entry in entries {
		let entry = entry.map_err(Error::io("closing a turn's action budget"))?;
		let name = entry.file_name();
		let noted = name
			.to_str()
			.and_then(|name| name.strip_prefix("open-")?.strip_suffix(".json"));
		if let Some(operation) = noted {
			opens::keep(root, operation, &entry.path())?;
		}
	}
	match std::fs::remove_dir_all(path) {
		Err(error) if error.kind() != ErrorKind::NotFound => Err(Error::io("closing a turn's action budget")(error)),
		_ => Ok(()),
	}
}

/// Take one place in the budget of the turn running in `conversation`.
pub fn spend(root: &Path, conversation: &ConversationId) -> Result<(), Error> {
	let path = budget(root, conversation);
	if !path.join(TURN).is_file() {
		return Err(Error::Usage(
			"say, send, and command act only while a turn in this conversation is running".into(),
		));
	}
	for place in 1..=MAX_ACTIONS_PER_TURN {
		match std::fs::OpenOptions::new()
			.write(true)
			.create_new(true)
			.open(path.join(place.to_string()))
		{
			Ok(_) => return Ok(()),
			Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
			Err(error) => return Err(Error::io("taking a place in the turn's action budget")(error)),
		}
	}
	Err(Error::Usage(format!(
		"a turn may run say, send, and command at most {MAX_ACTIONS_PER_TURN} times in all, and this turn has"
	)))
}

/// Where the turn keeps the open sent under `operation`. Only an operation
/// the bot mints names one.
fn open_file(root: &Path, conversation: &ConversationId, operation: &str) -> Option<PathBuf> {
	opens::minted(operation).then(|| budget(root, conversation).join(format!("open-{operation}.json")))
}

/// Keep the open under `operation` that is about to be sent, in the running
/// turn's budget, before it is sent.
pub fn note_open(root: &Path, conversation: &ConversationId, operation: &str, open: &Open) -> Result<(), Error> {
	let path = open_file(root, conversation, operation)
		.ok_or_else(|| Error::Usage(format!("operation {operation} is not one the bot made")))?;
	let bytes = serde_json::to_vec(open).map_err(|cause| Error::state("an open's introduction", cause))?;
	std::fs::OpenOptions::new()
		.write(true)
		.create_new(true)
		.open(path)
		.and_then(|mut file| file.write_all(&bytes))
		.map_err(Error::io("keeping an open's introduction in the turn's action budget"))
}

/// The open this turn sent under `operation`, or none when this turn sent
/// none under it or it settled.
pub fn noted_open(root: &Path, conversation: &ConversationId, operation: &str) -> Result<Option<Open>, Error> {
	let Some(path) = open_file(root, conversation, operation) else {
		return Ok(None);
	};
	match std::fs::read(&path) {
		Ok(bytes) => serde_json::from_slice(&bytes)
			.map(Some)
			.map_err(|cause| Error::state("an open's introduction", cause)),
		Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
		Err(error) => Err(Error::io(
			"reading an open's introduction from the turn's action budget",
		)(error)),
	}
}

/// Drop the note of the open under `operation`, which settled.
pub fn settled_open(root: &Path, conversation: &ConversationId, operation: &str) -> Result<(), Error> {
	let Some(path) = open_file(root, conversation, operation) else {
		return Ok(());
	};
	match std::fs::remove_file(path) {
		Err(error) if error.kind() != ErrorKind::NotFound => Err(Error::io("dropping a settled open's note")(error)),
		_ => Ok(()),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	#[test]
	fn a_turn_takes_at_most_its_places_and_a_new_turn_starts_over() {
		let dir = Scratch::create("bot-actions");
		let conversation = ConversationId::new("c");
		assert!(
			matches!(spend(&dir, &conversation), Err(Error::Usage(_))),
			"no turn is open"
		);
		open(&dir, &conversation, TurnId(1), []).unwrap();
		for _ in 0..MAX_ACTIONS_PER_TURN {
			spend(&dir, &conversation).unwrap();
		}
		let Err(Error::Usage(refused)) = spend(&dir, &conversation) else {
			panic!("a place past the bound was taken");
		};
		assert!(refused.contains(&MAX_ACTIONS_PER_TURN.to_string()), "{refused}");
		open(&dir, &conversation, TurnId(1), []).unwrap();
		assert!(
			spend(&dir, &conversation).is_err(),
			"a second run of the turn started over"
		);
		open(&dir, &conversation, TurnId(2), []).unwrap();
		spend(&dir, &conversation).unwrap();
		close(&dir, &conversation).unwrap();
		assert!(spend(&dir, &conversation).is_err(), "a closed budget took a place");
	}

	#[test]
	fn a_turn_names_each_member_it_was_shown_once_until_it_closes() {
		let dir = Scratch::create("bot-actions-members");
		let conversation = ConversationId::new("c");
		assert!(members(&dir, &conversation).is_err(), "no turn is open");
		open(
			&dir,
			&conversation,
			TurnId(1),
			[Some("bo"), None, Some("ann"), Some("bo")],
		)
		.unwrap();
		assert_eq!(members(&dir, &conversation).unwrap(), ["ann", "bo"]);
		open(&dir, &conversation, TurnId(1), [Some("cy")]).unwrap();
		assert_eq!(
			members(&dir, &conversation).unwrap(),
			["ann", "bo"],
			"a second run keeps its turn's"
		);
		open(&dir, &conversation, TurnId(2), []).unwrap();
		assert!(members(&dir, &conversation).unwrap().is_empty());
		close(&dir, &conversation).unwrap();
		assert!(members(&dir, &conversation).is_err());
	}

	#[test]
	fn an_open_is_kept_once_for_its_turn_and_a_closing_budget_hands_an_unsettled_one_on() {
		let dir = Scratch::create("bot-actions-open");
		let conversation = ConversationId::new("c");
		let [first, second] = ["0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210"];
		let noted = Open {
			base: crate::bot::rooms::Base(7),
			introduction: rooms_services::session::attached::Introduction {
				directory: "d".into(),
				peer: "ann".into(),
				registration: "r".into(),
			},
			looks: 0,
		};
		open(&dir, &conversation, TurnId(1), []).unwrap();
		assert_eq!(noted_open(&dir, &conversation, first).unwrap(), None);
		note_open(&dir, &conversation, first, &noted).unwrap();
		assert_eq!(noted_open(&dir, &conversation, first).unwrap(), Some(noted.clone()));
		assert!(note_open(&dir, &conversation, first, &noted).is_err(), "kept twice");
		for refused in ["../escape", "not-hex-but-thirty-two-bytes-long", ""] {
			assert!(note_open(&dir, &conversation, refused, &noted).is_err(), "{refused}");
			assert_eq!(noted_open(&dir, &conversation, refused).unwrap(), None, "{refused}");
		}
		note_open(&dir, &conversation, second, &noted).unwrap();
		settled_open(&dir, &conversation, second).unwrap();
		assert_eq!(
			noted_open(&dir, &conversation, second).unwrap(),
			None,
			"a settled open is dropped"
		);
		open(&dir, &conversation, TurnId(2), []).unwrap();
		assert_eq!(
			noted_open(&dir, &conversation, first).unwrap(),
			None,
			"a new turn starts over"
		);
		let kept: Vec<_> = std::fs::read_dir(dir.join("opens"))
			.unwrap()
			.map(|entry| entry.unwrap().file_name().into_string().unwrap())
			.collect();
		assert_eq!(kept, [format!("{first}.json")], "only the unsettled open is handed on");
		let handed: Open = serde_json::from_slice(&std::fs::read(dir.join("opens").join(&kept[0])).unwrap()).unwrap();
		assert_eq!(handed, noted);
	}
}
