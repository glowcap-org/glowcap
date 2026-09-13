//! What a room keeps of its own conversation, when this server keeps any.
//! Retention is one policy with two ceilings: a room keeps its last five
//! hundred lines, and the whole server keeps at most 4,096 lines across at
//! most 256 rooms. A busy server therefore holds fewer than five hundred
//! per room, and when the server-wide ceiling is reached the room whose
//! last line is oldest is let go whole rather than trimmed. A backend only
//! persists what this index admitted, in the JSON row form `encode_line`
//! writes, so a history directory is portable between deployments.
use crate::{
	room::{inbox::MAX_NICK, line::MAX_LINE_BYTES},
	server::document::MAX_DURABLE_ROOM,
};
use alloc::{
	borrow::Cow,
	collections::BTreeMap,
	string::{String, ToString},
	sync::Arc,
	vec::Vec,
};

/// One room's visible tail.
pub const LINES_KEPT: usize = 500;
/// Whole-server resident bounds. At the line limit the text held is at most
/// 32 MiB of UTF-8 plus bounded names.
pub const LINES_KEPT_TOTAL: usize = 4_096;
pub const ROOMS_KEPT: usize = 256;
/// Past this many rows on disk, a room file is rewritten to the kept tail.
pub const COMPACT_AT: usize = LINES_KEPT * 2;
/// One pre-compaction room file at the worst JSON escaping expansion.
pub const FILE_BYTES: usize = 64 * 1024 * 1024;
/// The pre-read ceiling for the whole history directory.
pub const DISK_BYTES: usize = 512 * 1024 * 1024;
/// Append and whole-room deletion are two filesystem operations, so a crash
/// may leave one surplus room standing; startup admits exactly that one.
pub const ROOM_FILES: usize = ROOMS_KEPT + 1;
const LINE_VERSION: u64 = 2;

/// One retained row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeptLine {
	pub from: String,
	pub text: String,
	pub previews: crate::open_graph::Selection,
	pub at: u64,
}

/// A row this process made. Its token is the line capability's exact
/// mutation authority: a restored row has none, so no later room generation
/// can govern it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Token(u64);

#[derive(Clone, Debug, PartialEq, Eq)]
struct Row {
	line: Arc<KeptLine>,
	token: Option<Token>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Room {
	name: String,
	rows: Vec<Row>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	RoomName,
	Line,
	Repeated,
	Version,
	Json,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::RoomName => "room history has an invalid room identity",
			Self::Line => "room history contains an invalid line",
			Self::Repeated => "room history repeats a room",
			Self::Version => "room history has an unsupported line version",
			Self::Json => "room history contains invalid JSON",
		})
	}
}
impl core::error::Error for Error {}

fn validate_room(room: &str) -> Result<(), Error> {
	let units = room.encode_utf16().take(MAX_DURABLE_ROOM + 1).count();
	if units == 0 || units > MAX_DURABLE_ROOM {
		return Err(Error::RoomName);
	}
	Ok(())
}

/// Refuse persisted or newly admitted state that no room could have produced.
pub fn validate_line(line: &KeptLine) -> Result<(), Error> {
	validate_fields(&line.from, &line.text, line.at)?;
	if crate::open_graph::Selection::new(&line.text, line.previews.urls().iter().map(String::as_str)).is_err() {
		return Err(Error::Line);
	}
	Ok(())
}

/// The cheap half of `validate_line`: the bounds a row's fields hold on
/// their own, before a preview selection is built over the text.
fn validate_fields(from: &str, text: &str, at: u64) -> Result<(), Error> {
	let units = from.encode_utf16().take(MAX_NICK + 1).count();
	if units == 0 || units > MAX_NICK || text.len() > MAX_LINE_BYTES || at >= (1 << 53) {
		return Err(Error::Line);
	}
	Ok(())
}

/// What `record` answers: the new row's token, what to persist, and the
/// row this room let go of to keep its tail at `LINES_KEPT`, when that row
/// was one this process made.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Recorded {
	pub token: Token,
	pub persist: Persist,
	pub retired: Option<Token>,
}

/// What one admitted change asks the backend to persist. Immutable rows are
/// shared with the index and queued tails; editing replaces only the changed
/// row with a fresh one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Persist {
	/// One more row for `room`, and the room whose whole tail left the index
	/// to make space, whose file is then deleted.
	Append {
		room: String,
		line: Arc<KeptLine>,
		evicted: Option<String>,
	},
	/// The kept tail changed shape: persist it as it now stands, or delete
	/// the file when nothing remains.
	Replace { room: String, tail: Vec<Arc<KeptLine>> },
}

