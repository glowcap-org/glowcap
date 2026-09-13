//! Message recording decisions shared by native sessions and browser peers.
//! Clocks, source capabilities and storage commitment belong to the caller.
use super::{
	Attachment, Body, ConversationKind, Coordinates, Error, Kind, LineState, Record,
	index::{Identity, Key, Parts},
};
use crate::{
	files::FileDescription,
	room::message::{ChangeKind, LineId},
	text::DocumentText,
};
use alloc::{collections::BTreeSet, string::ToString, sync::Arc};

pub struct Message<'a> {
	pub keep: bool,
	pub generation: Option<&'a DocumentText>,
	pub kind: ConversationKind,
	pub directory: &'a DocumentText,
	pub conversation: &'a DocumentText,
	pub nick: &'a str,
	pub from: &'a str,
	pub text: &'a str,
	pub previews: &'a crate::open_graph::Selection,
	pub system: bool,
	pub line: Option<LineId>,
	pub change: ChangeKind,
	pub at: u64,
}
/// Skip transient, system and unidentified messages before retaining input.
/// Withdrawals preserve identity and chronology while carrying no text or files.
pub fn message<'a>(
	source: &DocumentText,
	input: &Message<'_>,
	files: impl ExactSizeIterator<Item = &'a FileDescription>,
) -> Result<Option<Record>, Error> {
	let (Some(generation), Some(line)) = (input.generation, input.line) else {
		return Ok(None);
	};
	if !input.keep
		|| input.system
		|| (input.text.is_empty() && files.len() == 0 && input.change != ChangeKind::Withdrawn)
	{
		return Ok(None);
	}
	let withdrawn = input.change == ChangeKind::Withdrawn;
	// Check borrowed fields before materializing an owned archive row.
	super::records::opaque(source)?;
	super::records::opaque(generation)?;
	super::records::bounded_text(input.directory, super::MAX_CONTEXT_BYTES, false)?;
	super::records::bounded_text(input.conversation, super::MAX_CONVERSATION_BYTES, false)?;
	super::records::safe(input.at, false)?;
	if !crate::room::inbox::valid_nick(input.from) {
		return Err(Error::Record);
	}
	if !withdrawn {
		super::records::bounded(input.text, crate::room::line::MAX_LINE_BYTES, true)?;
	}
	if input.kind == ConversationKind::Room && !input.nick.is_empty() && !crate::room::inbox::valid_nick(input.nick) {
		return Err(Error::Record);
	}
	if !withdrawn && files.len() > crate::room::line::MAX_MESSAGE_FILES {
		return Err(Error::Record);
	}
	let attachments = if withdrawn {
		alloc::vec::Vec::new()
	} else {
		files
			.map(|file| {
				Attachment::new(
					file.name().into(),
					file.mime().into(),
					file.size() as u64,
					file.dimensions().0 as u64,
					file.dimensions().1 as u64,
					None,
				)
			})
			.collect::<Result<_, _>>()?
	};
	Record::new(
		Coordinates {
			source: source.clone(),
			generation: generation.clone(),
			id: line.get().to_string().into(),
		},
		input.directory.clone(),
		Body::Line {
			conversation_kind: input.kind,
			conversation: input.conversation.clone(),
			from: input.from.into(),
			text: if withdrawn { "" } else { input.text }.into(),
			mine: input.from == input.nick,
			at: input.at,
			order: line.get(),
			state: match input.change {
				ChangeKind::Withdrawn => LineState::Withdrawn,
				ChangeKind::Edited | ChangeKind::Refiled => LineState::Edited,
				ChangeKind::Said => LineState::Present,
			},
			previews: if withdrawn {
				crate::open_graph::Selection::default()
			} else {
				crate::open_graph::Selection::new(input.text, input.previews.urls().iter().map(|url| url.as_str()))
					.map_err(|_| Error::Record)?
			},
			attachments,
		},
	)
	.map(Some)
}

/// An account-local memo of successfully recorded standing. Eviction permits a
/// later retry; it never suppresses recording or substitutes for stored history.
/// Keys share their record and borrow the archive index's identity comparison.
pub struct Standings {
	keys: BTreeSet<Key>,
	bytes: usize,
	id: DocumentText,
}
const MAX_STANDINGS: usize = 128;
const MAX_STANDING_BYTES: usize = 256 * 1024;
impl Default for Standings {
	fn default() -> Self {
		Self {
			keys: BTreeSet::new(),
			bytes: 0,
			id: "standing".into(),
		}
	}
}
struct Probe<'a> {
	line: &'a Record,
	id: &'a DocumentText,
}
impl Identity for Probe<'_> {
	fn parts(&self) -> Parts<'_> {
		let c = self.line.coordinates();
		(
			&c.source,
			&c.generation,
			Kind::Standing,
			None,
			self.line.directory(),
			self.line.conversation(),
			self.id,
		)
	}
}
impl Standings {
	/// Build only an uncached room standing. The caller remembers it after the
	/// write succeeds, and clears this memo when that account is erased.
	pub fn prepare(&self, line: &Record, nick: &str) -> Result<Option<Record>, Error> {
		let Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation,
			at,
			..
		} = line.body()
		else {
			return Ok(None);
		};
		if nick.is_empty() || self.keys.contains(&Probe { line, id: &self.id } as &dyn Identity) {
			return Ok(None);
		}
		if !crate::room::inbox::valid_nick(nick) {
			return Err(Error::Record);
		}
		Record::new(
			Coordinates {
				source: line.coordinates().source.clone(),
				generation: line.coordinates().generation.clone(),
				id: self.id.clone(),
			},
			line.directory().clone(),
			Body::Standing {
				room: conversation.clone(),
				nick: nick.into(),
				at: *at,
			},
		)
		.map(Some)
	}
	pub fn remember(&mut self, standing: Record) -> Result<(), Error> {
		if standing.kind() != Kind::Standing {
			return Err(Error::Record);
		}
		if self.keys.contains(&standing as &dyn Identity) {
			return Ok(());
		}
		let bytes = standing.retained_bytes();
		if bytes > MAX_STANDING_BYTES {
			return Ok(());
		}
		while self.keys.len() == MAX_STANDINGS || bytes > MAX_STANDING_BYTES - self.bytes {
			let retired = self.keys.pop_first().expect("nonempty bounded standing memo");
			self.bytes -= retired.0.retained_bytes();
		}
		self.bytes += bytes;
		self.keys.insert(Key(Arc::new(standing)));
		Ok(())
	}
	pub fn clear(&mut self) {
		self.keys.clear();
		self.bytes = 0;
	}
}
