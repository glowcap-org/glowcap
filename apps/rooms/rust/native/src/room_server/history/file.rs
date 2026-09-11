//! Where kept lines persist: one JSONL file per room under `history/`, in
//! the form the TypeScript server writes, appended in place and compacted
//! back to the kept tail once the file has grown past the compaction point.
//! Retention lives in the policy's index; this worker only persists what the
//! index admitted, one change at a time, in order.
use super::super::error::Error;
use rooms_application::server::history::{
	self, decode_line, encode_line, file_name, room_of_file, Index, KeptLine, Persist, COMPACT_AT, DISK_BYTES,
	FILE_BYTES, LINES_KEPT, ROOM_FILES,
};
use std::{
	collections::BTreeMap,
	fs,
	io::{self, Write},
	path::{Path, PathBuf},
};

const PROBE: &str = ".open-check.tmp";

/// The file backend's own state: rows on disk per room, for compaction.
pub(super) struct Backend {
	directory: PathBuf,
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
	create(&directory)?;
	let probe = directory.join(PROBE);
	if let Err(error) = fs::remove_file(&probe) {
		if error.kind() != io::ErrorKind::NotFound {
			return Err(error.into());
		}
	}
	// Opening the file is the writability probe; no bytes become state.
	fs::OpenOptions::new().write(true).create_new(true).open(&probe)?;
	fs::remove_file(&probe)?;
	let mut rooms = Vec::new();
	let mut disk_bytes = 0u64;
	for entry in fs::read_dir(&directory)? {
		let entry = entry?;
		let name = entry.file_name();
		let name = name.to_string_lossy().into_owned();
		if !entry.file_type()?.is_file() {
			return Err(refuse(format!("room history contains unexpected entry {name:?}")));
		}
		if let Some(standing) = name.strip_suffix(".tmp") {
			if !directory.join(standing).is_file() {
				return Err(refuse(format!("room history contains an orphaned compaction {name:?}")));
			}
			fs::remove_file(entry.path())?;
			continue;
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

fn create(directory: &Path) -> io::Result<()> {
	let mut builder = fs::DirBuilder::new();
	builder.recursive(true);
	#[cfg(unix)]
	{
		use std::os::unix::fs::DirBuilderExt;
		builder.mode(0o700);
	}
	builder.create(directory)
}

impl Backend {
	fn file_for(&self, room: &str) -> PathBuf {
		self.directory.join(file_name(room))
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
		let mut tail = Vec::new();
		let mut count = 0;
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
			tail.push(line);
			if tail.len() > LINES_KEPT {
				tail.remove(0);
			}
			count += 1;
		}
		self.grown.insert(room.into(), count);
		Ok(tail)
	}
	fn append(&mut self, room: &str, line: &KeptLine, evicted: Option<&str>) -> Result<(), Error> {
		create(&self.directory)?;
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
			let mut file = fs::OpenOptions::new()
				.append(true)
				.create(true)
				.open(self.file_for(room))?;
			let mut row = encode_line(line);
			row.push('\n');
			file.write_all(row.as_bytes())?;
			file.sync_all()?;
		}
		if let Some(evicted) = evicted {
			self.replace(evicted, [].iter())?;
		}
		Ok(())
	}
	fn replace<'a>(&mut self, room: &str, tail: impl ExactSizeIterator<Item = &'a KeptLine>) -> Result<(), Error> {
		create(&self.directory)?;
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
		crate::storage::atomic::replace_at(&self.directory, &file_name(room), std::iter::once(text.as_bytes()))?;
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
