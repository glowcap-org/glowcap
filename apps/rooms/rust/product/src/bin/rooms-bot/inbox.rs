//! Attachments in. Before a turn starts, the files its trigger lines carry are
//! saved into the conversation's working directory, so the harness reads them
//! as ordinary files. They land in `inbox/<turn>/<n>-<name>` and the prompt
//! lists each saved path relative to that directory, or why a file was not
//! saved. A file that cannot be saved never fails the turn.
//!
//! Each attempt of a turn starts from an empty inbox, so nothing the harness
//! left there on an earlier attempt passes for a fetched file. The directory
//! goes when its turn is done.
use super::{
	classify::Trigger,
	engine::Env,
	ledger::TurnId,
	rooms::{ConversationId, Rooms},
	store::{self, Store},
};
use rooms_application::files::{MAX_FILE_BYTES, sources};
use std::path::{Path, PathBuf};

/// The most bytes one saved file may hold. It is the most one file carries.
pub const FILE_CAP: usize = MAX_FILE_BYTES;
/// The most bytes one turn saves in all, the most the receiving budget holds.
pub const TURN_CAP: usize = sources::MAX_BYTES;
/// The longest a saved name is, after its index.
const NAME_BYTES: usize = 64;
const DIRECTORY: &str = "inbox";

/// What became of one attachment.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fetched {
	/// Saved at this path, relative to the conversation's working directory.
	Saved(String),
	/// Not saved, for this reason.
	Skipped(String),
}

/// A name a member chose, as a safe single path component: ASCII letters,
/// digits, dot, dash and underscore, no leading dot, bounded in length.
fn sanitize(name: &str) -> String {
	let cleaned: String = name
		.chars()
		.map(|c| {
			if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
				c
			} else {
				'_'
			}
		})
		.collect();
	let trimmed = cleaned.trim_start_matches('.');
	let bounded = trimmed.get(..NAME_BYTES.min(trimmed.len())).unwrap_or_default();
	if bounded.is_empty() {
		"file".into()
	} else {
		bounded.into()
	}
}

fn turn_dir(turn: TurnId) -> PathBuf {
	Path::new(DIRECTORY).join(turn.0.to_string())
}

/// Make an empty inbox for `turn` under `workdir`. Whatever stands at the
/// turn's path is removed first, a link as itself and never what it points
/// to. The shared `inbox` directory must be a directory of its own, and the
/// turn's directory must be new. The harness writes in its working directory,
/// so a link or a file it left there would otherwise send this turn's files
/// wherever it points or pass for one. No harness of this conversation runs
/// while its files are fetched.
fn fresh_inbox(workdir: &Path, turn: TurnId) -> Result<(), String> {
	let refused = |at: &Path| {
		format!(
			"{} is not a directory of its own, so nothing is saved there",
			at.display()
		)
	};
	let shared = workdir.join(DIRECTORY);
	match std::fs::create_dir(&shared) {
		Ok(()) => {}
		Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
		Err(error) => return Err(format!("the inbox directory could not be made: {error}")),
	}
	if !std::fs::symlink_metadata(&shared).is_ok_and(|metadata| metadata.is_dir()) {
		return Err(refused(&shared));
	}
	let own = workdir.join(turn_dir(turn));
	let cleared = match std::fs::symlink_metadata(&own) {
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(error) => Err(error),
		Ok(metadata) if metadata.is_dir() => std::fs::remove_dir_all(&own),
		Ok(_) => std::fs::remove_file(&own),
	};
	cleared.map_err(|error| format!("the last attempt's inbox could not be cleared: {error}"))?;
	std::fs::create_dir(&own).map_err(|error| match error.kind() {
		std::io::ErrorKind::AlreadyExists => refused(&own),
		_ => format!("the inbox directory could not be made: {error}"),
	})
}

