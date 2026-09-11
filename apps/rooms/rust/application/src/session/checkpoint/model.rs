use super::fields::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct State {
	#[serde(deserialize_with = "version")]
	pub version: u8,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub directories: List<Directory, 32>,
	pub conversations: List<Conversation, { super::MAX_CONVERSATIONS }>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub invitations: List<Invitation, 16>,
	pub active: Nullable<Field>,
	pub standing: Field,
	pub ignored: List<Field, 512>,
	pub keep_history: bool,
	#[serde(deserialize_with = "crate::fields::object")]
	pub join: Join,
	pub dm_mode: DmMode,
	pub viz_override: Field,
	#[serde(deserialize_with = "crate::fields::object")]
	pub capabilities: Capabilities,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub peering: List<Peering, 256>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Directory {
	pub id: Id,
	pub locator: Id,
	pub home: bool,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	pub reached: Option<bool>,
	pub nick: Field,
	pub standing: Nullable<Field>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub(super) enum Conversation {
	Room(alloc::boxed::Box<Room>),
	Direct(alloc::boxed::Box<Direct>),
}
impl<'de> Deserialize<'de> for Conversation {
	fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		use serde::de::Error;
		let raw = <&serde_json::value::RawValue>::deserialize(d)?;
		#[derive(Deserialize)]
		struct Tag {
			kind: alloc::string::String,
		}
		let tag: Tag = crate::fields::json_object(raw.get()).map_err(D::Error::custom)?;
		match tag.kind.as_str() {
			"room" => serde_json::from_str(raw.get())
				.map(Self::Room)
				.map_err(D::Error::custom),
			"direct" => serde_json::from_str(raw.get())
				.map(Self::Direct)
				.map_err(D::Error::custom),
			_ => Err(D::Error::custom("checkpoint conversation kind")),
		}
	}
}
impl Conversation {
	pub fn id(&self) -> &Id {
		match self {
			Self::Room(v) => &v.id,
			Self::Direct(v) => &v.id,
		}
	}
	pub fn directory(&self) -> &Id {
		match self {
			Self::Room(v) => &v.directory,
			Self::Direct(v) => &v.directory,
		}
	}
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct Room {
	pub kind: RoomKind,
	pub id: Id,
	pub directory: Id,
	pub name: Text<32, true>,
	pub held: bool,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	pub reconnect: Option<Reconnect>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub link: Option<Bearer>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub manager: Option<Bearer>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub steward: Option<Bearer>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub publication_id: Option<Field>,
	pub standing: Nullable<Field>,
	pub draft: Field,
	#[serde(
		default,
		deserialize_with = "bridge_intent",
		skip_serializing_if = "Presence::missing"
	)]
	pub bridge_intent: Presence<Bridge>,
}
fn bridge_intent<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Presence<Bridge>, D::Error> {
	Ok(match Nullable::<crate::fields::Object<Bridge>>::deserialize(d)? {
		Nullable::Null => Presence::Null,
		Nullable::Value(value) => Presence::Value(value.0),
	})
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct Bridge {
	pub scope: Text<64, true>,
	pub action: Id,
	pub answers: Answers,
	pub secrets_given: bool,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub credential_revision: Option<Text<128, true>>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct Direct {
	pub kind: DirectKind,
	pub id: Id,
	pub directory: Id,
	pub peer: Id,
	pub peer_registration_id: Field,
	pub closed: bool,
	pub draft: Field,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Invitation {
	pub kind: InvitationKind,
	pub id: Id,
	pub directory: Id,
	pub locator: Text<16384, true>,
	pub nick: Field,
	pub label: Field,
	pub from: Field,
	pub link: Bearer,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Join {
	pub room: Field,
	pub locator: Field,
	pub nick: Field,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct Capabilities {
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub operations: List<Credential, 64>,
	pub archive_peer: Nullable<Bearer>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Credential {
	pub capability: Operation,
	pub scope: Text<16384, true>,
	pub swiss: Bearer,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Peering {
	pub id: Id,
	pub destination: Text<16384, true>,
	pub source: Id,
	pub name: Text<32, true>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Reconnect {
	Manual,
	Requested,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum DmMode {
	Webrtc,
	Relay,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) enum InvitationKind {
	#[serde(rename = "room-link")]
	RoomLink,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) enum RoomKind {
	#[serde(rename = "room")]
	Room,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) enum DirectKind {
	#[serde(rename = "direct")]
	Direct,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Operation {
	Listeners,
	Diagnostics,
	Irc,
	Operator,
	Peering,
	Viz,
}
impl Operation {
	pub fn wire(self) -> &'static str {
		match self {
			Self::Listeners => "listeners",
			Self::Diagnostics => "diagnostics",
			Self::Irc => "irc",
			Self::Operator => "operator",
			Self::Peering => "peering",
			Self::Viz => "viz",
		}
	}
}

impl State {
	pub fn empty() -> Self {
		Self {
			version: 1,
			directories: List(alloc::vec::Vec::new()),
			conversations: List(alloc::vec::Vec::new()),
			invitations: List(alloc::vec::Vec::new()),
			active: Nullable::Null,
			standing: Text("".into()),
			ignored: List(alloc::vec::Vec::new()),
			keep_history: true,
			join: Join {
				room: Text("".into()),
				locator: Text("".into()),
				nick: Text("".into()),
			},
			dm_mode: DmMode::Webrtc,
			viz_override: Text("".into()),
			capabilities: Capabilities {
				operations: List(alloc::vec::Vec::new()),
				archive_peer: Nullable::Null,
			},
			peering: List(alloc::vec::Vec::new()),
		}
	}
}