/// The one live tail owner. Every mutation answers what the backend must
/// persist; the adapter queues that work in order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Index {
	rooms: BTreeMap<String, Room>,
	lines: usize,
	next_token: u64,
	restored: Vec<String>,
	evicted_at_restore: Vec<String>,
}

fn fold(room: &str) -> String {
	room.to_lowercase()
}

impl Index {
	/// Transfer one persisted room tail, oldest first. Rooms past the global
	/// edge are evicted in age order and named by `take_evicted`, so the
	/// adapter deletes their files.
	pub fn restore_room(&mut self, room: &str, mut lines: Vec<KeptLine>) -> Result<(), Error> {
		validate_room(room)?;
		let key = fold(room);
		if self.restored.contains(&key) {
			return Err(Error::Repeated);
		}
		self.restored.push(key.clone());
		for line in &lines {
			validate_line(line)?;
		}
		if lines.len() > LINES_KEPT {
			lines.drain(..lines.len() - LINES_KEPT);
		}
		if lines.is_empty() {
			return Ok(());
		}
		self.lines += lines.len();
		self.rooms.insert(
			key,
			Room {
				name: room.into(),
				rows: lines
					.into_iter()
					.map(|line| Row {
						line: Arc::new(line),
						token: None,
					})
					.collect(),
			},
		);
		while self.rooms.len() > ROOMS_KEPT || self.lines > LINES_KEPT_TOTAL {
			if let Some(evicted) = self.evict_oldest() {
				self.evicted_at_restore.push(evicted);
			}
		}
		Ok(())
	}
	/// Rooms whose files a restore evicted, once.
	pub fn take_evicted(&mut self) -> Vec<String> {
		core::mem::take(&mut self.evicted_at_restore)
	}
	/// Keep one line for a room. The token names this row for the line
	/// capability's later edit or withdrawal. The row is shared with the
	/// caller rather than copied: the caller keeps the same body for the
	/// line it answers edits on and the notice it tells.
	pub fn record(&mut self, room: &str, line: Arc<KeptLine>) -> Result<Recorded, Error> {
		validate_room(room)?;
		validate_line(&line)?;
		let key = fold(room);
		let token = Token(self.next_token);
		self.next_token += 1;
		let kept = self.rooms.entry(key).or_insert_with(|| Room {
			name: room.into(),
			rows: Vec::new(),
		});
		kept.rows.push(Row {
			line: line.clone(),
			token: Some(token),
		});
		self.lines += 1;
		let retired = if kept.rows.len() > LINES_KEPT {
			self.lines -= 1;
			kept.rows.remove(0).token
		} else {
			None
		};
		let evicted = if self.rooms.len() > ROOMS_KEPT || self.lines > LINES_KEPT_TOTAL {
			self.evict_oldest()
		} else {
			None
		};
		Ok(Recorded {
			token,
			retired,
			persist: Persist::Append {
				room: room.into(),
				line,
				evicted,
			},
		})
	}
	/// Forget only the exact row the calling line capability retained.
	pub fn forget(&mut self, room: &str, token: Token) -> Option<Persist> {
		let key = fold(room);
		let kept = self.rooms.get_mut(&key)?;
		let at = kept.rows.iter().position(|row| row.token == Some(token))?;
		kept.rows.remove(at);
		self.lines -= 1;
		let tail = kept.rows.iter().map(|row| row.line.clone()).collect();
		if kept.rows.is_empty() {
			self.rooms.remove(&key);
		}
		Some(Persist::Replace {
			room: room.into(),
			tail,
		})
	}
	/// Replace only the exact row the calling line capability retained with
	/// the line as it now reads, shared with the caller the way `record`
	/// shares it. A queued tail keeps the row it was given, so the earlier
	/// value persists as it stood.
	pub fn replace(&mut self, room: &str, token: Token, line: Arc<KeptLine>) -> Result<Option<Persist>, Error> {
		validate_line(&line)?;
		let Some(kept) = self.rooms.get_mut(&fold(room)) else {
			return Ok(None);
		};
		let Some(row) = kept.rows.iter_mut().find(|row| row.token == Some(token)) else {
			return Ok(None);
		};
		row.line = line;
		Ok(Some(Persist::Replace {
			room: room.into(),
			tail: kept.rows.iter().map(|row| row.line.clone()).collect(),
		}))
	}
	/// The last `limit` kept lines for a room, oldest first, borrowed from
	/// the rows the index shares so a reader encodes without a copy.
	pub fn read(&self, room: &str, limit: usize) -> impl Iterator<Item = &KeptLine> + '_ {
		let rows = self.rooms.get(&fold(room)).map_or(&[][..], |kept| kept.rows.as_slice());
		let start = rows.len().saturating_sub(limit);
		rows[start..].iter().map(|row| &*row.line)
	}
	pub fn rooms(&self) -> usize {
		self.rooms.len()
	}
	pub fn lines(&self) -> usize {
		self.lines
	}
	fn evict_oldest(&mut self) -> Option<String> {
		let oldest = self
			.rooms
			.values()
			.min_by(|a, b| {
				let (a_at, b_at) = (
					a.rows.last().map_or(0, |row| row.line.at),
					b.rows.last().map_or(0, |row| row.line.at),
				);
				a_at.cmp(&b_at).then_with(|| a.name.cmp(&b.name))
			})?
			.name
			.clone();
		let removed = self.rooms.remove(&fold(&oldest))?;
		self.lines -= removed.rows.len();
		Some(oldest)
	}
}

