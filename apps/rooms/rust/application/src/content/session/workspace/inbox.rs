//! Callback identity selects one installed live inbox. Registration and seat
//! acquisition may change their result fields without replacing this identity.
use super::{Conversation, Direct, Directory, Id, Intent, Room, RoomNickname, custody};
use custody::FieldKey;
use serde::{Deserialize, Serialize};

/// Retains each directory's requested nickname (at most 32 UTF-16 units) for
/// the callback's lifetime. Borrowing the mutable workspace would let an edit
/// silently retarget a live callback; assigned names remain registration output.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum InboxSelection {
	Directory {
		id: Id,
		access: FieldKey<custody::DirectoryAccess>,
		source: FieldKey<custody::SessionAccess>,
		inbox: FieldKey<custody::DirectoryInbox>,
		nick: crate::fields::Text<32>,
		allocation: crate::directory::registration::NicknameAllocation,
	},
	Room {
		id: Id,
		directory: Id,
		nickname: RoomNickname,
		access: Option<FieldKey<custody::RoomAccess>>,
		accepted: Option<FieldKey<custody::AcceptedAccess>>,
		public_entry: Option<super::PublicEntry>,
		publication: Option<crate::fields::Text<128, true>>,
		source: FieldKey<custody::SessionAccess>,
		inbox: FieldKey<custody::RoomInbox>,
	},
	Direct {
		id: Id,
		directory: Id,
		peer: Id,
		access: Option<FieldKey<custody::DirectAccess>>,
		introduction: Option<super::Introduction>,
		source: FieldKey<custody::SessionAccess>,
		inbox: FieldKey<custody::DirectInbox>,
	},
}
impl InboxSelection {
	pub fn direct(row: &Direct) -> Option<Self> {
		if row.closed {
			return None;
		}
		Some(Self::Direct {
			id: row.id.clone(),
			directory: row.directory.clone(),
			peer: row.peer.clone(),
			access: row.access,
			introduction: row.introduction.clone(),
			source: row.source?,
			inbox: row.inbox?,
		})
	}
	pub fn directory(row: &Directory) -> Option<Self> {
		Some(Self::Directory {
			id: row.id.clone(),
			access: row.access,
			source: row.source?,
			inbox: row.inbox?,
			nick: row.nick.clone(),
			allocation: row.nick_allocation,
		})
	}
	pub fn room(row: &Room, intent: &Intent) -> Option<Self> {
		if !row.requests_membership() || !row.has_entrance() {
			return None;
		}
		Some(Self::Room {
			id: row.id.clone(),
			directory: row.directory.clone(),
			nickname: RoomNickname::select(intent, &row.directory)?,
			access: row.access,
			accepted: row.accepted,
			public_entry: row.public_entry.clone(),
			publication: row.publication.clone(),
			source: row.source?,
			inbox: row.inbox?,
		})
	}
	pub fn source(&self) -> FieldKey<custody::SessionAccess> {
		match self {
			Self::Directory { source, .. } | Self::Room { source, .. } | Self::Direct { source, .. } => *source,
		}
	}
	pub fn coordinate(&self) -> custody::Coordinate {
		let (role, slot, generation) = match self {
			Self::Directory { inbox, .. } => (custody::Role::DirectoryInbox, inbox.slot(), inbox.generation()),
			Self::Room { inbox, .. } => (custody::Role::RoomInbox, inbox.slot(), inbox.generation()),
			Self::Direct { inbox, .. } => (custody::Role::DirectInbox, inbox.slot(), inbox.generation()),
		};
		custody::Coordinate {
			role,
			key: FieldKey::new(slot, generation),
		}
	}
	pub fn matches(&self, intent: &Intent) -> bool {
		match self {
			Self::Direct {
				id,
				directory,
				peer,
				access,
				introduction,
				source,
				inbox,
			} => {
				intent.conversations.as_slice().iter().any(|row| {
					matches!(row, Conversation::Direct(row) if row.id == *id && !row.closed
					&& row.directory == *directory && row.peer == *peer && (introduction.is_some() || row.access == *access)
					&& row.introduction == *introduction
					&& row.source == Some(*source) && row.inbox == Some(*inbox))
				}) && (access.is_some()
					|| introduction.as_ref().is_some_and(|witness| {
						intent.directories.as_slice().iter().any(|row| {
							row.id == *directory
								&& row.access == witness.access
								&& row.name == Some(witness.name)
								&& row.inbox == Some(witness.callback)
								&& row.source == Some(*source)
						})
					}))
			}
			Self::Directory {
				id,
				access,
				source,
				inbox,
				nick,
				allocation,
			} => intent.directories.as_slice().iter().any(|row| {
				row.id == *id
					&& row.access == *access
					&& row.source == Some(*source)
					&& row.inbox == Some(*inbox)
					&& row.nick == *nick
					&& row.nick_allocation == *allocation
			}),
			Self::Room {
				id,
				directory,
				nickname,
				access,
				accepted,
				public_entry,
				publication,
				source,
				inbox,
			} => intent.conversations.as_slice().iter().any(|row| {
				matches!(row, Conversation::Room(row) if row.id == *id && row.requests_membership() && row.directory == *directory
					&& (row.access == *access || (access.is_some() && row.access.is_none() && row.seat.is_some()))
					&& row.accepted == *accepted && row.public_entry == *public_entry && row.publication == *publication
					&& row.source == Some(*source) && row.inbox == Some(*inbox)
					&& nickname.matches(intent, directory))
			}),
		}
	}
}
