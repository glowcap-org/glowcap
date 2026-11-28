//! Typed reading of one activity projection row. The runtime owns the row's
//! shape. This decodes it once so a consumer never parses JSON.
use super::Error;
use rooms_application::room::mentions::Mentions;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
	Room,
	Direct,
	Directory,
	Discovery,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Conversation {
	pub id: String,
	pub kind: Kind,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Change {
	Said,
	Edited,
	Refiled,
	Withdrawn,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Line {
	/// The sender's nickname in a room. A direct conversation has none, its
	/// sender is the peer.
	pub from: Option<String>,
	pub text: String,
	/// The line identity, absent for a line the session does not number.
	pub id: Option<u64>,
	pub change: Change,
	/// The operation the session posted this line under, on a line this
	/// member sent. A sender recognizes its own committed send by it.
	pub operation: Option<String>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Notice {
	Line(Line),
	/// Any other notice, by the kind the session named it.
	Other(String),
}
/// One file of an event with what `View::fetch` needs to read it. A caller
/// may keep it, as JSON, to fetch the file later.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Attachment {
	pub token: String,
	pub index: usize,
	pub name: String,
	pub mime: String,
	pub size: usize,
	pub width: u32,
	pub height: u32,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Event {
	/// Resume reading after this event with this cursor. It is also the token
	/// of the event's attachments.
	pub cursor: String,
	pub at: u64,
	pub conversation: Conversation,
	pub notice: Notice,
	pub mentions: Mentions,
	pub attachments: Vec<Attachment>,
}
/// One read of the session's activity.
#[derive(Debug, Eq, PartialEq)]
pub enum Step {
	/// Nothing newer than `cursor`.
	Idle {
		cursor: String,
	},
	Event(Event),
	/// Events before `cursor` were discarded unseen. Cached presentation is
	/// stale and the caller must resynchronize from its own source.
	Gap {
		cursor: String,
	},
	/// The event at `cursor` can no longer be shown to this access.
	Unavailable {
		cursor: String,
	},
	/// The row at `cursor` has a cursor the session issues and an event this
	/// reader cannot decode. Reading goes on after it.
	Unreadable {
		cursor: String,
	},
}
impl Step {
	pub(super) fn cursor(&self) -> &str {
		match self {
			Self::Event(event) => &event.cursor,
			Self::Idle { cursor }
			| Self::Gap { cursor }
			| Self::Unavailable { cursor }
			| Self::Unreadable { cursor } => cursor,
		}
	}
}
/// Whether `current`, a cursor from the session now, comes from another run
/// of the session than `earlier`. A cursor names the run it was issued in
/// before its first colon.
pub(super) fn restarted(earlier: &str, current: &str) -> bool {
	earlier.split(':').next() != current.split(':').next()
}
/// What one `View::events` call read, in order.
#[derive(Debug, Default, Eq, PartialEq)]
pub struct Batch {
	pub events: Vec<Event>,
	/// Persist this and pass it to the next call.
	pub cursor: String,
	pub gap: bool,
	pub unavailable: bool,
	/// Events skipped because their rows did not decode.
	pub unreadable: usize,
}

#[derive(Deserialize)]
struct Row {
	cursor: String,
	#[serde(default)]
	gap: bool,
	#[serde(default)]
	unavailable: bool,
	at: Option<u64>,
	data: Option<String>,
	#[serde(default)]
	files: Vec<FileRow>,
}
#[derive(Deserialize)]
struct FileRow {
	name: String,
	mime: String,
	size: usize,
	width: u32,
	height: u32,
}
#[derive(Deserialize)]
struct Envelope {
	target: Target,
	notice: NoticeRow,
	#[serde(default)]
	mentions: Mentions,
}
#[derive(Deserialize)]
struct Target {
	kind: String,
	id: String,
}
#[derive(Deserialize)]
struct NoticeRow {
	kind: String,
	from: Option<String>,
	text: Option<String>,
	marker: Option<Marker>,
	#[serde(default)]
	metadata: Option<serde_json::Value>,
}
#[derive(Deserialize)]
struct Marker {
	id: u64,
	change: String,
}

/// Whether `cursor` has the form the session issues: its run's marker in
/// hexadecimal, a colon, and a decimal position, within the length it reads
/// back. A caller persists the cursor, so any other text is refused here.
fn issued(cursor: &str) -> bool {
	let Some((run, position)) = cursor.split_once(':') else {
		return false;
	};
	cursor.len() <= rooms_runtime::session::managed::MAX_TOKEN_BYTES
		&& !run.is_empty()
		&& run.bytes().all(|byte| byte.is_ascii_hexdigit())
		&& position
			.parse::<u64>()
			.is_ok_and(|parsed| parsed.to_string() == position)
}

/// Decode one row. A row whose cursor the session could have issued and
/// whose event does not decode is `Unreadable` at that cursor, so a reader
/// passes it. A row without such a cursor is malformed, because nothing says
/// where to read next.
pub(super) fn decode(raw: &str) -> Result<Step, Error> {
	let value: serde_json::Value = serde_json::from_str(raw).map_err(|_| Error::Malformed("activity row"))?;
	let Some(cursor) = value.get("cursor").and_then(serde_json::Value::as_str) else {
		return Err(Error::Malformed("activity cursor"));
	};
	if !issued(cursor) {
		return Err(Error::Malformed("activity cursor"));
	}
	let cursor = cursor.to_owned();
	match event(value) {
		Err(Error::Malformed(_)) => Ok(Step::Unreadable { cursor }),
		step => step,
	}
}

fn event(value: serde_json::Value) -> Result<Step, Error> {
	let row: Row = serde_json::from_value(value).map_err(|_| Error::Malformed("activity row"))?;
	if row.unavailable {
		return Ok(Step::Unavailable { cursor: row.cursor });
	}
	if row.gap {
		return Ok(Step::Gap { cursor: row.cursor });
	}
	let (data, at) = match (row.data, row.at) {
		(None, None) => return Ok(Step::Idle { cursor: row.cursor }),
		(Some(data), Some(at)) => (data, at),
		_ => return Err(Error::Malformed("activity row")),
	};
	let envelope: Envelope = serde_json::from_str(&data).map_err(|_| Error::Malformed("activity envelope"))?;
	let kind = match envelope.target.kind.as_str() {
		"room" => Kind::Room,
		"direct" => Kind::Direct,
		"directory" => Kind::Directory,
		"discovery" => Kind::Discovery,
		_ => return Err(Error::Malformed("conversation kind")),
	};
	let notice = match (envelope.notice.kind.as_str(), envelope.notice.text) {
		("line", Some(text)) => {
			let change = match envelope.notice.marker.as_ref().map(|marker| marker.change.as_str()) {
				None | Some("said") => Change::Said,
				Some("edited") => Change::Edited,
				Some("refiled") => Change::Refiled,
				Some("withdrawn") => Change::Withdrawn,
				Some(_) => return Err(Error::Malformed("line change")),
			};
			Notice::Line(Line {
				from: envelope.notice.from,
				text,
				id: envelope.notice.marker.map(|marker| marker.id),
				change,
				operation: envelope
					.notice
					.metadata
					.as_ref()
					.and_then(|metadata| metadata.get("operation")?.as_str())
					.map(str::to_owned),
			})
		}
		(other, _) => Notice::Other(other.into()),
	};
	let attachments = row
		.files
		.into_iter()
		.enumerate()
		.map(|(index, file)| Attachment {
			token: row.cursor.clone(),
			index,
			name: file.name,
			mime: file.mime,
			size: file.size,
			width: file.width,
			height: file.height,
		})
		.collect();
	Ok(Step::Event(Event {
		cursor: row.cursor,
		at,
		conversation: Conversation {
			id: envelope.target.id,
			kind,
		},
		notice,
		mentions: envelope.mentions,
		attachments,
	}))
}

impl<D: super::Deadline + super::Tasks + Clone + 'static> super::View<D> {
	/// Re-read one occurrence under its original admission. A reused
	/// conversation id, an expired event or a restarted journal cannot match.
	pub async fn still_presents(&self, cursor: &str, conversation: &Conversation) -> Result<bool, Error> {
		let Some((run, position)) = cursor.split_once(':') else {
			return Ok(false);
		};
		let Some(previous) = position.parse::<u64>().ok().and_then(|n| n.checked_sub(1)) else {
			return Ok(false);
		};
		let before = format!("{run}:{previous}");
		let raw = match self.reader.read(&before, false).await {
			Ok(raw) => raw,
			Err(error) => {
				return match self.read_failure(error, &before).await {
					Error::Stale => Ok(false),
					other => Err(other),
				};
			}
		};
		Ok(
			matches!(decode(&raw)?,Step::Event(current) if current.cursor == cursor && &current.conversation == conversation),
		)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn row(data: &str) -> String {
		serde_json::json!({"cursor":"ab:2","head":"ab:9","at":7,"data":data,
			"files":[{"name":"a.txt","mime":"text/plain","size":3,"width":0,"height":0}]})
		.to_string()
	}
	#[test]
	fn a_room_line_decodes_with_its_mentions_and_files() {
		let data = r#"{"target":{"kind":"room","id":"r"},"notice":{"kind":"line","from":"bo","text":"hi @zoe",
			"marker":{"id":4,"change":"edited"}},"mentions":{"member":true,"room":false}}"#;
		let Step::Event(event) = decode(&row(data)).unwrap() else {
			panic!("an event")
		};
		assert_eq!(event.cursor, "ab:2");
		assert_eq!(event.conversation.kind, Kind::Room);
		assert!(event.mentions.member && !event.mentions.room);
		let Notice::Line(line) = event.notice else {
			panic!("a line")
		};
		assert_eq!(
			(line.from.as_deref(), line.id, line.change),
			(Some("bo"), Some(4), Change::Edited)
		);
		assert_eq!(event.attachments[0].token, "ab:2");
		assert_eq!(event.attachments[0].index, 0);
		assert_eq!(line.operation, None);
	}
	#[test]
	fn an_own_line_carries_the_operation_it_was_posted_under() {
		let own = r#"{"target":{"kind":"direct","id":"d"},"notice":{"kind":"line","from":"me","text":"yo",
			"metadata":{"operation":"op-1"},"marker":{"id":2,"change":"said"}},"mentions":{"member":false,"room":false}}"#;
		let Step::Event(event) = decode(&row(own)).unwrap() else {
			panic!("an event")
		};
		let Notice::Line(line) = event.notice else {
			panic!("a line")
		};
		assert_eq!(line.operation.as_deref(), Some("op-1"));
		let presence = r#"{"target":{"kind":"room","id":"r"},"notice":{"kind":"line","from":"bo","text":"x",
			"metadata":{"presence":"here"},"marker":{"id":3,"change":"said"}},"mentions":{"member":false,"room":false}}"#;
		let Step::Event(event) = decode(&row(presence)).unwrap() else {
			panic!("an event")
		};
		assert!(matches!(event.notice, Notice::Line(Line { operation: None, .. })));
	}
	#[test]
	fn a_direct_line_has_no_sender_and_other_notices_keep_their_kind() {
		let direct = r#"{"target":{"kind":"direct","id":"d"},"notice":{"kind":"line","text":"yo",
			"marker":{"id":1,"change":"said"}},"mentions":{"member":false,"room":false}}"#;
		let Step::Event(event) = decode(&row(direct)).unwrap() else {
			panic!("an event")
		};
		assert_eq!(event.conversation.kind, Kind::Direct);
		assert!(matches!(event.notice, Notice::Line(Line { from: None, .. })));
		let typing = r#"{"target":{"kind":"room","id":"r"},"notice":{"kind":"typing","name":"bo","on":true},"mentions":{"member":false,"room":false}}"#;
		let Step::Event(event) = decode(&row(typing)).unwrap() else {
			panic!("an event")
		};
		assert_eq!(event.notice, Notice::Other("typing".into()));
	}
	#[test]
	fn idle_gap_and_unavailable_are_distinct_and_carry_their_cursor() {
		assert_eq!(
			decode(r#"{"cursor":"ab:0","head":"ab:0"}"#).unwrap(),
			Step::Idle { cursor: "ab:0".into() }
		);
		assert_eq!(
			decode(r#"{"cursor":"ab:1","head":"ab:9","gap":true}"#).unwrap(),
			Step::Gap { cursor: "ab:1".into() }
		);
		assert_eq!(
			decode(r#"{"cursor":"ab:1","head":"ab:9","unavailable":true}"#).unwrap(),
			Step::Unavailable { cursor: "ab:1".into() }
		);
	}
	#[test]
	fn a_row_without_a_cursor_is_malformed_and_one_with_a_cursor_is_skipped_by_it() {
		assert!(matches!(decode("not json"), Err(Error::Malformed(_))));
		assert!(matches!(decode(r#"{"at":7}"#), Err(Error::Malformed(_))));
		let kind = r#"{"target":{"kind":"moon","id":"r"},"notice":{"kind":"ended"}}"#;
		assert_eq!(decode(&row(kind)).unwrap(), Step::Unreadable { cursor: "ab:2".into() });
		let half = [r#"{"cursor":"ab:2","at":7}"#, r#"{"cursor":"ab:2","data":"{}"}"#];
		for raw in half {
			assert_eq!(
				decode(raw).unwrap(),
				Step::Unreadable { cursor: "ab:2".into() },
				"{raw}"
			);
		}
	}
	#[test]
	fn a_cursor_the_session_could_not_have_issued_is_refused() {
		let long = format!("{}:1", "a".repeat(rooms_runtime::session::managed::MAX_TOKEN_BYTES));
		for cursor in [
			"",
			"ab",
			":1",
			"xy:1",
			"ab:",
			"ab:-1",
			"ab:01",
			"ab:1:2",
			"ab:1 ",
			long.as_str(),
		] {
			let raw = serde_json::json!({ "cursor": cursor }).to_string();
			assert!(matches!(decode(&raw), Err(Error::Malformed(_))), "{cursor:?}");
		}
		let longest = format!("{}:1", "a".repeat(rooms_runtime::session::managed::MAX_TOKEN_BYTES - 2));
		assert!(decode(&serde_json::json!({ "cursor": longest }).to_string()).is_ok());
	}
}