/// One persisted row in the room-history store's JSON form. A version-one
/// row is the same shape with no `previews` key; version two writes the
/// key only when a preview was chosen, so the two versions read through
/// one struct and the version rule is decided on it.
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Persisted<'a> {
	version: u64,
	from: Cow<'a, str>,
	text: Cow<'a, str>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	previews: Option<Vec<String>>,
	at: u64,
}

pub fn encode_line(line: &KeptLine) -> String {
	let urls = line.previews.urls();
	serde_json::to_string(&Persisted {
		version: LINE_VERSION,
		from: Cow::Borrowed(&line.from),
		text: Cow::Borrowed(&line.text),
		previews: (!urls.is_empty()).then(|| urls.to_vec()),
		at: line.at,
	})
	.expect("a kept line encodes")
}

/// Read one persisted row. A row of another version is refused, and so is
/// one no room could have produced. The row is parsed once and its preview
/// selection built once, so a restore pays one JSON pass and one Markdown
/// walk per line.
pub fn decode_line(row: &str) -> Result<KeptLine, Error> {
	let persisted: Persisted<'_> = serde_json::from_str(row).map_err(|error| {
		if error.is_syntax() || error.is_eof() {
			Error::Json
		} else {
			Error::Line
		}
	})?;
	let admitted = persisted.version == LINE_VERSION || (persisted.version == 1 && persisted.previews.is_none());
	if !admitted {
		return Err(Error::Version);
	}
	let (from, text) = (persisted.from.into_owned(), persisted.text.into_owned());
	validate_fields(&from, &text, persisted.at)?;
	let previews = crate::open_graph::Selection::new(&text, persisted.previews.iter().flatten().map(String::as_str))
		.map_err(|_| Error::Line)?;
	Ok(KeptLine {
		from,
		text,
		previews,
		at: persisted.at,
	})
}

/// The file a room's history lives in, `<name>.jsonl` with the name encoded
/// the way JavaScript's `encodeURIComponent` encodes it, so a directory of
/// files remains portable across server deployments.
pub fn file_name(room: &str) -> String {
	let mut out = String::with_capacity(room.len() + 6);
	for byte in room.bytes() {
		match byte {
			b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'!' | b'~' | b'*' | b'\'' | b'(' | b')' => {
				out.push(byte as char)
			}
			_ => {
				const DIGITS: &[u8; 16] = b"0123456789ABCDEF";
				out.push('%');
				out.push(DIGITS[(byte >> 4) as usize] as char);
				out.push(DIGITS[(byte & 15) as usize] as char);
			}
		}
	}
	out.push_str(".jsonl");
	out
}

/// The room a file name stands for, when the name is exactly what
/// `file_name` writes for it.
pub fn room_of_file(name: &str) -> Option<String> {
	let encoded = name.strip_suffix(".jsonl")?;
	let bytes = encoded.as_bytes();
	let mut out = Vec::with_capacity(bytes.len());
	let mut at = 0;
	while at < bytes.len() {
		if bytes[at] == b'%' {
			let digit = |byte: u8| (byte as char).to_digit(16).map(|d| d as u8);
			let (high, low) = (digit(*bytes.get(at + 1)?)?, digit(*bytes.get(at + 2)?)?);
			out.push(high << 4 | low);
			at += 3;
		} else {
			out.push(bytes[at]);
			at += 1;
		}
	}
	let room = String::from_utf8(out).ok()?;
	(file_name(&room) == name).then_some(room)
}

impl core::fmt::Display for Token {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		self.0.to_string().fmt(f)
	}
}

#[cfg(test)]
mod tests;
