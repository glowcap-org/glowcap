//! Decide what one event means to the bot. Only typed values reach here, so
//! the bot never text-matches a nickname. A value past the bounds a session
//! keeps is refused here, so nothing the bot stores can outgrow its files.
use super::rooms::{Attachment, Body, Change, Cursor, Incoming, Kind, Line, Sender};
use rooms_application::{
	content::session::workspace::MAX_ID_UNITS,
	room::{
		inbox::valid_nick,
		line::{MAX_LINE_BYTES, MAX_MESSAGE_FILES},
	},
};
use serde::{Deserialize, Serialize};

/// The longest line id or attachment token the bot keeps.
pub const MAX_NAME_BYTES: usize = 128;
/// The longest attachment file name or media type the bot keeps.
pub const MAX_LABEL_BYTES: usize = 255;

/// The bot's own order of the events it reads. The bot numbers events as it
/// reads them, and a restart numbers the replay from the durable cursor's
/// number, so the same stream gets the same numbers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Seq(pub u64);

impl Seq {
	pub fn next(self) -> Self {
		Self(self.0.saturating_add(1))
	}
}

/// A line that asks the bot to act. The ledger keeps these, so a restart
/// rebuilds the prompt without asking the session for the line again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Trigger {
	pub seq: Seq,
	/// The event's own cursor, which names it when it is read again.
	pub event: Cursor,
	/// The line's id in its conversation.
	pub line: String,
	/// The sender's nickname. A direct line has none.
	pub from: Option<String>,
	pub text: String,
	pub files: Vec<Attachment>,
}

/// A line in a conversation that does not address the bot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextLine {
	pub seq: Seq,
	pub event: Cursor,
	pub from: Option<String>,
	pub text: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Class {
	/// Nothing to remember and nothing to answer.
	Ignore,
	Context(ContextLine),
	Trigger(Trigger),
	/// A line no session sends. The reason is for the log.
	Malformed(&'static str),
}

fn bounded(line: &Line) -> Result<(), &'static str> {
	if line.text.len() > MAX_LINE_BYTES {
		return Err("a line is longer than a session allows");
	}
	if line.id.len() > MAX_NAME_BYTES {
		return Err("a line id is longer than the bot keeps");
	}
	if line.files.len() > MAX_MESSAGE_FILES {
		return Err("a line carries more files than a session allows");
	}
	let long_file = line.files.iter().any(|file| {
		file.token.len() > MAX_NAME_BYTES || file.name.len() > MAX_LABEL_BYTES || file.mime.len() > MAX_LABEL_BYTES
	});
	if long_file {
		return Err("an attachment description is longer than the bot keeps");
	}
	Ok(())
}

/// A trigger is a new line in a direct conversation from the other person, or
/// a room line that mentions this member. Any other new line from someone
/// else is context.
pub fn classify(event: &Incoming, seq: Seq) -> Class {
	let Body::Line(line) = &event.body else {
		return Class::Ignore;
	};
	if line.change != Change::Said {
		return Class::Ignore;
	}
	let from = match (&line.sender, event.kind) {
		(Sender::Own | Sender::System, _) | (_, Kind::Other) => return Class::Ignore,
		(Sender::Peer(_), Kind::Direct) => None,
		(Sender::Peer(_), Kind::Room) => return Class::Malformed("a room line names no sender"),
		(Sender::Member(name), _) if !valid_nick(name) => {
			return Class::Malformed("a nickname is not one a session grants");
		}
		(Sender::Member(name), _) => Some(name.clone()),
	};
	if event.conversation.as_str().encode_utf16().nth(MAX_ID_UNITS).is_some() {
		return Class::Malformed("a conversation id is longer than a session allows");
	}
	if let Err(reason) = bounded(line) {
		return Class::Malformed(reason);
	}
	let addressed = match event.kind {
		Kind::Direct => true,
		Kind::Room => line.mentions.member,
		Kind::Other => false,
	};
	if addressed {
		Class::Trigger(Trigger {
			seq,
			event: event.cursor.clone(),
			line: line.id.clone(),
			from,
			text: line.text.clone(),
			files: line.files.clone(),
		})
	} else {
		Class::Context(ContextLine {
			seq,
			event: event.cursor.clone(),
			from,
			text: line.text.clone(),
		})
	}
}

