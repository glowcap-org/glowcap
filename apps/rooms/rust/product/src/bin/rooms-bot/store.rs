//! The bot directory, which `serve`, `status`, and `ready` name with `--dir`
//! and a turn verb takes from its turn. It belongs to the bot alone and says nothing about where the session runs. Holding the
//! lease makes `serve` the only writer, and every document is replaced
//! atomically so a crash leaves the old or the new one, never a torn file.
//!
//! | Path | Holds |
//! | --- | --- |
//! | `config.json` | the settings `serve` resolved |
//! | `session.link` | the session link the bot attaches with, owner-only |
//! | `peer.json` | the bot's own CapTP identity, owner-only |
//! | `turns.json` | the turn ledger and the durable cursor |
//! | `sessions.json` | each harness's session per conversation |
//! | `conversations.json` | the conversations the bot keeps state for |
//! | `status.json` | what `bot status` reports |
//! | `context/<conversation>.json` | the ring of recent lines that did not address the bot |
//! | `work/<conversation>/` | the harness's working directory, with `inbox/<turn>/` holding the files a turn was sent |
//! | `harness/<adapter>/<conversation>/` | an adapter's own state, out of the model's reach |
//! | `groups/<conversation>` | the process group of a running harness |
//! | `home/` | the agent's own place, shared by every conversation, with `memory/` holding its memories. The bot creates it and never changes it |
//! | `bot.log` | diagnostics |
//!
//! A conversation's state is spread over `context`, `work`, `harness`, and
//! `groups`, each named by [`file_stem`]. A group record lives only while its
//! harness runs. [`Store::forget_conversation`] removes the other three.
use super::{error::Error, rooms::ConversationId, stamp};
use rooms_platform::storage::{self, Directory, StorageError, atomic};
use serde::{Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
	fs::OpenOptions,
	io::Write,
	path::{Path, PathBuf},
};

const LEASE: &str = "lock";
const LOG: &str = "bot.log";
/// The log is moved aside once it passes this size, replacing the older copy.
const LOG_LIMIT: u64 = 1024 * 1024;
/// The most bytes of one logged detail, such as a harness's stderr, the log
/// keeps. The rest is counted, not written.
const MAX_LOG_LINE_BYTES: usize = 4096;
/// The most a state document may hold, which every reader of one enforces.
pub const MAX_DOCUMENT_BYTES: usize = 4 * 1024 * 1024;

pub struct Store {
	lease: Directory,
}

/// The absolute bot directory, without holding it.
pub fn directory(dir: &Path) -> Result<PathBuf, Error> {
	std::path::absolute(dir).map_err(Error::io("resolving the bot directory path"))
}

/// `value` as the bytes of document `name`, refused when they pass `limit`.
pub fn encode<T: Serialize>(name: &str, value: &T, limit: usize) -> Result<Vec<u8>, Error> {
	let bytes = serde_json::to_vec(value).map_err(|error| Error::state(name, error))?;
	if bytes.len() > limit {
		return Err(Error::TooLarge {
			file: name.into(),
			bytes: bytes.len(),
			limit,
		});
	}
	Ok(bytes)
}

/// The directory that holds every conversation's harness working directory.
pub fn work_root(root: &Path) -> PathBuf {
	root.join("work")
}

/// The harness working directory of one conversation in the bot directory
/// `root`. The paths `send` may post are confined beneath it.
pub fn work_dir(root: &Path, conversation: &ConversationId) -> PathBuf {
	work_root(root).join(file_stem(conversation))
}

impl Store {
	/// Take the lease. A second `serve` on the same bot directory is refused.
	pub fn open(dir: &Path) -> Result<Self, Error> {
		let path = directory(dir)?;
		match Directory::open(path.clone(), LEASE) {
			Ok(lease) => Ok(Self { lease }),
			Err(StorageError::InUse(path)) => Err(Error::Lease(path)),
			Err(error) => Err(error.into()),
		}
	}

	pub fn root(&self) -> &Path {
		self.lease.path()
	}

	pub fn read<T: DeserializeOwned>(&self, name: &str) -> Result<Option<T>, Error> {
		read_document(self.root(), name)
	}

	/// Read a document allowed to grow past the usual bound, up to `max` bytes.
	pub fn read_bounded<T: DeserializeOwned>(&self, name: &str, max: usize) -> Result<Option<T>, Error> {
		read_limited(self.root(), name, max)
	}

	/// Replace a document with `value`. One that would pass
	/// [`MAX_DOCUMENT_BYTES`], the bound every reader enforces, is refused
	/// before anything is written.
	pub fn write<T: Serialize>(&self, name: &str, value: &T) -> Result<(), Error> {
		self.write_bounded(name, value, MAX_DOCUMENT_BYTES)
	}

