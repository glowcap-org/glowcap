//! Version-one workspace payload: user intent and typed custody coordinates.
//! It contains no bearer codec, grant state, canonical parent or history floor.
//! Loading these values alone cannot restore any retained application authority.
use super::custody::{self, Custody, FieldKey, References};
use crate::{
	directory::registration::NicknameAllocation,
	fields::{List, Text},
};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error};
mod discovery;
mod export;
pub use export::{ConfigurationImport, ImportRecipe};
mod presentation;
pub use presentation::PresentationImport;
mod archive;
pub use archive::{MAX_ARCHIVE_SHARES, ReceivedArchive};
mod signaling;
pub use signaling::SignalingSelection;
mod footprint;
pub mod history;
mod inbox;
pub use discovery::DiscoverySelection;
mod nickname;
mod references;
pub use inbox::InboxSelection;
pub use nickname::RoomNickname;
pub(super) use references::coordinate;

pub const MAX_ID_UNITS: usize = 1024;
pub type Id = Text<MAX_ID_UNITS, true>;
pub type Field = Text<4096>;
pub type Standing = Text<{ crate::room::membership::MAX_AWAY }>;
pub const MAX_DIRECTORIES: usize = 32;
pub const MAX_CONVERSATIONS: usize = 256;
pub const MAX_INVITATIONS: usize = 16;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Directory {
	pub id: Id,
	pub access: FieldKey<custody::DirectoryAccess>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub name: Option<FieldKey<custody::DirectoryName>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub source: Option<FieldKey<custody::SessionAccess>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub inbox: Option<FieldKey<custody::DirectoryInbox>>,
	pub home: bool,
	pub nick: Text<32>,
	/// Registration output never replaces the user's requested nickname.
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub assigned_nick: Option<Text<32>>,
	pub nick_allocation: NicknameAllocation,
	pub standing: Option<Standing>,
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
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub source: Option<FieldKey<custody::SessionAccess>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub inbox: Option<FieldKey<custody::RoomInbox>>,
	pub access: Option<FieldKey<custody::RoomAccess>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub accepted: Option<FieldKey<custody::AcceptedAccess>>,
	/// Public membership reopens this exact publication through its retained
	/// directory authority. An accepted visit is connection-lived, not a durable
	/// entrance, and a display name cannot select a replacement publication.
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub public_entry: Option<PublicEntry>,
	/// Descriptive public generation, retained when its entrance becomes a link.
	/// Dispatch still requires separately held directory or room authority.
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub publication: Option<Text<128, true>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub seat: Option<FieldKey<custody::RoomSeat>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub topic: Option<FieldKey<custody::RoomTopic>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub files: Option<FieldKey<custody::RoomFiles>>,
	#[serde(
		default,
		deserialize_with = "crate::fields::object_list",
		skip_serializing_if = "List::is_empty"
	)]
	pub lines: List<PostedLine, 256>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub moderator: Option<FieldKey<custody::RoomAccess>>,
	pub control: Option<FieldKey<custody::RoomControl>>,
	pub reconnect: Reconnect,
	pub standing: Option<Standing>,
	pub draft: Field,
}

