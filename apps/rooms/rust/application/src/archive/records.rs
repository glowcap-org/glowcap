//! Archive record validation and lifecycle replacement policy.
use super::{Error, MAX_CONTEXT_BYTES, MAX_CONVERSATION_BYTES, MAX_ID_BYTES};
use crate::{
	room::{
		inbox::valid_nick,
		line::{MAX_LINE_BYTES, MAX_MESSAGE_FILES},
	},
	text::DocumentText,
};
use alloc::vec::Vec;
use serde::{Deserialize, Serialize};
use serde_json::{Value as Json, json};

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Coordinates {
	pub source: DocumentText,
	pub generation: DocumentText,
	pub id: DocumentText,
}
impl Coordinates {
	pub fn new(source: DocumentText, generation: DocumentText, id: DocumentText) -> Result<Self, Error> {
		let coordinates = Self { source, generation, id };
		coordinates.validate()?;
		Ok(coordinates)
	}
	fn validate(&self) -> Result<(), Error> {
		for id in [&self.source, &self.generation, &self.id] {
			opaque(id)?;
		}
		Ok(())
	}
}
/// The one presentation of an archive coordinate. The runtime's activity
/// reader and the services control journal both attach a received event's
/// history in this shape, so the two renderers cannot drift apart.
pub fn history_data(history: Coordinates) -> Json {
	json!({"source":history.source,"generation":history.generation,"id":history.id})
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConversationKind {
	Room,
	Direct,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
	Standing,
	Line,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LineState {
	Present,
	Edited,
	Withdrawn,
}
pub use super::attachment::Attachment;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Body {
	Standing {
		room: DocumentText,
		nick: DocumentText,
		at: u64,
	},
	Line {
		conversation_kind: ConversationKind,
		conversation: DocumentText,
		from: DocumentText,
		text: DocumentText,
		mine: bool,
		at: u64,
		order: u64,
		state: LineState,
		previews: crate::open_graph::Selection,
		attachments: Vec<Attachment>,
	},
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
	coordinates: Coordinates,
	directory: DocumentText,
	body: Body,
}
impl Record {
	pub fn new(coordinates: Coordinates, directory: DocumentText, body: Body) -> Result<Self, Error> {
		coordinates.validate()?;
		bounded_text(&directory, MAX_CONTEXT_BYTES, false)?;
		match &body {
			Body::Standing { room, nick, at } => {
				bounded_text(room, MAX_CONVERSATION_BYTES, false)?;
				if !valid_nick(&nick.utf8_lossy()) {
					return Err(Error::Record);
				}
				safe(*at, false)?;
			}
			Body::Line {
				conversation,
				from,
				text,
				at,
				order,
				state,
				previews,
				attachments,
				..
			} => {
				bounded_text(conversation, MAX_CONVERSATION_BYTES, false)?;
				bounded_text(text, MAX_LINE_BYTES, true)?;
				if !valid_nick(&from.utf8_lossy()) {
					return Err(Error::Record);
				}
				safe(*at, false)?;
				safe(*order, true)?;
				if attachments.len() > MAX_MESSAGE_FILES
					|| attachments.iter().map(|a| a.size()).sum::<usize>() > 64 * 1024 * 1024
				{
					return Err(Error::Record);
				}
				for attachment in attachments {
					if attachment.blob().is_some_and(|blob| !digest(blob)) {
						return Err(Error::Record);
					}
				}
				if !previews.is_empty()
					&& text.as_str().is_none_or(|text| {
						crate::open_graph::Selection::new(text, previews.urls().iter().map(|url| url.as_str())).is_err()
					}) {
					return Err(Error::Record);
				}
				if *state == LineState::Withdrawn
					&& (text.utf16().next().is_some() || !previews.is_empty() || !attachments.is_empty())
				{
					return Err(Error::Record);
				}
			}
		}
		Ok(Self {
			coordinates,
			directory,
			body,
		})
	}
	pub fn coordinates(&self) -> &Coordinates {
		&self.coordinates
	}
	pub fn directory(&self) -> &DocumentText {
		&self.directory
	}
	pub fn body(&self) -> &Body {
		&self.body
	}
	pub fn kind(&self) -> Kind {
		match self.body {
			Body::Standing { .. } => Kind::Standing,
			Body::Line { .. } => Kind::Line,
		}
	}
	pub fn conversation(&self) -> &DocumentText {
		match &self.body {
			Body::Standing { room, .. } => room,
			Body::Line { conversation, .. } => conversation,
		}
	}
	pub fn conversation_kind(&self) -> Option<ConversationKind> {
		match self.body {
			Body::Line { conversation_kind, .. } => Some(conversation_kind),
			_ => None,
		}
	}
	/// Prepare a metadata replacement using only a committed record with the
	/// same structural identity. Supplied digests confer no ownership of bytes.
	pub fn prepare_put(mut self, prior: Option<&Record>) -> Self {
		use super::index::Identity;
		let prior = prior.filter(|prior| prior.parts() == self.parts());
		if let Some(prior) = prior {
			self.preserve_chronology(prior);
		}
		self.preserve_blobs(prior);
		self
	}
	pub(super) fn preserve_chronology(&mut self, prior: &Record) {
		if let (
			Body::Line { at, order, .. },
			Body::Line {
				at: original_at,
				order: original_order,
				..
			},
		) = (&mut self.body, &prior.body)
		{
			*at = *original_at;
			*order = *original_order;
		}
	}
	pub(super) fn preserve_blobs(&mut self, prior: Option<&Record>) {
		if let Body::Line { attachments, .. } = &mut self.body {
			let prior = prior.and_then(|record| match record.body() {
				Body::Line { attachments, .. } => Some(attachments),
				_ => None,
			});
			for (index, attachment) in attachments.iter_mut().enumerate() {
				attachment.preserve_blob(prior.and_then(|prior| prior.get(index)));
			}
		}
	}
	pub fn retained_bytes(&self) -> usize {
		let mut bytes = core::mem::size_of::<Self>()
			+ self.coordinates.source.heap_bytes()
			+ self.coordinates.generation.heap_bytes()
			+ self.coordinates.id.heap_bytes()
			+ self.directory.heap_bytes();
		bytes += match &self.body {
			Body::Standing { room, nick, .. } => room.heap_bytes() + nick.heap_bytes(),
			Body::Line {
				conversation,
				from,
				text,
				previews,
				attachments,
				..
			} => {
				conversation.heap_bytes()
					+ from.heap_bytes()
					+ text.heap_bytes()
					+ previews.retained_bytes()
					+ attachments.capacity() * core::mem::size_of::<Attachment>()
					+ attachments.iter().map(|a| a.heap_bytes()).sum::<usize>()
			}
		};
		bytes
	}
}
pub(super) fn bounded_text(text: &DocumentText, max: usize, empty: bool) -> Result<(), Error> {
	if let Some(text) = text.as_str() {
		return bounded(text, max, empty);
	}
	let bytes = core::char::decode_utf16(text.utf16())
		.map(|c| c.unwrap_or(char::REPLACEMENT_CHARACTER).len_utf8())
		.sum::<usize>();
	if (!empty && bytes == 0) || bytes > max {
		Err(Error::Record)
	} else {
		Ok(())
	}
}
pub(super) fn bounded(text: &str, max: usize, empty: bool) -> Result<(), Error> {
	if (!empty && text.is_empty()) || text.len() > max {
		Err(Error::Record)
	} else {
		Ok(())
	}
}
pub(super) fn opaque(text: &DocumentText) -> Result<(), Error> {
	bounded_text(text, MAX_ID_BYTES, false)?;
	if text.utf16().any(|c| c <= 0x1f || (0x7f..=0x9f).contains(&c)) {
		Err(Error::Record)
	} else {
		Ok(())
	}
}
pub(super) fn digest(text: &str) -> bool {
	text.len() == 64 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub(super) fn safe(value: u64, positive: bool) -> Result<(), Error> {
	if value < (1 << 53) && (!positive || value != 0) {
		Ok(())
	} else {
		Err(Error::Revision)
	}
}

impl Record {
	/// Storage supplies digests only after all corresponding bytes are durable.
	/// Wire admission still treats supplied record digests as untrusted metadata.
	pub fn with_blob_digests(mut self, digests: Vec<alloc::string::String>) -> Result<Self, Error> {
		let Body::Line { attachments, .. } = &mut self.body else {
			return Err(Error::Blob);
		};
		if attachments.len() != digests.len() || digests.iter().any(|d| !digest(d)) {
			return Err(Error::Blob);
		}
		for (a, digest) in attachments.iter_mut().zip(digests) {
			a.set_blob(digest);
		}
		Ok(self)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn history_presentation_is_the_coordinate_triple() {
		let history = Coordinates::new("room-source".into(), "generation-1".into(), "line-9".into()).unwrap();
		assert_eq!(
			history_data(history),
			json!({"source":"room-source","generation":"generation-1","id":"line-9"})
		);
	}
}