	/// Replace a document allowed to grow past the usual bound, up to `max`
	/// bytes, as [`Store::read_bounded`] reads it back.
	pub fn write_bounded<T: Serialize>(&self, name: &str, value: &T, max: usize) -> Result<(), Error> {
		self.write_bytes(name, &encode(name, value, max)?)
	}

	/// Replace a document with bytes the caller already encoded and measured.
	pub fn write_bytes(&self, name: &str, bytes: &[u8]) -> Result<(), Error> {
		atomic::replace(&self.lease, name, [bytes])?;
		Ok(())
	}

	/// Write a document in a subdirectory of the bot directory, creating it.
	pub fn write_in<T: Serialize>(&self, subdirectory: &str, name: &str, value: &T) -> Result<(), Error> {
		let directory = self.root().join(subdirectory);
		let bytes = encode(name, value, MAX_DOCUMENT_BYTES)?;
		std::fs::create_dir_all(&directory).map_err(Error::io("creating a bot state directory"))?;
		atomic::replace_at(&directory, name, [&bytes[..]])?;
		Ok(())
	}

	pub fn read_in<T: DeserializeOwned>(&self, subdirectory: &str, name: &str) -> Result<Option<T>, Error> {
		read_document(&self.root().join(subdirectory), name)
	}

	/// The harness working directory of one conversation, created on demand.
	pub fn workdir(&self, conversation: &ConversationId) -> Result<PathBuf, Error> {
		let path = work_dir(self.root(), conversation);
		std::fs::create_dir_all(&path).map_err(Error::io("creating a harness working directory"))?;
		Ok(path)
	}

	/// The directory an adapter keeps one conversation's state in. The
	/// adapter's own preparation creates it.
	pub fn harness_state(&self, adapter: &str, conversation: &ConversationId) -> PathBuf {
		self.root().join("harness").join(adapter).join(file_stem(conversation))
	}

	/// Remove one conversation's context ring, working directory, and every
	/// adapter's state for it. A conversation with a running harness is never
	/// forgotten, so its group record is not touched.
	pub fn forget_conversation(&self, conversation: &ConversationId) -> Result<(), Error> {
		let stem = file_stem(conversation);
		let gone = |result: std::io::Result<()>| match result {
			Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
			other => other,
		};
		let context = self.root().join("context");
		for name in [format!("{stem}.json"), format!("{stem}.json.unreadable")] {
			gone(std::fs::remove_file(context.join(name))).map_err(Error::io("removing a context ring"))?;
		}
		gone(std::fs::remove_dir_all(work_dir(self.root(), conversation)))
			.map_err(Error::io("removing a harness working directory"))?;
		let adapters = match std::fs::read_dir(self.root().join("harness")) {
			Ok(adapters) => adapters,
			Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
			Err(error) => return Err(Error::io("listing harness state")(error)),
		};
		for adapter in adapters {
			let adapter = adapter.map_err(Error::io("listing harness state"))?;
			gone(std::fs::remove_dir_all(adapter.path().join(&stem))).map_err(Error::io("removing harness state"))?;
		}
		Ok(())
	}

	/// The directory that holds the process group records, created on demand.
	pub fn groups(&self) -> Result<PathBuf, Error> {
		let path = self.root().join("groups");
		std::fs::create_dir_all(&path).map_err(Error::io("creating the harness group directory"))?;
		Ok(path)
	}

	/// Append one diagnostic line. A log that cannot be written must not stop
	/// the bot, so the failure goes to stderr instead.
	pub fn log(&self, line: &str) {
		self.logger().line(line);
	}

	/// A handle that appends to the same log without holding the lease.
	pub fn logger(&self) -> Log {
		Log(self.root().join(LOG))
	}
}

/// Appends diagnostic lines to `bot.log`.
#[derive(Clone)]
pub struct Log(PathBuf);

impl Log {
	/// The log of the bot directory `root`, for a process that holds no lease.
	pub fn in_directory(root: &Path) -> Self {
		Self(root.join(LOG))
	}

	pub fn line(&self, line: &str) {
		let rotate = std::fs::metadata(&self.0).is_ok_and(|meta| meta.len() > LOG_LIMIT);
		if rotate && let Err(error) = std::fs::rename(&self.0, self.0.with_file_name("bot.log.1")) {
			eprintln!("rooms-bot: rotating {LOG}: {error}");
		}
		// The line is escaped once, so the error output a terminal shows takes
		// the same safe form the file would have held.
		let line = single_line(line);
		let written = OpenOptions::new()
			.create(true)
			.append(true)
			.open(&self.0)
			.and_then(|mut file| writeln!(file, "{} {line}", stamp::now()));
		if let Err(error) = written {
			eprintln!("rooms-bot: writing {LOG}: {error}: {line}");
		}
	}
}

