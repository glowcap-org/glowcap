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
//! twice. An `open-<operation>.json` file keeps the introduction a `--dm`
//! open sent, so looking again at that open in the same turn sends the same
//! one.
use super::{error::Error, ledger::TurnId, rooms::ConversationId, store};
use rooms_services::session::attached::Introduction;
use std::{
	io::{ErrorKind, Write},
	path::{Path, PathBuf},
};

/// The most `say`, `send`, and `command` effects one turn may have.
pub const MAX_ACTIONS_PER_TURN: usize = 12;

const TURN: &str = "turn";

fn budget(root: &Path, conversation: &ConversationId) -> PathBuf {
	root.join("actions").join(store::file_stem(conversation))
}

/// Open the budget of turn `id`, unless that turn already holds it, so the
/// runs of one turn share one budget.
pub fn open(root: &Path, conversation: &ConversationId, id: TurnId) -> Result<(), Error> {
	let path = budget(root, conversation);
	let held = std::fs::read_to_string(path.join(TURN)).ok();
	if held.as_deref().map(str::trim) == Some(id.0.to_string().as_str()) {
		return Ok(());
	}
	close(root, conversation)?;
	std::fs::create_dir_all(&path)
		.and_then(|()| std::fs::write(path.join(TURN), id.0.to_string()))
		.map_err(Error::io("opening a turn's action budget"))
}

/// Close the conversation's budget, so no verb acts for it until a turn
/// opens one again.
pub fn close(root: &Path, conversation: &ConversationId) -> Result<(), Error> {
	match std::fs::remove_dir_all(budget(root, conversation)) {
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

/// Where the turn keeps the introduction sent under `operation`. Only an
/// operation the bot mints, 32 hexadecimal digits, names one.
fn open_file(root: &Path, conversation: &ConversationId, operation: &str) -> Option<PathBuf> {
	(operation.len() == 32 && operation.bytes().all(|byte| byte.is_ascii_hexdigit()))
		.then(|| budget(root, conversation).join(format!("open-{operation}.json")))
}

/// Keep the introduction an open under `operation` is about to send, in the
/// running turn's budget, before it is sent.
pub fn note_open(
	root: &Path,
	conversation: &ConversationId,
	operation: &str,
	introduction: &Introduction,
) -> Result<(), Error> {
	let path = open_file(root, conversation, operation)
		.ok_or_else(|| Error::Usage(format!("operation {operation} is not one the bot made")))?;
	let bytes = serde_json::to_vec(introduction).map_err(|cause| Error::state("an open's introduction", cause))?;
	std::fs::OpenOptions::new()
		.write(true)
		.create_new(true)
		.open(path)
		.and_then(|mut file| file.write_all(&bytes))
		.map_err(Error::io("keeping an open's introduction in the turn's action budget"))
}

/// The introduction this turn sent under `operation`, or none when this turn
/// sent no open under it.
pub fn noted_open(root: &Path, conversation: &ConversationId, operation: &str) -> Result<Option<Introduction>, Error> {
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
		open(&dir, &conversation, TurnId(1)).unwrap();
		for _ in 0..MAX_ACTIONS_PER_TURN {
			spend(&dir, &conversation).unwrap();
		}
		let Err(Error::Usage(refused)) = spend(&dir, &conversation) else {
			panic!("a place past the bound was taken");
		};
		assert!(refused.contains(&MAX_ACTIONS_PER_TURN.to_string()), "{refused}");
		open(&dir, &conversation, TurnId(1)).unwrap();
		assert!(
			spend(&dir, &conversation).is_err(),
			"a second run of the turn started over"
		);
		open(&dir, &conversation, TurnId(2)).unwrap();
		spend(&dir, &conversation).unwrap();
		close(&dir, &conversation).unwrap();
		assert!(spend(&dir, &conversation).is_err(), "a closed budget took a place");
	}

	#[test]
	fn an_open_is_kept_once_for_its_turn_under_an_operation_the_bot_made() {
		let dir = Scratch::create("bot-actions-open");
		let conversation = ConversationId::new("c");
		let operation = "0123456789abcdef0123456789abcdef";
		let introduction = Introduction {
			directory: "d".into(),
			peer: "ann".into(),
			registration: "r".into(),
		};
		open(&dir, &conversation, TurnId(1)).unwrap();
		assert_eq!(noted_open(&dir, &conversation, operation).unwrap(), None);
		note_open(&dir, &conversation, operation, &introduction).unwrap();
		assert_eq!(
			noted_open(&dir, &conversation, operation).unwrap(),
			Some(introduction.clone())
		);
		assert!(
			note_open(&dir, &conversation, operation, &introduction).is_err(),
			"kept twice"
		);
		for refused in ["../escape", "not-hex-but-thirty-two-bytes-long", ""] {
			assert!(
				note_open(&dir, &conversation, refused, &introduction).is_err(),
				"{refused}"
			);
			assert_eq!(noted_open(&dir, &conversation, refused).unwrap(), None, "{refused}");
		}
		open(&dir, &conversation, TurnId(2)).unwrap();
		assert_eq!(
			noted_open(&dir, &conversation, operation).unwrap(),
			None,
			"a new turn starts over"
		);
	}
}
