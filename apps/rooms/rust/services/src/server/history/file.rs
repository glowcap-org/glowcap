//! Where kept lines persist: one JSONL file per room under `history/`, one
//! row per line, appended in place and compacted back to the kept tail once
//! the file has grown past the compaction point. Retention lives in the
//! policy's index. This worker only persists what the index admitted, one
//! change at a time, in order. The directory is leased to one server, so two
//! servers pointed at one `--storage` refuse rather than interleave, and a
//! staging file a crashed compaction left behind is swept before restore.
use super::super::error::Error;
use rooms_application::server::history::{
	self, COMPACT_AT, DISK_BYTES, FILE_BYTES, Index, KeptLine, LINES_KEPT, Persist, ROOM_FILES, decode_line,
	encode_line, file_name, room_of_file,
};
use rooms_platform::storage::{Directory, StorageError, atomic};
use std::{
	collections::BTreeMap,
	fs,
	io::{self, Write},
	path::PathBuf,
};

const LOCK: &str = "history.lock";

/// The file backend's own state: the leased directory and, per room, how
/// many rows its file holds, for compaction.
pub(super) struct Backend {
	directory: Directory,
	grown: BTreeMap<String, usize>,
}

/// Restore every persisted room into `index`, then answer the backend that
/// persists what the index admits next. Rooms the index evicted at the
/// global edge lose their files here.
pub(super) async fn restore(directory: PathBuf) -> Result<(Backend, Index), Error> {
	tokio::task::spawn_blocking(move || restore_blocking(directory))
		.await
		.map_err(|e| Error::Worker(e.to_string()))?
}

fn refuse(what: impl Into<String>) -> Error {
	Error::History(what.into())
}

fn restore_blocking(directory: PathBuf) -> Result<(Backend, Index), Error> {
	// The lease is the writability probe, the exclusion PostgreSQL's advisory
	// lock gives the other backend, and the sweep of any staging file a
	// crashed compaction left: `Directory::open` does all three.
	let directory = Directory::open(directory, LOCK).map_err(|error| match error {
		StorageError::InUse(path) => refuse(format!(
			"room history in {} is already held by another server",
			path.display()
		)),
		other => Error::from(other),
	})?;
	let mut rooms = Vec::new();
	let mut disk_bytes = 0u64;
	for entry in fs::read_dir(directory.path())? {
		let entry = entry?;
		let name = entry.file_name();
		let name = name.to_string_lossy().into_owned();
		if name == LOCK {
			continue;
		}
		if !entry.file_type()?.is_file() {
			return Err(refuse(format!("room history contains unexpected entry {name:?}")));
		}
		let Some(room) = room_of_file(&name) else {
			return Err(refuse(format!("room history has an invalid filename {name:?}")));
		};
		let bytes = entry.metadata()?.len();
		if bytes > FILE_BYTES as u64 {
			return Err(refuse(format!("room history file {name:?} exceeds {FILE_BYTES} bytes")));
		}
		disk_bytes += bytes;
		if disk_bytes > DISK_BYTES as u64 {
			return Err(refuse(format!(
				"room history exceeds its {DISK_BYTES}-byte disk ceiling"
			)));
		}
		rooms.push(room);
		if rooms.len() > ROOM_FILES {
			return Err(refuse(format!(
				"room history contains more than {ROOM_FILES} recoverable room files"
			)));
		}
	}
	rooms.sort();
	let mut backend = Backend {
		directory,
		grown: BTreeMap::new(),
	};
	let mut index = Index::default();
	for room in rooms {
		let tail = backend.load(&room)?;
		index.restore_room(&room, tail).map_err(|e| refuse(e.to_string()))?;
	}
	for evicted in index.take_evicted() {
		backend.replace(&evicted, [].iter())?;
	}
	Ok((backend, index))
}