/// `text` with every newline and other control character written as an
/// escape, so a logged detail, such as a harness's stderr, can never start a
/// line of its own, cut at [`MAX_LOG_LINE_BYTES`].
fn single_line(text: &str) -> String {
	let mut out = String::with_capacity(text.len().min(MAX_LOG_LINE_BYTES));
	for (at, ch) in text.char_indices() {
		let before = out.len();
		if ch.is_control() {
			out.extend(ch.escape_default());
		} else {
			out.push(ch);
		}
		if out.len() > MAX_LOG_LINE_BYTES {
			out.truncate(before);
			out.push_str(&format!(" ({} more bytes not logged)", text.len() - at));
			break;
		}
	}
	out
}

/// Read a document of the bot directory at `directory` without holding its
/// lease, so a command can look beside a `serve` that holds it. Only an
/// atomically replaced document is read this way, so it is the old or the
/// new one, never a torn file.
pub fn read_unleased<T: DeserializeOwned>(directory: &Path, name: &str) -> Result<Option<T>, Error> {
	read_document(directory, name)
}

fn read_document<T: DeserializeOwned>(directory: &Path, name: &str) -> Result<Option<T>, Error> {
	read_limited(directory, name, MAX_DOCUMENT_BYTES)
}

fn read_limited<T: DeserializeOwned>(directory: &Path, name: &str, max: usize) -> Result<Option<T>, Error> {
	let Some(bytes) = storage::read(&directory.join(name), max)? else {
		return Ok(None);
	};
	serde_json::from_slice(&bytes)
		.map(Some)
		.map_err(|error| Error::unreadable(name, error))
}

/// A file name for a conversation id. Plain ids stay readable, any other byte
/// is percent-encoded, and a very long id is replaced by its digest.
pub fn file_stem(conversation: &ConversationId) -> String {
	let mut stem = String::new();
	for byte in conversation.as_str().bytes() {
		if byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_' {
			stem.push(char::from(byte));
		} else {
			stem.push_str(&format!("%{byte:02x}"));
		}
	}
	if stem.len() > 96 {
		let digest = Sha256::digest(conversation.as_str().as_bytes());
		stem = format!(
			"h-{}",
			digest
				.iter()
				.take(16)
				.map(|byte| format!("{byte:02x}"))
				.collect::<String>()
		);
	}
	stem
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	#[test]
	fn file_stems_are_safe_distinct_and_bounded() {
		let stem = |id: &str| file_stem(&ConversationId::new(id));
		assert_eq!(stem("room-1_a"), "room-1_a");
		assert_eq!(stem("../x"), "%2e%2e%2fx");
		assert_ne!(stem("a/b"), stem("a%2fb"));
		assert!(stem(&"x".repeat(500)).len() < 40);
		assert_ne!(stem(&"x".repeat(500)), stem(&"y".repeat(500)));
	}

	#[test]
	fn a_logged_line_cannot_forge_another() {
		assert_eq!(single_line("a\nb\r\x1b[0m\tc"), "a\\nb\\r\\u{1b}[0m\\tc");
		assert_eq!(single_line("plain é"), "plain é");
		let long = format!("{}\n", "é".repeat(MAX_LOG_LINE_BYTES));
		let kept = single_line(&long);
		assert!(
			kept.ends_with(&format!(" ({} more bytes not logged)", long.len() - MAX_LOG_LINE_BYTES)),
			"{kept}"
		);
		assert!(kept.len() < MAX_LOG_LINE_BYTES + 40);
	}

	#[test]
	fn a_second_open_is_refused_and_documents_round_trip() {
		let dir = Scratch::create("bot-store");
		let store = Store::open(&dir).unwrap();
		assert!(matches!(Store::open(&dir), Err(Error::Lease(_))));
		store.write("doc.json", &vec![1, 2, 3]).unwrap();
		assert_eq!(store.read::<Vec<u8>>("doc.json").unwrap(), Some(vec![1, 2, 3]));
		assert_eq!(store.read::<Vec<u8>>("missing.json").unwrap(), None);
		std::fs::write(store.root().join("bad.json"), "{").unwrap();
		assert!(matches!(
			store.read::<Vec<u8>>("bad.json"),
			Err(Error::Unreadable { .. })
		));
		drop(store);
		assert!(Store::open(&dir).is_ok(), "the lease is released on drop");
	}
}
