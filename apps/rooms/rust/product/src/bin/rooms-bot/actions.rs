//! The bound on what one turn's agent may do in Rooms. The bot opens a
//! budget for a turn before its agent runs and closes it when the turn stops
//! thinking. Each `say`, `send`, or new `command` the agent runs takes one of
//! [`MAX_ACTIONS_PER_TURN`] places first, and a verb that finds no place, or
//! no budget open, refuses before it reaches the session.
//!
//! A budget is the directory `actions/<conversation>` in the bot directory,
//! outside every agent's working directory. The bot creates both directories for its
//! owner alone and checks that `actions` is a private directory before it
//! uses a budget inside it. A budget's `turn` file names the turn
//! that opened it, and only a verb of that turn takes a place, so a process
//! an earlier turn left running never spends a later turn's budget. Each
//! place taken is a file named by its number, made with an exclusive create,
//! so verbs running at once never take one place twice.
use super::{error::Error, ledger::TurnId, rooms::ConversationId, store, words};
use std::{
	io::{ErrorKind, Write},
	os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
	path::{Path, PathBuf},
};

/// The most `say`, `send`, and `command` effects one turn may have.
pub const MAX_ACTIONS_PER_TURN: usize = 12;

const TURN: &str = "turn";

fn budget(budgets: &Path, conversation: &ConversationId) -> PathBuf {
	budgets.join(store::file_stem(conversation))
}

/// The directory of budgets in `root`, kept to its owner, or none while it
/// is missing. A path there that is not a directory is refused.
fn budgets(root: &Path) -> Result<Option<PathBuf>, Error> {
	let directory = root.join("actions");
	let metadata = match std::fs::symlink_metadata(&directory) {
		Ok(metadata) => metadata,
		Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
		Err(error) => return Err(Error::io("reading the directory of action budgets")(error)),
	};
	if !metadata.is_dir() {
		return Err(Error::io("reading the directory of action budgets")(
			std::io::Error::other(format!(
				"{} is not a directory of the bot's own, so no action budget is kept there",
				directory.display()
			)),
		));
	}
	if metadata.permissions().mode() & 0o077 != 0 {
		std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
			.map_err(Error::io("keeping the directory of action budgets to its owner"))?;
	}
	Ok(Some(directory))
}

/// The directory of budgets in `root`, made readable by its owner alone when
/// it is missing.
fn made_budgets(root: &Path) -> Result<PathBuf, Error> {
	match std::fs::DirBuilder::new().mode(0o700).create(root.join("actions")) {
		Ok(()) => {}
		Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
		Err(error) => return Err(Error::io("making the directory of action budgets")(error)),
	}
	budgets(root)?
		.ok_or_else(|| Error::io("making the directory of action budgets")(std::io::Error::from(ErrorKind::NotFound)))
}

/// Create the owner-only file `path`, which must not exist yet.
fn create(path: &Path) -> std::io::Result<std::fs::File> {
	std::fs::OpenOptions::new()
		.write(true)
		.create_new(true)
		.mode(0o600)
		.open(path)
}

/// Open the budget of turn `id`, unless that turn already holds it, so the
/// runs of one turn share one budget.
pub fn open(root: &Path, conversation: &ConversationId, id: TurnId) -> Result<(), Error> {
	let path = budget(&made_budgets(root)?, conversation);
	// tolerant: a budget whose turn file cannot be read is not held, so it is
	// closed and opened again for this turn below.
	let held = std::fs::read_to_string(path.join(TURN)).ok();
	if held.as_deref().map(str::trim) == Some(id.0.to_string().as_str()) {
		return Ok(());
	}
	close(root, conversation)?;
	std::fs::DirBuilder::new()
		.mode(0o700)
		.create(&path)
		.and_then(|()| create(&path.join(TURN)))
		.and_then(|mut turn| turn.write_all(id.0.to_string().as_bytes()))
		.map_err(Error::io("opening a turn's action budget"))
}

