//! The directory and room rows of the intent: what a session asked to hold
//! in each directory and each room, and the custody coordinates it holds
//! there. A row's methods answer what its coordinates mean for membership.
use super::{Field, Id, Reconnect, RoomKind, Standing, custody, custody::FieldKey};
use crate::{
	directory::registration::NicknameAllocation,
	fields::{List, Text},
};
use serde::{Deserialize, Serialize};

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
	pub subject: Option<FieldKey<custody::RoomSubject>>,
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

impl Directory {
	/// A requested nickname held through an initiating source is registered by
	/// this session's directory membership.
	pub fn registers(&self) -> bool {
		self.source.is_some() && self.nick.text().as_str().is_some_and(|nick| !nick.is_empty())
	}
}
impl Room {
	/// Keep an independently held seat. Otherwise join only by explicit intent.
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
	/// Whether a membership realized through the entrance `access`,
	/// `accepted`, `public_entry` still stands in this row. A held seat
	/// outlives two entrance changes: the link it came in by dropped, and a
	/// link taken while standing in the room by name or invitation, which
	/// becomes the way back in on the next connection. A link replaced by
	/// another link does not stand: the membership is realized again through
	/// the new link, which fences the replaced link's callback.
	pub fn stands_through(
		&self,
		access: Option<FieldKey<custody::RoomAccess>>,
		accepted: Option<FieldKey<custody::AcceptedAccess>>,
		public_entry: Option<&PublicEntry>,
	) -> bool {
		let same_entrance = self.accepted == accepted && self.public_entry.as_ref() == public_entry;
		if same_entrance && self.access == access {
			return true;
		}
		let link_dropped = same_entrance && access.is_some() && self.access.is_none();
		let link_taken =
			access.is_none() && self.access.is_some() && self.accepted.is_none() && self.public_entry.is_none();
		self.seat.is_some() && (link_dropped || link_taken)
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

#[cfg(test)]
mod tests {
	use super::*;
	use core::num::NonZeroU64;

	fn key<T>(slot: u64) -> FieldKey<T> {
		FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::MIN)
	}
	fn room(access: Option<FieldKey<custody::RoomAccess>>, seat: Option<FieldKey<custody::RoomSeat>>) -> Room {
		serde_json::from_value(serde_json::json!({
			"kind": "room", "id": "c", "directory": "d", "name": "n", "access": access, "seat": seat,
			"reconnect": "requested", "standing": null, "draft": "",
		}))
		.unwrap()
	}

	#[test]
	fn a_held_seat_stands_through_a_taken_link_and_not_a_replaced_one() {
		let seated = room(Some(key(2)), Some(key(3)));
		assert!(seated.stands_through(Some(key(2)), None, None), "the same entrance");
		assert!(
			seated.stands_through(None, None, None),
			"a link taken while standing by name"
		);
		assert!(
			room(None, Some(key(3))).stands_through(Some(key(2)), None, None),
			"the link it came in by dropped"
		);
		assert!(
			!seated.stands_through(Some(key(1)), None, None),
			"a replaced link is realized again"
		);
		assert!(
			!room(Some(key(2)), None).stands_through(None, None, None),
			"no seat, no membership to keep"
		);
	}
}
