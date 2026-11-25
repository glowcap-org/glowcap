//! The notes in one directory of the bot directory, `opens/` for `--dm` opens
//! and `turn-actions/` for the agent's actions: what a file name says, and the
//! bounded read, write, listing, rename, and removal of a note. The name
//! grammar is the one `opens` documents. Nothing here decides what a note's
//! state should be.
//!
//! A directory of notes is the bot's own: it is made readable by its owner
//! alone, and one that is a link or no directory is refused, so no note is
//! written to or read from a place someone else chose.
use crate::bot::{error::Error, store};
use rooms_platform::storage::{Directory, StorageError};
use serde::{Serialize, de::DeserializeOwned};
use std::{
	io::ErrorKind,
	os::unix::fs::{DirBuilderExt, PermissionsExt},
	path::{Path, PathBuf},
	time::Duration,
};

/// The most bytes of one note, which every reader of one enforces.
const MAX_NOTE_BYTES: usize = 64 * 1024;
pub(super) const LIVE: &str = ".json";
/// A note whose request this access can never settle, or that could not be
/// read.
pub(super) const UNSETTLED: &str = ".json.unsettled";
/// A note whose request this access gave up on and is giving back.
pub(super) const GIVING: &str = ".json.giving";
/// Appended to a note's name while an access other than the serving one sent
/// it, whatever its other state.
const REPLACED: &str = ".replaced";
/// How long a writer waits for another that is counting the notes, which
/// holds the count for one small write.
pub(super) const COUNT_WAIT: Duration = Duration::from_secs(5);
/// How long the serving loop's rename waits for that lease. The loop runs on
/// one thread that every turn shares, so it waits for one small write and no
/// longer: a lease still held after this is the loop's transient failure, and
/// it asks again on its own backoff.
const RENAME_WAIT: Duration = Duration::from_millis(100);
const COUNT_LEASE: &str = "lock";

/// One directory of notes, and the directory beside it whose lease file makes
/// a count and a write one step, and each rename of a note one the count sees
/// whole. The lease is not among the notes, where every file is a note.
#[derive(Clone, Copy, Debug)]
pub(in crate::bot) struct Notes {
	pub(in crate::bot) directory: &'static str,
	count: &'static str,
	/// How a log line names the note of an operation.
	label: fn(&str) -> String,
}

/// Whether `operation` is one the bot mints, 32 hexadecimal digits, so it
/// can name a file.
pub(super) fn minted(operation: &str) -> bool {
	operation.len() == 32 && operation.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Where a note stands with the serving access.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum State {
	/// The serving loop looks at it until its request settles.
	Live,
	/// The loop never looks at it again.
	Unsettled,
	/// The bot gave the request up and asks the session to give its receipt
	/// back. The request is never sent again, so the session's answer for it
	/// is final even if the receipt later leaves the session.
	Giving,
}

/// Which access holds the request's receipt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Custody {
	Serving,
	/// Another access, which sent the request.
	Another,
}

/// What a note's file name says: the operation and two independent states.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Name {
	pub(super) operation: String,
	pub(super) state: State,
	pub(super) custody: Custody,
}

impl Name {
	/// The name of a live note the serving access sent.
	pub(super) fn live(operation: &str) -> Self {
		Self::serving(operation, State::Live)
	}

	/// The name of a note the serving access sent, in `state`.
	pub(super) fn serving(operation: &str, state: State) -> Self {
		Self {
			operation: operation.to_owned(),
			state,
			custody: Custody::Serving,
		}
	}

	/// The name a directory entry spells, or none for a file that is no note.
	fn parse(file: &str) -> Option<Self> {
		let (rest, custody) = match file.strip_suffix(REPLACED) {
			Some(rest) => (rest, Custody::Another),
			None => (file, Custody::Serving),
		};
		let (operation, state) = if let Some(operation) = rest.strip_suffix(UNSETTLED) {
			(operation, State::Unsettled)
		} else if let Some(operation) = rest.strip_suffix(GIVING) {
			(operation, State::Giving)
		} else {
			(rest.strip_suffix(LIVE)?, State::Live)
		};
		minted(operation).then(|| Self {
			operation: operation.to_owned(),
			state,
			custody,
		})
	}

