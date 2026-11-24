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
	ledger::TurnId,
	rooms::{ConversationId, Rooms},
	store::{self, Store},
};
use rooms_application::files::{MAX_FILE_BYTES, sources};
use std::path::{Path, PathBuf};
use tokio::time::{Instant, timeout_at};

/// Why a file was not saved when the share of the reply's deadline that
/// fetches may spend has passed.
const OUT_OF_TIME: &str = "fetching the message's files used up the time they may take of the reply's deadline";

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

fn refused(at: &Path) -> String {
	format!(
		"{} is not a directory of its own, so nothing is saved or removed there",
		at.display()
	)
}

/// The shared `inbox` directory of `workdir`, or none when there is none.
/// The harness writes in its working directory, so a link or a file it left
/// in the inbox's place is refused: saving or removing through it would
/// reach wherever it points.
fn own_inbox(workdir: &Path) -> Result<Option<PathBuf>, String> {
	let shared = workdir.join(DIRECTORY);
	match std::fs::symlink_metadata(&shared) {
		Ok(metadata) if metadata.is_dir() => Ok(Some(shared)),
		Ok(_) => Err(refused(&shared)),
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
		Err(error) => Err(format!("the inbox directory could not be read: {error}")),
	}
}

/// Make an empty inbox for `turn` under `workdir`. Whatever stands at the
/// turn's path is removed first, a link as itself and never what it points
/// to. The shared `inbox` directory must be a directory of its own
/// ([`own_inbox`]), and the turn's directory must be new, so a file the
/// harness left there cannot pass for a fetched one. No harness of this
/// conversation runs while its files are fetched.
fn fresh_inbox(workdir: &Path, turn: TurnId) -> Result<(), String> {
	let shared = workdir.join(DIRECTORY);
	match std::fs::create_dir(&shared) {
		Ok(()) => {}
		Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
		Err(error) => return Err(format!("the inbox directory could not be made: {error}")),
	}
	let own = own_inbox(workdir)?
		.ok_or_else(|| refused(&shared))?
		.join(turn.0.to_string());
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

/// When a run's fetches must end: halfway through what is left of the
/// reply's deadline `ends`, so the agent keeps at least the other half.
pub fn fetch_ends(ends: Instant) -> Instant {
	let now = Instant::now();
	now + ends.saturating_duration_since(now) / 2
}

/// Save the attachments of `triggers`, one outcome per file in trigger order.
/// The Rooms implementation bounds each fetch by its own deadline, and every
/// fetch together ends by `ends`: a file not saved by then is skipped, and
/// a file cut off mid-fetch may leave part of itself in the turn's inbox,
/// which the prompt does not list.
pub async fn fetch<R: Rooms>(
	(rooms, store): (&R, &Store),
	workdir: &Path,
	turn: TurnId,
	triggers: &[Trigger],
	ends: Instant,
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
				_ if Instant::now() >= ends => Err(OUT_OF_TIME.to_owned()),
				_ => match timeout_at(ends, rooms.fetch(file, &destination)).await {
					Ok(Ok(_)) => Ok(()),
					Ok(Err(error)) => Err(format!("it could not be fetched: {error}")),
					Err(_) => Err(OUT_OF_TIME.to_owned()),
				},
			};
			match made {
				Ok(()) => {
					total += file.size;
					row.push(Fetched::Saved(relative.display().to_string()));
				}
				Err(reason) => {
					store.log(&format!("turn {}: attachment {number}: {reason}", turn.0));
					row.push(Fetched::Skipped(reason));
				}
			}
		}
		outcomes.push(row);
	}
	outcomes
}

/// Remove what `fetch` saved for `turn`, inside an inbox of its own
/// ([`own_inbox`]). A directory left behind is only disk the next start
/// sweeps, so a failure is logged and not raised.
pub fn remove(store: &Store, conversation: &ConversationId, turn: TurnId) {
	let workdir = store::work_dir(store.root(), conversation);
	let path = match own_inbox(&workdir) {
		Ok(Some(shared)) => shared.join(turn.0.to_string()),
		Ok(None) => return,
		// best-effort: nothing is removed through an inbox that is not its
		// own, and the saved files are a copy the next turn's inbox replaces.
		Err(reason) => return store.log(&format!("turn {}: {reason}", turn.0)),
	};
	match std::fs::remove_dir_all(&path) {
		Ok(()) => {}
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
		// best-effort: the saved files are a copy, and the sweep at the next
		// start removes the directory again.
		Err(error) => store.log(&format!("removing {}: {error}", path.display())),
	}
}

