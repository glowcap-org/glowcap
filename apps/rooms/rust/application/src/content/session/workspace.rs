//! Version-one workspace payload: user intent and typed custody coordinates.
//! It contains no bearer codec, grant state, canonical parent or history floor.
//! Loading these values alone cannot restore any retained application authority.
use super::custody::{self, Custody, FieldKey, References};
use crate::{
	directory::registration::NicknameAllocation,
	fields::{List, Text},
};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error};

pub type Id = Text<1024, true>;
pub type Field = Text<4096>;
pub const MAX_DIRECTORIES: usize = 32;
pub const MAX_CONVERSATIONS: usize = 256;
pub const MAX_INVITATIONS: usize = 16;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Directory {
	pub id: Id,
	pub access: FieldKey<custody::DirectoryAccess>,
	pub home: bool,
	pub nick: Text<32>,
	pub nick_allocation: NicknameAllocation,
	pub standing: Option<Field>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum Conversation {
	Room(alloc::boxed::Box<Room>),
	Direct(alloc::boxed::Box<Direct>),
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Room {
	pub kind: RoomKind,
	pub id: Id,
	pub directory: Id,
	pub name: Text<32, true>,
	pub access: Option<FieldKey<custody::RoomAccess>>,
	pub control: Option<FieldKey<custody::RoomControl>>,
	pub held: bool,
	pub reconnect: Reconnect,
	pub standing: Option<Field>,
	pub draft: Field,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Direct {
	pub kind: DirectKind,
	pub id: Id,
	pub directory: Id,
	pub peer: Id,
	pub access: Option<FieldKey<custody::DirectAccess>>,
	pub closed: bool,
	pub draft: Field,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RoomKind {
	#[serde(rename = "room")]
	Room,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DirectKind {
	#[serde(rename = "direct")]
	Direct,
}
// Buffer only the raw object: Serde's internally tagged content buffer cannot
// preserve RawValue-backed UTF-16 fields, including isolated surrogates.
impl<'de> Deserialize<'de> for Conversation {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let raw = <&serde_json::value::RawValue>::deserialize(d)?;
		#[derive(Deserialize)]
		struct Tag {
			kind: Text<6, true>,
		}
		let tag: Tag = crate::fields::json_object(raw.get()).map_err(D::Error::custom)?;
		match tag.kind.text().as_str() {
			Some("room") => crate::fields::json_object(raw.get())
				.map(|v| Self::Room(alloc::boxed::Box::new(v)))
				.map_err(D::Error::custom),
			Some("direct") => crate::fields::json_object(raw.get())
				.map(|v| Self::Direct(alloc::boxed::Box::new(v)))
				.map_err(D::Error::custom),
			_ => Err(D::Error::custom("workspace conversation kind")),
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reconnect {
	Manual,
	Requested,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Connection {
	Webrtc,
	Relay,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Invitation {
	pub id: Id,
	pub directory: Id,
	pub offer: FieldKey<custody::Offer>,
	pub label: Field,
	pub from: Field,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Peering {
	pub id: Id,
	pub directory: Id,
	pub room: FieldKey<custody::RoomAccess>,
	pub lease: FieldKey<custody::PublicationLease>,
	pub name: Text<32, true>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Intent {
	pub version: Version,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub directories: List<Directory, MAX_DIRECTORIES>,
	pub conversations: List<Conversation, MAX_CONVERSATIONS>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub invitations: List<Invitation, MAX_INVITATIONS>,
	pub active: Option<Id>,
	pub standing: Field,
	pub ignored: List<Field, 512>,
	pub keep_history: bool,
	pub connection: Connection,
	pub archive: Option<FieldKey<custody::ArchiveAccess>>,
	pub archive_control: Option<FieldKey<custody::ArchiveControl>>,
	pub operators: List<FieldKey<custody::Operator>, 64>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub peering: List<Peering, 256>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Version {
	V1,
}
impl Serialize for Version {
	fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		s.serialize_u16(super::VERSION)
	}
}
impl<'de> Deserialize<'de> for Version {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		if u16::deserialize(d)? == super::VERSION {
			Ok(Self::V1)
		} else {
			Err(D::Error::custom("session content version"))
		}
	}
}

#[derive(Debug)]
pub enum DecodeError {
	Capacity,
	Json(serde_json::Error),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidIntent {
	Home,
	Duplicate,
	Directory,
	Active,
	Custody,
}
impl Intent {
	pub fn decode(raw: &str) -> Result<Self, DecodeError> {
		if raw.len() > custody::MAX_AUTHORITY_BYTES {
			return Err(DecodeError::Capacity);
		}
		crate::fields::json_object(raw).map_err(DecodeError::Json)
	}

	/// Check data relationships and the existence of exact held fields. This is
	/// not grant admission: shared access and upstream roles still authorize use.
	pub fn validate<R: References>(&self, custody: &Custody<R>) -> Result<(), InvalidIntent> {
		let directories = self.directories.as_slice();
		let conversations = self.conversations.as_slice();
		if directories.iter().filter(|row| row.home).count() > 1 {
			return Err(InvalidIntent::Home);
		}
		for (i, directory) in directories.iter().enumerate() {
			if directories[..i].iter().any(|row| row.id == directory.id) {
				return Err(InvalidIntent::Duplicate);
			}
			if custody.directory_access(directory.access).is_none() {
				return Err(InvalidIntent::Custody);
			}
		}
		for (i, conversation) in conversations.iter().enumerate() {
			if conversations[..i].iter().any(|row| row.id() == conversation.id()) {
				return Err(InvalidIntent::Duplicate);
			}
			if !directories.iter().any(|row| &row.id == conversation.directory()) {
				return Err(InvalidIntent::Directory);
			}
			let exists = match conversation {
				Conversation::Room(room) => {
					room.access.is_none_or(|key| custody.room_access(key).is_some())
						&& (!room.held || room.access.is_some())
						&& room.control.is_none_or(|key| custody.room_control(key).is_some())
				}
				Conversation::Direct(direct) => {
					direct.access.is_none_or(|key| custody.direct_access(key).is_some())
						&& (direct.closed || direct.access.is_some())
				}
			};
			if !exists {
				return Err(InvalidIntent::Custody);
			}
		}
		if self
			.active
			.as_ref()
			.is_some_and(|active| !conversations.iter().any(|row| row.id() == active))
		{
			return Err(InvalidIntent::Active);
		}
		for (i, invitation) in self.invitations.as_slice().iter().enumerate() {
			if self.invitations.as_slice()[..i]
				.iter()
				.any(|row| row.id == invitation.id)
			{
				return Err(InvalidIntent::Duplicate);
			}
			if !directories.iter().any(|row| row.id == invitation.directory) {
				return Err(InvalidIntent::Directory);
			}
			if custody.offer(invitation.offer).is_none() {
				return Err(InvalidIntent::Custody);
			}
		}
		for (i, peering) in self.peering.as_slice().iter().enumerate() {
			if self.peering.as_slice()[..i].iter().any(|row| row.id == peering.id) {
				return Err(InvalidIntent::Duplicate);
			}
			if !directories.iter().any(|row| row.id == peering.directory) {
				return Err(InvalidIntent::Directory);
			}
			if custody.room_access(peering.room).is_none() || custody.publication_lease(peering.lease).is_none() {
				return Err(InvalidIntent::Custody);
			}
		}
		if self.archive.is_some_and(|key| custody.archive_access(key).is_none())
			|| self
				.archive_control
				.is_some_and(|key| custody.archive_control(key).is_none())
			|| self
				.operators
				.as_slice()
				.iter()
				.any(|key| custody.operator(*key).is_none())
		{
			return Err(InvalidIntent::Custody);
		}
		Ok(())
	}
}

/// The managed resource supplies identity/containment; content stores intent,
/// typed custody and receipts in that owner's transaction. Store codecs must
/// enforce VERSION and MAX_AUTHORITY_BYTES before admitting persisted records.
pub struct Record<R: References, C> {
	pub binding: custody::ResourceBinding<C>,
	pub intent: Intent,
	pub custody: Custody<R>,
	pub effects: custody::EffectReceipts<R>,
}
