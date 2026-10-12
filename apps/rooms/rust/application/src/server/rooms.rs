//! The rooms a server hosts: who is in each, what they say, the files they
//! post, the topic, and the invitations, links, and stewardship that let
//! others in. Connections are the adapter's keys (`C`) and capabilities its
//! tokens (`R`). The policy performs no effect. Every verb answers with the
//! notices to tell, the capabilities to give back, the directory events to
//! announce, and the history to persist, so the same decisions run under any
//! host and a test reads them without a wire.
//!
//! Actors are the adapter's to mint and the policy's to name: a verb that
//! answers a capability takes the adapter's freshly spawned token for it, so
//! a refusal hands the token straight back and never leaves an orphan.
//!
//! File events take the host's current monotonic milliseconds, from the same
//! origin as `advance`. Timer delivery reclaims quiet uploads. Event time also
//! checks expiry and dates each new or renewed reservation when no timer fired.
mod entrance;
mod files;
mod lines;
mod membership;
mod notice;
mod presence;
mod receipts;
mod state;
pub(crate) use state::roster_count;
#[cfg(test)]
mod tests;
pub mod wire;

pub use super::{Refusal, Release};
pub use entrance::{Bootstrap, Entrance, Fresh, Gate, Open, Opening, Subscribed};
pub use notice::{Blob, Effects, Mutation, Notice, Tell};
pub use receipts::Delivery;
pub use state::{InvitationKey, LineKey, MembershipKey, RoomKey, UploadKey};

/// One live room as an inventory reads it.
pub struct LiveRoom<'a, C> {
	pub key: &'a RoomKey,
	pub entry_id: &'a str,
	pub name: &'a str,
	/// The name durable authority files the room under.
	pub durable_name: &'a str,
	pub listed: bool,
	pub members: Vec<LiveMember<'a, C>>,
	/// Line capabilities this room generation still answers edits on.
	pub lines: usize,
	/// Uploads in flight into this room.
	pub uploads: usize,
}

pub struct LiveMember<'a, C> {
	pub membership: MembershipKey,
	pub nick: &'a str,
	pub connection: C,
	/// Why the member has stepped away. Empty while they are here.
	pub away: &'a str,
}

use super::{history, links::Authority};
use crate::{
	directory::{RoomInfo, registration::Id},
	files::{FileLimits, FileStore},
	room::policy::{MembershipKind, RoomPolicy},
};
use alloc::{collections::BTreeMap, string::String, vec::Vec};
use state::{Invitation, Line, Room, Upload};

pub const MAX_ROOM_MEMBERS: usize = 256;
/// Disconnected names retained for display in one live room generation.
pub const MAX_ROOM_OFFLINE: usize = 256;
pub const MAX_ROSTER_SEEN: usize = MAX_ROOM_MEMBERS + MAX_ROOM_OFFLINE;
pub const MAX_ROOMS_PER_CREATOR: usize = 256;
pub const MAX_ROOM_INVITATIONS: usize = 64;
pub use crate::room::membership::MAX_AWAY;
pub const MAX_TOPIC: usize = super::document::MAX_TOPIC;
pub const MAX_ROOM: usize = super::document::MAX_ROOM;
/// The lines a room membership's `history` answers.
pub const HISTORY_ANSWERED: usize = 100;

/// A refusal that carries back the tokens the adapter minted for the verb.
#[derive(Debug, PartialEq, Eq)]
pub struct Refused<R> {
	pub refusal: Refusal,
	/// The adapter's own tokens, given back in the order they were handed in.
	pub returned: Vec<R>,
}