	/// The file name this note has.
	pub(super) fn file(&self) -> String {
		let state = match self.state {
			State::Live => LIVE,
			State::Unsettled => UNSETTLED,
			State::Giving => GIVING,
		};
		let replaced = match self.custody {
			Custody::Serving => "",
			Custody::Another => REPLACED,
		};
		format!("{}{state}{replaced}", self.operation)
	}

	/// This note's operation under another state and custody.
	pub(super) fn with(&self, state: State, custody: Custody) -> Self {
		Self {
			operation: self.operation.clone(),
			state,
			custody,
		}
	}
}

/// The notes in a directory, as each one's name says.
pub(super) struct Listed {
	/// The operations of the live notes the serving access sent, in name order.
	pub(super) live: Vec<String>,
	/// The operations of the notes the serving access is giving back, in name
	/// order.
	pub(super) giving: Vec<String>,
	/// Unsettled notes the serving access sent, or that could not be read: each
	/// holds one of its places in the session.
	pub(super) unsettled: u64,
	/// Notes, live or unsettled, another access sent. The session holds their
	/// receipts under that access, and the serving one can settle none of
	/// them, so none counts against it.
	pub(super) replaced: u64,
}
impl Listed {
	/// The requests of the serving access the session has not settled: the
	/// unsettled notes and the notes being given back, which hold their places
	/// until the session takes the receipt.
	pub(super) fn unsettled_now(&self) -> u64 {
		self.unsettled + self.giving.len() as u64
	}

	/// The notes of the serving access, live, given up, or unsettled, except
	/// the live one under `except`: each can hold one of the session's places.
	pub(super) fn held_except(&self, except: &str) -> u64 {
		self.live.iter().filter(|live| *live != except).count() as u64 + self.unsettled_now()
	}
}

impl Notes {
	pub(super) const fn new(directory: &'static str, count: &'static str, label: fn(&str) -> String) -> Self {
		Self {
			directory,
			count,
			label,
		}
	}

	/// The directory of notes in `root`, which must be one of the bot's own.
	/// `make` creates it, readable by its owner alone, when it is missing.
	/// Answers none for a missing directory that is not made.
	fn own(self, root: &Path, make: bool) -> Result<Option<PathBuf>, Error> {
		let directory = root.join(self.directory);
		if make {
			match std::fs::DirBuilder::new()
				.recursive(true)
				.mode(0o700)
				.create(&directory)
			{
				Ok(()) => {}
				Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
				Err(error) => return Err(Error::io("making a directory of notes")(error)),
			}
		}
		let metadata = match std::fs::symlink_metadata(&directory) {
			Ok(metadata) => metadata,
			Err(error) if error.kind() == ErrorKind::NotFound && !make => return Ok(None),
			Err(error) => return Err(Error::io("reading a directory of notes")(error)),
		};
		if !metadata.is_dir() {
			return Err(Error::io("reading a directory of notes")(std::io::Error::other(
				format!(
					"{} is not a directory of the bot's own, so no note is kept there",
					directory.display()
				),
			)));
		}
		if metadata.permissions().mode() & 0o077 != 0 {
			std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
				.map_err(Error::io("keeping a directory of notes to its owner"))?;
		}
		Ok(Some(directory))
	}

	/// Write the live note of `operation`, in a directory of the bot's own.
	/// The replace is atomic and durable, so a reader finds the whole note or
	/// none, and a note written survives a crash.
	pub(super) fn write<T: Serialize>(self, root: &Path, operation: &str, value: &T) -> Result<(), Error> {
		self.own(root, true)?;
		store::write_unleased(root, self.directory, &Name::live(operation).file(), value)
	}

	/// Read the note the serving access sent under `operation` in `state`,
	/// which no other reader may hold open longer than [`MAX_NOTE_BYTES`].
	pub(super) fn read<T: DeserializeOwned>(
		self,
		root: &Path,
		operation: &str,
		state: State,
	) -> Result<Option<T>, Error> {
		let Some(directory) = self.own(root, false)? else {
			return Ok(None);
		};
		store::read_unleased_bounded(&directory, &Name::serving(operation, state).file(), MAX_NOTE_BYTES)
	}