/// Close the conversation's budget, so no verb acts for it until a turn
/// opens one again.
pub fn close(root: &Path, conversation: &ConversationId) -> Result<(), Error> {
	let Some(budgets) = budgets(root)? else {
		return Ok(());
	};
	match std::fs::remove_dir_all(budget(&budgets, conversation)) {
		Err(error) if error.kind() != ErrorKind::NotFound => Err(Error::io("closing a turn's action budget")(error)),
		_ => Ok(()),
	}
}

/// Take one place in the budget of turn `id`, which must be the turn
/// running in `conversation`.
pub fn spend(root: &Path, conversation: &ConversationId, id: TurnId) -> Result<(), Error> {
	// tolerant: a budget whose turn file cannot be read is no budget of this
	// turn, which is refused below like a closed one.
	let held = budgets(root)?
		.map(|budgets| budget(&budgets, conversation))
		.filter(|path| std::fs::read_to_string(path.join(TURN)).is_ok_and(|held| held.trim() == id.0.to_string()));
	let Some(path) = held else {
		return Err(Error::Usage(format!(
			"say, send, and command {}",
			words::ONLY_WHILE_TURN
		)));
	};
	for place in 1..=MAX_ACTIONS_PER_TURN {
		match create(&path.join(place.to_string())) {
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
			matches!(spend(&dir, &conversation, TurnId(1)), Err(Error::Usage(_))),
			"no turn is open"
		);
		open(&dir, &conversation, TurnId(1)).unwrap();
		for _ in 0..MAX_ACTIONS_PER_TURN {
			spend(&dir, &conversation, TurnId(1)).unwrap();
		}
		let Err(Error::Usage(refused)) = spend(&dir, &conversation, TurnId(1)) else {
			panic!("a place past the bound was taken");
		};
		assert!(refused.contains(&MAX_ACTIONS_PER_TURN.to_string()), "{refused}");
		open(&dir, &conversation, TurnId(1)).unwrap();
		assert!(
			spend(&dir, &conversation, TurnId(1)).is_err(),
			"a second run of the turn started over"
		);
		open(&dir, &conversation, TurnId(2)).unwrap();
		assert!(
			matches!(spend(&dir, &conversation, TurnId(1)), Err(Error::Usage(_))),
			"an earlier turn spent the next turn's budget"
		);
		spend(&dir, &conversation, TurnId(2)).unwrap();
		close(&dir, &conversation).unwrap();
		assert!(
			spend(&dir, &conversation, TurnId(2)).is_err(),
			"a closed budget took a place"
		);
	}

	#[test]
	fn budgets_are_kept_to_their_owner_and_never_reached_through_a_symlink() {
		let dir = Scratch::create("bot-actions-private");
		let conversation = ConversationId::new("c");
		open(&dir, &conversation, TurnId(1)).unwrap();
		spend(&dir, &conversation, TurnId(1)).unwrap();
		let path = budget(&dir.join("actions"), &conversation);
		for (entry, mode) in [
			(dir.join("actions"), 0o700),
			(path.clone(), 0o700),
			(path.join(TURN), 0o600),
			(path.join("1"), 0o600),
		] {
			let found = std::fs::symlink_metadata(&entry).unwrap().permissions().mode() & 0o777;
			assert_eq!(found, mode, "{}", entry.display());
		}
		close(&dir, &conversation).unwrap();
		std::fs::remove_dir(dir.join("actions")).unwrap();
		let elsewhere = dir.join("elsewhere");
		std::fs::create_dir(&elsewhere).unwrap();
		std::os::unix::fs::symlink(&elsewhere, dir.join("actions")).unwrap();
		assert!(open(&dir, &conversation, TurnId(2)).is_err());
		assert!(spend(&dir, &conversation, TurnId(2)).is_err());
		assert!(close(&dir, &conversation).is_err());
		assert!(
			std::fs::read_dir(&elsewhere).unwrap().next().is_none(),
			"a budget was written through the symlink"
		);
	}
}