/// Save the attachments of `triggers`, one outcome per file in trigger order.
/// The Rooms implementation bounds each fetch by its own deadline.
pub async fn fetch<R: Rooms>(
	env: &Env<'_, R>,
	workdir: &Path,
	turn: TurnId,
	triggers: &[Trigger],
) -> Vec<Vec<Fetched>> {
	let mut total = 0_usize;
	let mut number = 0_usize;
	let inbox = triggers
		.iter()
		.any(|trigger| !trigger.files.is_empty())
		.then(|| fresh_inbox(workdir, turn));
	let mut outcomes = Vec::new();
	for trigger in triggers {
		let mut row = Vec::new();
		for file in &trigger.files {
			number += 1;
			if file.size > FILE_CAP {
				row.push(Fetched::Skipped(format!("it is larger than the {FILE_CAP} byte limit")));
				continue;
			}
			if total.saturating_add(file.size) > TURN_CAP {
				row.push(Fetched::Skipped(format!(
					"this message's files together pass the {TURN_CAP} byte limit"
				)));
				continue;
			}
			let relative = turn_dir(turn).join(format!("{number}-{}", sanitize(&file.name)));
			let destination = workdir.join(&relative);
			let made = match &inbox {
				Some(Err(reason)) => Err(reason.clone()),
				_ => match env.rooms.fetch(file, &destination).await {
					Ok(_) => Ok(()),
					Err(error) => Err(format!("it could not be fetched: {error}")),
				},
			};
			match made {
				Ok(()) => {
					total += file.size;
					row.push(Fetched::Saved(relative.display().to_string()));
				}
				Err(reason) => {
					env.store
						.log(&format!("turn {}: attachment {number}: {reason}", turn.0));
					row.push(Fetched::Skipped(reason));
				}
			}
		}
		outcomes.push(row);
	}
	outcomes
}

/// Remove what `fetch` saved for `turn`. A directory left behind is only disk
/// the next start sweeps, so a failure is logged and not raised.
pub fn remove(store: &Store, conversation: &ConversationId, turn: TurnId) {
	let path = store::work_dir(store.root(), conversation).join(turn_dir(turn));
	match std::fs::remove_dir_all(&path) {
		Ok(()) => {}
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
		// best-effort: the saved files are a copy, and the sweep at the next
		// start removes the directory again.
		Err(error) => store.log(&format!("removing {}: {error}", path.display())),
	}
}

/// Remove the inbox of every turn that is not open, left by a bot that
/// stopped between finishing a turn and removing its files.
pub fn sweep(store: &Store, open: &[TurnId]) {
	let Ok(conversations) = std::fs::read_dir(store::work_root(store.root())) else {
		return;
	};
	for conversation in conversations.flatten() {
		let Ok(turns) = std::fs::read_dir(conversation.path().join(DIRECTORY)) else {
			continue;
		};
		for turn in turns.flatten() {
			let id = turn.file_name().to_str().and_then(|name| name.parse::<u64>().ok());
			if !id.is_some_and(|id| open.contains(&TurnId(id))) {
				// best-effort: a directory that stays is removed at the next start.
				let _ = std::fs::remove_dir_all(turn.path());
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn each_attempt_gets_an_empty_inbox_and_a_planted_link_reaches_nothing() {
		let scratch = rooms_testing::scratch::Scratch::create("bot-inbox");
		let (work, elsewhere) = (scratch.join("work"), scratch.join("elsewhere"));
		std::fs::create_dir_all(&work).unwrap();
		std::fs::create_dir_all(&elsewhere).unwrap();
		std::fs::write(elsewhere.join("kept"), "outside").unwrap();
		fresh_inbox(&work, TurnId(1)).unwrap();
		std::fs::write(work.join("inbox/1/1-planted"), "left by the agent").unwrap();
		fresh_inbox(&work, TurnId(1)).unwrap();
		assert!(work.join("inbox/1").is_dir());
		assert!(!work.join("inbox/1/1-planted").exists(), "a later attempt starts empty");
		// A link in place of the turn's directory is removed as itself.
		std::os::unix::fs::symlink(&elsewhere, work.join("inbox/2")).unwrap();
		fresh_inbox(&work, TurnId(2)).unwrap();
		assert!(std::fs::symlink_metadata(work.join("inbox/2")).unwrap().is_dir());
		assert!(
			elsewhere.join("kept").exists(),
			"nothing the link pointed to is touched"
		);
		// A link in place of the shared directory is refused.
		std::fs::remove_dir_all(work.join("inbox")).unwrap();
		std::os::unix::fs::symlink(&elsewhere, work.join("inbox")).unwrap();
		assert!(fresh_inbox(&work, TurnId(3)).is_err());
		assert!(!elsewhere.join("3").exists());
	}
}