impl Room {
	/// Keep an independently held seat; otherwise join only by explicit intent.
	/// Room visibility is learned from the upstream policy, never this choice.
	pub fn requests_membership(&self) -> bool {
		self.seat.is_some() || self.reconnect == Reconnect::Requested
	}
	pub fn has_entrance(&self) -> bool {
		usize::from(self.access.is_some())
			+ usize::from(self.accepted.is_some())
			+ usize::from(self.public_entry.is_some())
			== 1
	}
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublicEntry {
	pub access: FieldKey<custody::DirectoryAccess>,
}

/// A display identity selects an already held line actor in this conversation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PostedLine {
	pub id: crate::session::state::SafeInteger,
	pub handle: FieldKey<custody::Line>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Direct {
	pub kind: DirectKind,
	pub id: Id,
	pub directory: Id,
	pub peer: Id,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub source: Option<FieldKey<custody::SessionAccess>>,
	pub access: Option<FieldKey<custody::DirectAccess>>,
	/// A directory introduction binds this conversation to the exact local and
	/// peer registrations. An incoming receiver can precede its reciprocal route;
	/// a nickname cannot renew either occurrence.
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub introduction: Option<Introduction>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub inbox: Option<FieldKey<custody::DirectInbox>>,
	#[serde(
		default,
		deserialize_with = "crate::fields::object_list",
		skip_serializing_if = "List::is_empty"
	)]
	pub lines: List<PostedLine, 256>,
	pub closed: bool,
	pub draft: Field,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Introduction {
	pub access: FieldKey<custody::DirectoryAccess>,
	pub name: FieldKey<custody::DirectoryName>,
	pub callback: FieldKey<custody::DirectoryInbox>,
	pub registration: Text<64, true>,
	/// Retries retain this opening; a fresh gesture cannot revive its callback.
	pub opening: Text<128, true>,
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
	pub fn lines(&self) -> &[PostedLine] {
		match self {
			Self::Room(room) => room.lines.as_slice(),
			Self::Direct(direct) => direct.lines.as_slice(),
		}
	}
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
	pub authority: InvitationAuthority,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub source: Option<FieldKey<custody::SessionAccess>>,
	pub label: Field,
	pub from: Field,
}
/// A claimable offer and an already handed entrance have different acceptance
/// paths. Both remain exact custody while the person decides whether to enter.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "role", content = "key", rename_all = "camelCase")]
pub enum InvitationAuthority {
	Offer(FieldKey<custody::Offer>),
	RoomAccess(FieldKey<custody::RoomAccess>),
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

/// Each declared interface selects one already held operations capability.
/// A connection has its own exact custody; its display name cannot restore it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Operations {
	pub kind: crate::session::operations::mutation::Kind,
	pub handle: custody::Coordinate,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub connection: Option<ConnectionSelection>,
}
/// These correlators identify an acquired connection's original gesture and
/// gateway selection. Only `Operations::handle` holds live authority.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectionSelection {
	pub operation: crate::session::state::OperationId,
	pub gateway: custody::Coordinate,
	pub id: Text<128, true>,
}