/// Every live room on one server.
pub struct Rooms<C, R> {
	rooms: BTreeMap<RoomKey, Room<C, R>>,
	/// Listed rooms by folded public name. A managed room listed under a
	/// public name stands here too, under its managed key.
	public: BTreeMap<String, RoomKey>,
	by_entry: BTreeMap<String, RoomKey>,
	per_owner: BTreeMap<C, usize>,
	/// Every line a room still answers edits on. Each room's own set names
	/// its share, oldest first.
	lines: BTreeMap<LineKey, Line>,
	/// The line behind each history row this process made, so a row leaving
	/// the index retires its line in one lookup.
	kept_lines: BTreeMap<history::Token, LineKey>,
	uploads: BTreeMap<UploadKey, Upload<C>>,
	invitations: BTreeMap<InvitationKey, Invitation<C>>,
	files: FileStore,
	history: Option<history::Index>,
	next: u64,
}

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	/// `history` is the retention policy the operator stated. `None` keeps
	/// nothing, and `history` on a membership is then not a method.
	pub fn new(history: Option<history::Index>, limits: FileLimits) -> Self {
		Self {
			rooms: BTreeMap::new(),
			public: BTreeMap::new(),
			by_entry: BTreeMap::new(),
			per_owner: BTreeMap::new(),
			lines: BTreeMap::new(),
			kept_lines: BTreeMap::new(),
			uploads: BTreeMap::new(),
			invitations: BTreeMap::new(),
			files: FileStore::new(limits),
			history,
			next: 0,
		}
	}
	pub fn keeps_history(&self) -> bool {
		self.history.is_some()
	}
	pub fn history_mut(&mut self) -> Option<&mut history::Index> {
		self.history.as_mut()
	}
	pub fn files(&self) -> &FileStore {
		&self.files
	}
	pub fn files_mut(&mut self) -> &mut FileStore {
		&mut self.files
	}
	fn next_id(&mut self) -> u64 {
		self.next += 1;
		self.next
	}
	/// The live rooms a directory lists: listed, occupied, with what its
	/// public name offers.
	pub fn listed(&self) -> impl Iterator<Item = RoomInfo> + '_ {
		self.rooms
			.values()
			.filter(|room| room.policy.is_listed() && !room.members.is_empty())
			.map(Room::info)
	}
	/// Every live room, listed or not, for the inventories an operator reads.
	pub fn live(&self) -> impl Iterator<Item = LiveRoom<'_, C>> + '_ {
		self.rooms.values().map(|room| LiveRoom {
			key: &room.key,
			entry_id: room.entry_id.as_str(),
			name: &room.name,
			durable_name: room.durable_name(),
			listed: room.policy.is_listed(),
			members: room
				.members
				.iter()
				.map(|member| LiveMember {
					membership: member.key,
					nick: &member.nick,
					connection: member.connection,
					away: &member.away,
				})
				.collect(),
			lines: room.lines.len(),
			uploads: self.uploads.values().filter(|upload| upload.room == room.key).count(),
		})
	}
	/// A public room's live entry by its publication id.
	pub fn public_entry(&self, entry_id: &str) -> Option<&RoomKey> {
		self.by_entry.get(entry_id)
	}
	/// Any live room by the exact id of its generation, listed or not.
	pub fn room_by_entry(&self, entry_id: &str) -> Option<&RoomKey> {
		self.rooms
			.values()
			.find(|room| room.entry_id.as_str() == entry_id)
			.map(|room| &room.key)
	}
	/// An operator ends one exact membership: the member hears why, and the
	/// leave follows.
	pub fn end_membership(&mut self, key: &RoomKey, membership: MembershipKey, why: &str) -> Effects<C, R> {
		let mut effects = Effects::default();
		let Some((connection, inbox)) = self
			.rooms
			.get(key)
			.and_then(|room| room.member(membership))
			.map(|member| (member.connection, member.inbox.clone()))
		else {
			return effects;
		};
		effects.tell(connection, inbox, Notice::Ended(why.into()));
		effects.extend(self.leave_member(key, membership, None, entrance::Departure::Ended));
		effects
	}
	/// An operator removes one exact room generation: every member hears
	/// why, the room goes, and a listed one is announced closed.
	pub fn retire_room(&mut self, key: &RoomKey, why: &str) -> Effects<C, R> {
		let mut effects = Effects::default();
		let Some(room) = self.rooms.get(key) else {
			return effects;
		};
		let listed = room.policy.is_listed();
		let entry = room.info();
		for member in &room.members {
			effects.tell(member.connection, member.inbox.clone(), Notice::Ended(why.into()));
		}
		effects.extend(self.forget_room(key));
		if listed {
			effects.events.push(crate::directory::Event::Room {
				kind: crate::directory::RoomChange::Closed,
				entry,
			});
		}
		effects
	}
	pub fn room_name(&self, key: &RoomKey) -> Option<&str> {
		self.rooms.get(key).map(|room| room.name.as_str())
	}
	pub fn member_count(&self, key: &RoomKey) -> usize {
		self.rooms.get(key).map_or(0, |room| room.members.len())
	}
	/// The nick `connection` is in `key` under.
	pub fn nick_of(&self, key: &RoomKey, connection: C) -> Option<&str> {
		self.rooms
			.get(key)
			.and_then(|room| room.member_of(connection))
			.map(|member| member.nick.as_str())
	}
	/// The live listed room under a public name.
	pub fn public_key_of(&self, name: &str) -> Option<RoomKey> {
		self.public.get(&state::folded(name)).cloned()
	}
	/// Whether a public name is taken by a live listed room.
	pub fn public_name_taken(&self, name: &str) -> bool {
		self.public.contains_key(&state::folded(name))
	}
	/// A fresh registration id for a public-room generation, drawn by the
	/// adapter. The policy checks it names nothing live.
	pub fn entry_id_known(&self, id: &Id) -> bool {
		self.by_entry.contains_key(id.as_str())
	}
	/// The exact live incarnation used for reconnect admission. A room name
	/// may be reused. Accounting must not mistake it for this generation.
	pub fn generation(&self, key: &RoomKey) -> Option<&str> {
		self.rooms.get(key).map(|room| room.entry_id.as_str())
	}
	pub(super) fn authority_kind_name(kind: crate::room::stewardship::Kind) -> &'static str {
		match kind {
			crate::room::stewardship::Kind::Room => "room",
			crate::room::stewardship::Kind::Steward => "steward",
			crate::room::stewardship::Kind::Manager => "manager",
		}
	}
	/// The policy a room stands under, live or from its managed row.
	pub fn policy_of(&self, key: &RoomKey, authority: &Authority) -> Option<RoomPolicy> {
		if let Some(room) = self.rooms.get(key) {
			return Some(room.policy);
		}
		authority.managed_room(key.as_str()).map(|managed| managed.policy)
	}
	pub(super) fn public_kind(policy: RoomPolicy) -> MembershipKind {
		policy.public_membership().unwrap_or(MembershipKind::Observer)
	}
}