/// The nickname that decides whether a line may start work: the sender's in a
/// room, and the other person's in a direct conversation.
pub fn sender(event: &Incoming) -> Option<&str> {
	match &event.body {
		Body::Line(Line {
			sender: Sender::Member(name) | Sender::Peer(Some(name)),
			..
		}) => Some(name),
		_ => None,
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::bot::rooms::{ConversationId, Mentions};

	fn event(kind: Kind, sender: Sender, change: Change, mentions: Mentions) -> Incoming {
		Incoming {
			cursor: Cursor::new("x7").unwrap(),
			conversation: ConversationId::new("c1"),
			kind,
			body: Body::Line(Line {
				id: "l7".into(),
				sender,
				change,
				text: "hello".into(),
				files: Vec::new(),
				mentions,
			}),
		}
	}
	fn member(name: &str) -> Sender {
		Sender::Member(name.into())
	}
	const MENTIONED: Mentions = Mentions {
		member: true,
		room: false,
	};
	const ROOM_WIDE: Mentions = Mentions {
		member: false,
		room: true,
	};

	#[test]
	fn a_direct_line_from_the_other_person_triggers_without_a_mention() {
		let class = classify(
			&event(Kind::Direct, Sender::Peer(None), Change::Said, Mentions::default()),
			Seq(4),
		);
		assert!(
			matches!(class, Class::Trigger(t) if t.seq == Seq(4) && t.event.as_str() == "x7" && t.from.is_none() && t.line == "l7")
		);
	}

	#[test]
	fn a_room_line_triggers_only_when_it_mentions_the_member() {
		let plain = classify(
			&event(Kind::Room, member("ann"), Change::Said, Mentions::default()),
			Seq(1),
		);
		assert!(matches!(plain, Class::Context(line) if line.from.as_deref() == Some("ann")));
		let wide = classify(&event(Kind::Room, member("ann"), Change::Said, ROOM_WIDE), Seq(1));
		assert!(
			matches!(wide, Class::Context(_)),
			"a room-wide mention is not a mention of the bot"
		);
		let named = classify(&event(Kind::Room, member("ann"), Change::Said, MENTIONED), Seq(1));
		assert!(matches!(named, Class::Trigger(t) if t.from.as_deref() == Some("ann")));
	}

	#[test]
	fn own_lines_notices_revisions_and_other_kinds_are_ignored() {
		for (kind, sender, change) in [
			(Kind::Direct, Sender::Own, Change::Said),
			(Kind::Room, Sender::Own, Change::Said),
			(Kind::Room, Sender::System, Change::Said),
			(Kind::Direct, Sender::Peer(None), Change::Revised),
			(Kind::Room, member("ann"), Change::Revised),
			(Kind::Other, member("ann"), Change::Said),
		] {
			assert_eq!(classify(&event(kind, sender, change, MENTIONED), Seq(1)), Class::Ignore);
		}
		let other = Incoming {
			body: Body::Other,
			..event(Kind::Room, Sender::Own, Change::Said, MENTIONED)
		};
		assert_eq!(classify(&other, Seq(1)), Class::Ignore);
	}

	#[test]
	fn a_line_past_the_session_bounds_is_refused_whole() {
		let mut long = event(Kind::Direct, Sender::Peer(None), Change::Said, Mentions::default());
		if let Body::Line(line) = &mut long.body {
			line.text = "x".repeat(MAX_LINE_BYTES + 1);
		}
		assert!(matches!(classify(&long, Seq(1)), Class::Malformed(_)));
		let mut files = event(Kind::Direct, Sender::Peer(None), Change::Said, Mentions::default());
		if let Body::Line(line) = &mut files.body {
			line.files = vec![
				Attachment {
					token: "t".into(),
					index: 0,
					name: "a".into(),
					mime: "text/plain".into(),
					size: 1,
					width: 0,
					height: 0,
				};
				MAX_MESSAGE_FILES + 1
			];
		}
		assert!(matches!(classify(&files, Seq(1)), Class::Malformed(_)));
		let nameless = event(Kind::Room, Sender::Peer(None), Change::Said, MENTIONED);
		assert!(matches!(classify(&nameless, Seq(1)), Class::Malformed(_)));
	}
}