impl Backend {
	fn file_for(&self, room: &str) -> PathBuf {
		self.directory.path().join(file_name(room))
	}
	/// One room's kept tail, and how many rows its file holds.
	fn load(&mut self, room: &str) -> Result<Vec<KeptLine>, Error> {
		let text = match fs::read(self.file_for(room)) {
			Ok(bytes) if bytes.len() > FILE_BYTES => {
				return Err(refuse(format!("room history for {room} exceeds {FILE_BYTES} bytes")));
			}
			Ok(bytes) => {
				String::from_utf8(bytes).map_err(|_| refuse(format!("room history for {room} is not UTF-8")))?
			}
			Err(error) if error.kind() == io::ErrorKind::NotFound => {
				self.grown.insert(room.into(), 0);
				return Ok(Vec::new());
			}
			Err(error) => return Err(error.into()),
		};
		let mut lines = Vec::new();
		let rows: Vec<&str> = text.split('\n').collect();
		for (at, row) in rows.iter().enumerate() {
			if row.is_empty() {
				if at == rows.len() - 1 {
					continue;
				}
				return Err(refuse(format!("room history for {room} contains an empty row")));
			}
			let line = match decode_line(row) {
				Ok(line) => line,
				// An append can tear only at the file's unfinished final row.
				// Every complete row is state, never silently skipped.
				Err(history::Error::Json) if at == rows.len() - 1 && !text.ends_with('\n') => break,
				Err(error) => return Err(refuse(format!("room history for {room}: {error}"))),
			};
			lines.push(line);
		}
		self.grown.insert(room.into(), lines.len());
		if lines.len() > LINES_KEPT {
			lines.drain(..lines.len() - LINES_KEPT);
		}
		Ok(lines)
	}
	fn append(&mut self, room: &str, line: &KeptLine, evicted: Option<&str>) -> Result<(), Error> {
		let count = self.grown.get(room).copied().unwrap_or(0) + 1;
		if count >= COMPACT_AT {
			let mut tail = self.load(room)?;
			tail.push(line.clone());
			if tail.len() > LINES_KEPT {
				tail.drain(..tail.len() - LINES_KEPT);
			}
			self.replace(room, tail.iter())?;
		} else {
			self.grown.insert(room.into(), count);
			let mut row = encode_line(line);
			row.push('\n');
			let path = self.file_for(room);
			// A room's first line creates its file, and a file the directory
			// has not been synced for can vanish with the power, taking the
			// lines the server said it kept. So the directory is synced once,
			// on creation; later appends only sync the file.
			let created = match fs::OpenOptions::new().write(true).create_new(true).open(&path) {
				Ok(file) => Some(file),
				Err(error) if error.kind() == io::ErrorKind::AlreadyExists => None,
				Err(error) => return Err(error.into()),
			};
			let mut file = match created {
				Some(file) => {
					self.directory.sync()?;
					file
				}
				None => fs::OpenOptions::new().append(true).open(&path)?,
			};
			file.write_all(row.as_bytes())?;
			file.sync_all()?;
		}
		if let Some(evicted) = evicted {
			self.replace(evicted, [].iter())?;
		}
		Ok(())
	}
	fn replace<'a>(&mut self, room: &str, tail: impl ExactSizeIterator<Item = &'a KeptLine>) -> Result<(), Error> {
		if tail.len() == 0 {
			match fs::remove_file(self.file_for(room)) {
				Ok(()) => {}
				Err(error) if error.kind() == io::ErrorKind::NotFound => {}
				Err(error) => return Err(error.into()),
			}
			self.grown.remove(room);
			return Ok(());
		}
		let count = tail.len();
		let mut text = String::new();
		for line in tail {
			text.push_str(&encode_line(line));
			text.push('\n');
		}
		atomic::replace(&self.directory, &file_name(room), std::iter::once(text.as_bytes()))?;
		self.grown.insert(room.into(), count);
		Ok(())
	}
	pub(super) fn persist(&mut self, change: Persist) -> Result<(), (&'static str, Error)> {
		match change {
			Persist::Append { room, line, evicted } => self
				.append(&room, &line, evicted.as_deref())
				.map_err(|e| ("keep a line", e)),
			Persist::Replace { room, tail } => self
				.replace(&room, tail.iter().map(std::sync::Arc::as_ref))
				.map_err(|e| ("persist a room's kept lines", e)),
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::atomic::{AtomicU64, Ordering};

	static NEXT: AtomicU64 = AtomicU64::new(0);
	struct Temp(PathBuf);
	impl Temp {
		fn new() -> Self {
			let path = std::env::temp_dir().join(format!(
				"rooms-history-{}-{}",
				std::process::id(),
				NEXT.fetch_add(1, Ordering::Relaxed)
			));
			fs::create_dir_all(&path).unwrap();
			Self(path)
		}
	}
	impl Drop for Temp {
		fn drop(&mut self) {
			let _ = fs::remove_dir_all(&self.0); // tolerant: a leftover temp dir is not a failure
		}
	}

	fn kept(text: &str) -> KeptLine {
		let row = format!(
			r#"{{"version":1,"from":"ada","text":{},"at":7}}"#,
			serde_json::json!(text)
		);
		decode_line(&row).unwrap()
	}

	#[test]
	fn a_crashed_compaction_is_swept_and_the_room_still_restores() {
		let temp = Temp::new();
		let room = temp.0.join(file_name("general"));
		fs::write(&room, format!("{}\n", encode_line(&kept("kept")))).unwrap();
		let debris = temp.0.join(".general.jsonl.tmp-1-1");
		fs::write(&debris, b"half a compaction").unwrap();
		let (_backend, index) = restore_blocking(temp.0.clone()).expect("restores past the debris");
		assert!(!debris.exists(), "the staging file is gone");
		assert_eq!(index.read("general", 10).count(), 1);
	}

	#[test]
	fn a_second_server_on_the_same_history_directory_is_refused() {
		let temp = Temp::new();
		let (_held, _index) = restore_blocking(temp.0.clone()).unwrap();
		let refused = restore_blocking(temp.0.clone()).err().expect("the lease is held");
		assert!(
			refused.to_string().contains("already held by another server"),
			"names the holder: {refused}"
		);
	}

	#[test]
	fn a_new_room_file_is_created_and_appended_to() {
		let temp = Temp::new();
		let (mut backend, _index) = restore_blocking(temp.0.clone()).unwrap();
		backend.append("general", &kept("first"), None).unwrap();
		backend.append("general", &kept("second"), None).unwrap();
		let text = fs::read_to_string(temp.0.join(file_name("general"))).unwrap();
		assert_eq!(text.lines().count(), 2);
		assert_eq!(backend.grown["general"], 2);
	}
}