/// Independent held use and control. This row selects saved occurrences only;
/// labels, permissions, status and revisions belong to Loam's managed owner.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Access {
	pub id: Id,
	pub access: Option<FieldKey<custody::SessionAccess>>,
	pub control: Option<FieldKey<custody::SessionControl>>,
}
impl Operations {
	pub fn valid(&self) -> bool {
		let role = self.handle.role
			== if self.kind == crate::session::operations::mutation::Kind::IrcConnection {
				custody::Role::IrcConnection
			} else {
				custody::Role::Operations
			};
		role && match (&self.connection, self.kind) {
			(Some(connection), crate::session::operations::mutation::Kind::IrcConnection) => {
				connection.gateway.role == custody::Role::Operations
			}
			(None, crate::session::operations::mutation::Kind::IrcConnection) => false,
			(None, _) => true,
			_ => false,
		}
	}
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Intent {
	pub version: Version,
	#[serde(
		default,
		deserialize_with = "crate::fields::object_list",
		skip_serializing_if = "List::is_empty"
	)]
	pub accesses: List<Access, 256>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub directories: List<Directory, MAX_DIRECTORIES>,
	pub conversations: List<Conversation, MAX_CONVERSATIONS>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub invitations: List<Invitation, MAX_INVITATIONS>,
	pub active: Option<Id>,
	pub standing: Standing,
	pub ignored: List<Field, 512>,
	pub keep_history: bool,
	/// The committed operation that must erase this owner's local history before
	/// recording can be enabled again. Recovery repeats that idempotent local
	/// erasure; exported intent alone never supplies the backend authority.
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub history_erasure: Option<crate::session::state::OperationId>,
	pub connection: Connection,
	pub archive: Option<FieldKey<custody::ArchiveAccess>>,
	pub archive_control: Option<FieldKey<custody::ArchiveControl>>,
	#[serde(
		default,
		deserialize_with = "crate::fields::object_list",
		skip_serializing_if = "List::is_empty"
	)]
	pub archive_shares: List<ReceivedArchive, MAX_ARCHIVE_SHARES>,
	pub operators: List<FieldKey<custody::Operator>, 64>,
	#[serde(
		default,
		deserialize_with = "crate::fields::object_list",
		skip_serializing_if = "List::is_empty"
	)]
	pub operations: List<Operations, 64>,
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
	/// Effective standing preserves explicit empty overrides at both scopes.
	pub fn room_standing(&self, id: &str) -> Option<&Standing> {
		let room = self.conversations.as_slice().iter().find_map(|row| match row {
			Conversation::Room(room) if room.id.text().as_str() == Some(id) => Some(room),
			_ => None,
		})?;
		let directory = self
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id == room.directory)?;
		Some(
			room.standing
				.as_ref()
				.or(directory.standing.as_ref())
				.unwrap_or(&self.standing),
		)
	}
	/// Importing presentation and custody cannot cancel an admitted erasure or
	/// bypass the recording fence. Retention changes use their dedicated command.
	pub fn replace_configuration(&mut self, next: Self) -> Result<(), InvalidIntent> {
		self.check_configuration(&next)?;
		*self = next;
		Ok(())
	}
	fn check_configuration(&self, next: &Self) -> Result<(), InvalidIntent> {
		if next.keep_history != self.keep_history || next.history_erasure != self.history_erasure {
			return Err(InvalidIntent::Custody);
		}
		for candidate in next.conversations.as_slice() {
			let Conversation::Direct(candidate) = candidate else {
				continue;
			};
			let previous = self.conversations.as_slice().iter().find_map(|row| match row {
				Conversation::Direct(row) if row.id == candidate.id => Some(row.as_ref()),
				_ => None,
			});
			// A replacement callback starts its ordinal at one. It cannot reuse
			// the retained route's watermark from another callback lifetime.
			if candidate.inbox.is_some_and(|inbox| {
				candidate.access.is_some_and(|route| route.slot() == inbox.slot())
					&& previous.is_none_or(|row| row.inbox != candidate.inbox)
			}) {
				return Err(InvalidIntent::Custody);
			}
		}
		for row in self.operations.as_slice() {
			if row.connection.is_some()
				&& next
					.operations
					.as_slice()
					.iter()
					.any(|candidate| candidate.handle == row.handle && candidate.connection != row.connection)
			{
				return Err(InvalidIntent::Custody);
			}
		}
		for row in self.peering.as_slice() {
			if next
				.peering
				.as_slice()
				.iter()
				.any(|candidate| candidate.lease == row.lease && candidate != row)
			{
				return Err(InvalidIntent::Custody);
			}
		}
		Ok(())
	}
	/// Initial user intent contains no capability coordinates. Custody enters
	/// through an explicit checked import after the managed owner is created.
	pub fn empty() -> Self {
		fn empty<T, const N: usize>() -> List<T, N> {
			List::new(alloc::vec::Vec::new()).expect("empty bounded list")
		}
		Self {
			version: Version::V1,
			accesses: empty(),
			directories: empty(),
			conversations: empty(),
			invitations: empty(),
			active: None,
			standing: Text::new("".into()).expect("empty standing"),
			ignored: empty(),
			keep_history: true,
			history_erasure: None,
			connection: Connection::Relay,
			archive: None,
			archive_control: None,
			archive_shares: empty(),
			operators: empty(),
			operations: empty(),
			peering: empty(),
		}
	}
	pub fn decode(raw: &str) -> Result<Self, DecodeError> {
		if raw.len() > custody::MAX_AUTHORITY_BYTES {
			return Err(DecodeError::Capacity);
		}
		crate::fields::json_object(raw).map_err(DecodeError::Json)
	}

	/// Check data relationships and the existence of exact held fields. This is
	/// not grant admission: shared access and upstream roles still authorize use.
	pub fn validate<R: References>(&self, custody: &Custody<R>) -> Result<(), InvalidIntent> {
		self.validate_archive_shares()?;
		for (at, row) in self.accesses.as_slice().iter().enumerate() {
			if row.access.is_none() && row.control.is_none() {
				return Err(InvalidIntent::Custody);
			}
			if self.accesses.as_slice()[..at].iter().any(|prior| prior.id == row.id) {
				return Err(InvalidIntent::Duplicate);
			}
		}
		for (at, row) in self.operations.as_slice().iter().enumerate() {
			if !row.valid()
				|| self.operations.as_slice()[..at]
					.iter()
					.any(|prior| prior.handle == row.handle)
			{
				return Err(InvalidIntent::Custody);
			}
		}
		let directories = self.directories.as_slice();
		let conversations = self.conversations.as_slice();
		if directories.iter().filter(|row| row.home).count() > 1 {
			return Err(InvalidIntent::Home);
		}
		for (i, directory) in directories.iter().enumerate() {
			if directories[..i].iter().any(|row| row.id == directory.id) {
				return Err(InvalidIntent::Duplicate);
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
					if room.public_entry.is_some() && room.publication.is_none() {
						return Err(InvalidIntent::Custody);
					}
					if usize::from(room.access.is_some())
						+ usize::from(room.accepted.is_some())
						+ usize::from(room.public_entry.is_some())
						> 1
					{
						return Err(InvalidIntent::Custody);
					}
					!room.requests_membership() || room.has_entrance() || room.seat.is_some()
				}
				Conversation::Direct(direct) => {
					// Each conversation owns its reply route's custody generation.
					// Equal actual capabilities may be held at independent keys;
					// sharing a key would let one handshake retire another route.
					if direct.access.is_some()
						&& conversations[..i]
							.iter()
							.any(|row| matches!(row, Conversation::Direct(other) if other.access == direct.access))
					{
						return Err(InvalidIntent::Custody);
					}
					// Installation reserves the callback slot for ordered reply
					// handoffs before any peer can invoke the callback.
					if direct.inbox.is_some_and(|inbox| {
						custody.fields().any(|field| {
							let coordinate = field.coordinate();
							coordinate.role == custody::Role::DirectAccess
								&& coordinate.key.slot() == inbox.slot()
								&& direct.access.is_none_or(|own| {
									own.slot() != coordinate.key.slot()
										|| own.generation() != coordinate.key.generation()
								})
						})
					}) {
						return Err(InvalidIntent::Custody);
					}
					if let Some(introduction) = &direct.introduction {
						let registration = introduction
							.registration
							.text()
							.as_str()
							.ok_or(InvalidIntent::Custody)?;
						if crate::directory::registration::Id::parse(registration).is_err() {
							return Err(InvalidIntent::Custody);
						}
					}
					direct.closed || direct.access.is_some() || direct.introduction.is_some()
				}
			};
			for (i, line) in conversation.lines().iter().enumerate() {
				if crate::room::message::LineId::new(line.id.get()).is_none()
					|| conversation.lines()[..i].iter().any(|prior| prior.id == line.id)
				{
					return Err(InvalidIntent::Custody);
				}
			}
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
		}
		for (i, peering) in self.peering.as_slice().iter().enumerate() {
			if self.peering.as_slice()[..i].iter().any(|row| row.id == peering.id) {
				return Err(InvalidIntent::Duplicate);
			}
			if !directories.iter().any(|row| row.id == peering.directory) {
				return Err(InvalidIntent::Directory);
			}
		}
		if self.coordinates().any(|coordinate| custody.get(coordinate).is_none()) {
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
	pub outgoing: List<super::outgoing::Origin, { custody::MAX_FIELDS_PER_ROLE }>,
	pub bridges: List<super::bridge::Witness, { super::bridge::MAX_WITNESSES }>,
	pub effects: custody::EffectReceipts<R>,
}
