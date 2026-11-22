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
//! lines the turn was shown, the only ones `--dm` reaches from a room.
use super::{error::Error, ledger::TurnId, rooms::ConversationId, store};
use std::{
	io::ErrorKind,
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
}
