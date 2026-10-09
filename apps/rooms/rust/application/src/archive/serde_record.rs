//! Archive JSON maps retain document text without serde's tagged-enum
//! buffering. Raw fields are consumed into the one validated `Record` owner.
use super::*;
use crate::fields::{List, Nullable, SafeInteger, Text, present};
use serde::{Deserialize, Deserializer, Serialize, Serializer, ser::SerializeMap};
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Fields {
	kind: Kind,
	source: Text<128, true>,
	generation: Text<128, true>,
	id: Text<128, true>,
	directory: Text<8192, true>,
	at: SafeInteger,
	#[serde(default, deserialize_with = "present")]
	room: Option<Text<MAX_CONVERSATION_BYTES, true>>,
	#[serde(default, deserialize_with = "present")]
	nick: Option<Text<32>>,
	#[serde(default, deserialize_with = "present")]
	conversation_kind: Option<ConversationKind>,
	#[serde(default, deserialize_with = "present")]
	conversation: Option<Text<MAX_CONVERSATION_BYTES, true>>,
	#[serde(default, deserialize_with = "present")]
	from: Option<Text<32>>,
	#[serde(default, deserialize_with = "present")]
	text: Option<Text<8192>>,
	#[serde(default, deserialize_with = "present")]
	mine: Option<bool>,
	#[serde(default, deserialize_with = "present")]
	order: Option<SafeInteger<true>>,
	#[serde(default, deserialize_with = "present")]
	state: Option<LineState>,
	#[serde(default, deserialize_with = "present")]
	attachments: Option<List<File, 8>>,
	#[serde(rename = "previewUrls", default, deserialize_with = "present")]
	previews: Option<List<Text<2048, true>, 5>>,
}
use alloc::{string::String, vec::Vec};
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
	name: Text<160, true>,
	mime: Text<80>,
	size: SafeInteger,
	width: SafeInteger,
	height: SafeInteger,
	blob: Nullable<String>,
}
impl TryFrom<Fields> for Record {
	type Error = Error;
	fn try_from(f: Fields) -> Result<Self, Error> {
		let body = match f.kind {
			Kind::Standing => {
				if f.conversation_kind.is_some()
					|| f.conversation.is_some()
					|| f.from.is_some()
					|| f.text.is_some()
					|| f.mine.is_some()
					|| f.order.is_some()
					|| f.state.is_some()
					|| f.attachments.is_some()
					|| f.previews.is_some()
				{
					return Err(Error::Record);
				}
				Body::Standing {
					room: f.room.ok_or(Error::Record)?.0,
					nick: f.nick.ok_or(Error::Record)?.0,
					at: f.at.get(),
				}
			}
			Kind::Line => {
				if f.room.is_some() || f.nick.is_some() {
					return Err(Error::Record);
				}
				let text = f.text.ok_or(Error::Record)?.0;
				let preview_values = f.previews.map_or_else(Vec::new, |values| values.0);
				let previews = if preview_values.is_empty() {
					crate::open_graph::Selection::default()
				} else {
					crate::open_graph::Selection::new(
						text.as_str().ok_or(Error::Record)?,
						preview_values
							.iter()
							.map(|url| url.0.as_str().ok_or(Error::Record))
							.collect::<Result<Vec<_>, _>>()?,
					)
					.map_err(|_| Error::Record)?
				};
				let conversation_kind = f.conversation_kind.ok_or(Error::Record)?;
				let state = f.state.ok_or(Error::Record)?;
				let attachments = f
					.attachments
					.ok_or(Error::Record)?
					.0
					.into_iter()
					.map(|a| {
						Attachment::new(
							a.name.0,
							a.mime.0,
							a.size.get(),
							a.width.get(),
							a.height.get(),
							match a.blob {
								Nullable::Value(v) => Some(v),
								Nullable::Null => None,
							},
						)
					})
					.collect::<Result<_, _>>()?;
				Body::Line {
					conversation_kind,
					conversation: f.conversation.ok_or(Error::Record)?.0,
					from: f.from.ok_or(Error::Record)?.0,
					text,
					mine: f.mine.ok_or(Error::Record)?,
					at: f.at.get(),
					order: f.order.ok_or(Error::Record)?.get(),
					state,
					previews,
					attachments,
				}
			}
		};
		Record::new(
			Coordinates {
				source: f.source.0,
				generation: f.generation.0,
				id: f.id.0,
			},
			f.directory.0,
			body,
		)
	}
}
impl<'de> Deserialize<'de> for Record {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		Fields::deserialize(d)?.try_into().map_err(serde::de::Error::custom)
	}
}
impl Serialize for Record {
	fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		let mut map = s.serialize_map(Some(if self.kind() == Kind::Standing { 8 } else { 15 }))?;
		map.serialize_entry(
			"kind",
			if self.kind() == Kind::Standing {
				"standing"
			} else {
				"line"
			},
		)?;
		let c = self.coordinates();
		map.serialize_entry("source", &c.source)?;
		map.serialize_entry("generation", &c.generation)?;
		map.serialize_entry("id", &c.id)?;
		map.serialize_entry("directory", self.directory())?;
		match self.body() {
			Body::Standing { room, nick, at } => {
				map.serialize_entry("room", room)?;
				map.serialize_entry("nick", nick)?;
				map.serialize_entry("at", at)?;
			}
			Body::Line {
				conversation_kind,
				conversation,
				from,
				text,
				mine,
				at,
				order,
				state,
				previews,
				attachments,
			} => {
				map.serialize_entry(
					"conversationKind",
					match conversation_kind {
						ConversationKind::Room => "room",
						ConversationKind::Direct => "direct",
					},
				)?;
				map.serialize_entry("conversation", conversation)?;
				map.serialize_entry("from", from)?;
				map.serialize_entry("text", text)?;
				map.serialize_entry("mine", mine)?;
				map.serialize_entry("at", at)?;
				map.serialize_entry("order", order)?;
				map.serialize_entry(
					"state",
					match state {
						LineState::Present => "present",
						LineState::Edited => "edited",
						LineState::Withdrawn => "withdrawn",
					},
				)?;
				map.serialize_entry("previewUrls", previews)?;
				map.serialize_entry("attachments", attachments)?;
			}
		}
		map.end()
	}
}
impl Serialize for Attachment {
	fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		let mut map = s.serialize_map(Some(6))?;
		let (width, height) = self.dimensions();
		map.serialize_entry("name", self.name())?;
		map.serialize_entry("mime", self.mime())?;
		map.serialize_entry("size", &self.size())?;
		map.serialize_entry("width", &width)?;
		map.serialize_entry("height", &height)?;
		map.serialize_entry("blob", &self.blob())?;
		map.end()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn archive_json_uses_the_shared_browser_preview_field() {
		let input = r#"{
			"kind":"line", "source":"source", "generation":"generation", "id":"line",
			"directory":"directory", "conversationKind":"room", "conversation":"garden",
			"from":"alice", "text":"https://example.com/story", "mine":false,
			"at":1, "order":1, "state":"present",
			"previewUrls":["https://example.com/story"], "attachments":[]
		}"#;
		let record: Record = serde_json::from_str(input).unwrap();
		let output = serde_json::to_value(record).unwrap();
		assert_eq!(output["previewUrls"][0], "https://example.com/story");
		assert!(output.get("previews").is_none());
	}
}