	/// Remove the file `name` spells, in a directory of the bot's own.
	/// Returns whether it was there.
	pub(super) fn remove(self, root: &Path, name: &Name) -> Result<bool, Error> {
		let Some(directory) = self.own(root, false)? else {
			return Ok(false);
		};
		match std::fs::remove_file(directory.join(name.file())) {
			Ok(()) => Ok(true),
			Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
			Err(error) => Err(Error::io("removing a settled note")(error)),
		}
	}

	/// Hold the lease a count of the notes takes, for as long as the returned
	/// value lives.
	pub(super) fn counting(self, root: &Path) -> Result<Directory, StorageError> {
		Directory::open_within(root.join(self.count), COUNT_LEASE, COUNT_WAIT)
	}

	/// The same lease for a caller that must not stay long, as the serving
	/// loop's: the wait is [`RENAME_WAIT`].
	fn counting_briefly(self, root: &Path) -> Result<Directory, StorageError> {
		Directory::open_within(root.join(self.count), COUNT_LEASE, RENAME_WAIT)
	}

	/// Rename the note `from` spells to `to`. Returns whether it was still
	/// there. The rename holds the counting lease, because a directory listing
	/// that runs during a rename can see the note under neither name or under
	/// both, and a writer counting the notes would then admit one past its
	/// limit or refuse one early. A lease held past [`RENAME_WAIT`] is a
	/// transient failure, so the serving loop never sleeps on its thread for a
	/// verb's count.
	pub(super) fn rename(self, root: &Path, from: &Name, to: &Name, what: &'static str) -> Result<bool, Error> {
		let _counting = self.counting_briefly(root)?;
		let Some(directory) = self.own(root, false)? else {
			return Ok(false);
		};
		match std::fs::rename(directory.join(from.file()), directory.join(to.file())) {
			Ok(()) => Ok(true),
			Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
			Err(error) => Err(Error::io(what)(error)),
		}
	}

	/// Move the serving access's note under `operation` from `from` to `to`.
	/// Returns whether it was still there.
	pub(super) fn restate(self, root: &Path, operation: &str, from: State, to: State) -> Result<bool, Error> {
		let what = match to {
			State::Live => "keeping a note live",
			State::Unsettled => "leaving an unsettled note",
			State::Giving => "marking a note given back",
		};
		self.rename(
			root,
			&Name::serving(operation, from),
			&Name::serving(operation, to),
			what,
		)
	}

	/// Every note in the directory, in name order.
	pub(super) fn names(self, root: &Path) -> Result<Vec<Name>, Error> {
		let Some(directory) = self.own(root, false)? else {
			return Ok(Vec::new());
		};
		let listing = |error| Error::io("listing a directory of notes")(error);
		let mut found = Vec::new();
		for entry in std::fs::read_dir(directory).map_err(listing)? {
			found.extend(entry.map_err(listing)?.file_name().to_str().and_then(Name::parse));
		}
		found.sort_by(|a, b| a.operation.cmp(&b.operation));
		Ok(found)
	}

	/// The notes in the directory, counted and sorted by what their names say.
	pub(super) fn listed(self, root: &Path) -> Result<Listed, Error> {
		let mut listed = Listed {
			live: Vec::new(),
			giving: Vec::new(),
			unsettled: 0,
			replaced: 0,
		};
		for name in self.names(root)? {
			match (name.custody, name.state) {
				(Custody::Another, _) => listed.replaced += 1,
				(Custody::Serving, State::Unsettled) => listed.unsettled += 1,
				(Custody::Serving, State::Live) => listed.live.push(name.operation),
				(Custody::Serving, State::Giving) => listed.giving.push(name.operation),
			}
		}
		Ok(listed)
	}

	/// How a log line names the note of `operation`.
	pub(super) fn label(self, operation: &str) -> String {
		(self.label)(operation)
	}
}

#[cfg(test)]
mod tests;
