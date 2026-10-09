//! Presentation imports edit scalar preferences on existing held topology.
//! Display identities never install custody or reconstruct a conversation.
use super::{Conversation, Field, Id, Intent, MAX_CONVERSATIONS, MAX_DIRECTORIES, Standing};
use crate::fields::{List, Text};
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PresentationImport {
	#[serde(deserialize_with = "crate::fields::json_u64")]
	version: u64,
	kind: alloc::string::String,
	#[serde(deserialize_with = "crate::fields::object_list")]
	directories: List<Directory, MAX_DIRECTORIES>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	conversations: List<Row, MAX_CONVERSATIONS>,
	standing: Standing,
	ignored: List<Field, 512>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Directory {
	id: Id,
	#[serde(rename = "nick")]
	_nick: Text<32>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Row {
	kind: Kind,
	id: Id,
	directory: Id,
	label: Id,
	draft: Field,
}
#[derive(Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Kind {
	Room,
	Direct,
}

impl PresentationImport {
	pub fn decode(raw: &str) -> Result<Self, &'static str> {
		if raw.len() > super::custody::MAX_AUTHORITY_BYTES {
			return Err("Presentation exceeds its byte bound");
		}
		let input: Self = crate::fields::json_object(raw).map_err(|_| "Invalid presentation envelope")?;
		if input.version != 1 || input.kind != "rooms-presentation" {
			return Err("Unsupported presentation format");
		}
		for (index, row) in input.directories.as_slice().iter().enumerate() {
			if input.directories.as_slice()[..index]
				.iter()
				.any(|prior| prior.id == row.id)
			{
				return Err("Duplicate presentation directory");
			}
		}
		for (index, row) in input.conversations.as_slice().iter().enumerate() {
			if input.conversations.as_slice()[..index]
				.iter()
				.any(|prior| prior.id == row.id)
			{
				return Err("Duplicate presentation conversation");
			}
			if !input
				.directories
				.as_slice()
				.iter()
				.any(|directory| directory.id == row.directory)
			{
				return Err("Presentation conversation has no directory");
			}
		}
		Ok(input)
	}
	/// The bounded decoded preferences move into one admitted candidate copy.
	/// Existing coordinates and observations retain their current authority.
	pub fn apply(self, current: &Intent) -> Result<Intent, &'static str> {
		let mut next = current.clone();
		for row in self.conversations.0 {
			let Some(selected) = next
				.conversations
				.as_mut_slice()
				.iter_mut()
				.find(|selected| selected.id() == &row.id)
			else {
				continue;
			};
			match selected {
				Conversation::Room(room)
					if row.kind == Kind::Room
						&& room.directory == row.directory
						&& room.name.text() == row.label.text() =>
				{
					room.draft = row.draft
				}
				Conversation::Direct(direct)
					if row.kind == Kind::Direct && direct.directory == row.directory && direct.peer == row.label =>
				{
					direct.draft = row.draft
				}
				_ => return Err("Presentation identity no longer matches the held conversation"),
			}
		}
		next.standing = self.standing;
		next.ignored = self.ignored;
		Ok(next)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn display_import_cannot_install_authority_and_refuses_ambiguous_material() {
		let raw = r#"{"version":1,"kind":"rooms-presentation","directories":[{"id":"d","nick":"self"}],"conversations":[{"kind":"room","id":"r","directory":"d","label":"garden","draft":"draft"}],"standing":"here","ignored":[]}"#;
		let next = PresentationImport::decode(raw)
			.unwrap()
			.apply(&Intent::empty())
			.unwrap();
		assert!(next.conversations.is_empty());
		assert_eq!(next.coordinates().count(), 0);
		assert_eq!(next.standing.text().as_str(), Some("here"));
		assert!(PresentationImport::decode(&raw.replace("\"ignored\":[]", "\"ignored\":[],\"custody\":[]")).is_err());
		assert!(PresentationImport::decode(&raw.replace("\"version\":1", "\"version\":2")).is_err());
		assert!(PresentationImport::decode(&raw.replace("\"directory\":\"d\"", "\"directory\":\"missing\"")).is_err());
	}
}