/// Remove the inbox of every turn that is not open, left by a bot that
/// stopped between finishing a turn and removing its files. Only a working
/// directory and an inbox of their own are swept, so a link in either place
/// reaches nothing. What cannot be read or removed is logged and stays.
pub fn sweep(store: &Store, open: &[TurnId]) {
	// best-effort: each failure below leaves only disk, which the next start
	// sweeps again, and the log names it.
	let failed = |what: &Path, error: &dyn std::fmt::Display| {
		store.log(&format!("sweeping inboxes: {}: {error}", what.display()));
	};
	let root = store::work_root(store.root());
	let conversations = match std::fs::read_dir(&root) {
		Ok(conversations) => conversations,
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
		Err(error) => return failed(&root, &error),
	};
	for conversation in conversations {
		let conversation = match conversation {
			Ok(conversation) => conversation,
			Err(error) => {
				failed(&root, &error);
				continue;
			}
		};
		let workdir = conversation.path();
		match conversation.file_type() {
			Ok(kind) if kind.is_dir() => {}
			Ok(_) => continue,
			Err(error) => {
				failed(&workdir, &error);
				continue;
			}
		}
		let shared = match own_inbox(&workdir) {
			Ok(Some(shared)) => shared,
			Ok(None) => continue,
			Err(reason) => {
				failed(&workdir, &reason);
				continue;
			}
		};
		let turns = match std::fs::read_dir(&shared) {
			Ok(turns) => turns,
			Err(error) => {
				failed(&shared, &error);
				continue;
			}
		};
		for turn in turns {
			let turn = match turn {
				Ok(turn) => turn,
				Err(error) => {
					failed(&shared, &error);
					continue;
				}
			};
			let id = turn.file_name().to_str().and_then(|name| name.parse::<u64>().ok());
			if id.is_some_and(|id| open.contains(&TurnId(id))) {
				continue;
			}
			// A link is removed as itself, never what it points to.
			let removed = match turn.file_type() {
				Ok(kind) if kind.is_dir() => std::fs::remove_dir_all(turn.path()),
				Ok(_) => std::fs::remove_file(turn.path()),
				Err(error) => Err(error),
			};
			if let Err(error) = removed {
				failed(&turn.path(), &error);
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	/// A fetch the session never answers ends with the share of the deadline
	/// fetches may take, and the files after it are skipped without a fetch.
	#[cfg(feature = "test-support")]
	#[tokio::test(start_paused = true)]
	async fn fetches_end_with_their_share_of_the_replys_deadline() {
		use crate::bot::{
			classify::Seq,
			rooms::{Attachment, Cursor, files::Files},
		};
		let scratch = rooms_testing::scratch::Scratch::create("bot-inbox-deadline");
		let (session, work) = (scratch.join("session"), scratch.join("work"));
		std::fs::create_dir_all(&session).unwrap();
		std::fs::create_dir_all(&work).unwrap();
		std::fs::write(session.join("fetch-faults"), "hang\n").unwrap();
		let store = Store::open(&scratch.join("bot")).unwrap();
		let file = |index| Attachment {
			token: "t".into(),
			index,
			name: format!("f{index}"),
			mime: "text/plain".into(),
			size: 1,
			width: 0,
			height: 0,
		};
		let trigger = Trigger {
			seq: Seq(1),
			event: Cursor::start(),
			line: "l".into(),
			from: None,
			text: "x".into(),
			files: vec![file(0), file(1)],
		};
		let ends = fetch_ends(Instant::now() + std::time::Duration::from_secs(60));
		let fetched = tokio::time::timeout(
			std::time::Duration::from_secs(60),
			fetch((&Files::open(&session), &store), &work, TurnId(1), &[trigger], ends),
		)
		.await
		.expect("the fetches outlasted the reply's deadline");
		assert_eq!(
			fetched,
			[[
				Fetched::Skipped(OUT_OF_TIME.into()),
				Fetched::Skipped(OUT_OF_TIME.into())
			]]
		);
		assert!(Instant::now() >= ends);
		let calls = std::fs::read_to_string(session.join("calls.jsonl")).unwrap_or_default();
		assert_eq!(calls.matches("fetch").count(), 1, "{calls}");
	}

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

	#[test]
	fn sweeping_and_removing_reach_only_an_inbox_of_its_own() {
		let scratch = rooms_testing::scratch::Scratch::create("bot-inbox-sweep");
		let store = Store::open(&scratch.join("bot")).unwrap();
		let (linked, kept) = (ConversationId::new("c1"), ConversationId::new("c2"));
		let elsewhere = scratch.join("elsewhere");
		std::fs::create_dir_all(elsewhere.join("5")).unwrap();
		let linked_work = store::work_dir(store.root(), &linked);
		std::fs::create_dir_all(&linked_work).unwrap();
		std::os::unix::fs::symlink(&elsewhere, linked_work.join(DIRECTORY)).unwrap();
		let own = store::work_dir(store.root(), &kept).join(DIRECTORY);
		std::fs::create_dir_all(own.join("7")).unwrap();
		std::fs::create_dir_all(own.join("8")).unwrap();
		sweep(&store, &[TurnId(8)]);
		remove(&store, &linked, TurnId(5));
		assert!(
			elsewhere.join("5").is_dir(),
			"a linked inbox was swept or removed through"
		);
		assert!(
			!own.join("7").exists() && own.join("8").is_dir(),
			"an inbox of its own was not swept"
		);
		let log = std::fs::read_to_string(store.root().join("bot.log")).unwrap();
		assert_eq!(log.matches("is not a directory of its own").count(), 2, "{log}");
	}
}
