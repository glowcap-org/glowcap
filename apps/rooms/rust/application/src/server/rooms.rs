//! The rooms a server hosts: who is in each, what they say, the files they
//! post, the topic, and the invitations, links, and stewardship that let
//! others in. Connections are the adapter's keys (`C`) and capabilities its
//! tokens (`R`); the policy performs no effect. Every verb answers with the
//! notices to tell, the capabilities to give back, the directory events to
//! announce, and the history to persist, so the same decisions run under any
//! host and a test reads them without a wire.
//!
//! Actors are the adapter's to mint and the policy's to name: a verb that
//! answers a capability takes the adapter's freshly spawned token for it, so
//! a refusal hands the token straight back and never leaves an orphan.
//!
//! File events take the host's current monotonic milliseconds, from the same
//! origin as `advance`. Timer delivery reclaims quiet uploads; event time also
//! checks expiry and dates each new or renewed reservation when no timer fired.
mod entrance;
mod files;
mod lines;
mod membership;
mod notice;
mod presence;
mod state;
#[cfg(test)]
mod tests;
pub mod wire;

pub use entrance::{Bootstrap, Entrance, Fresh, Gate, Open, Opening, Subscribed};
pub use notice::{Blob, Effects, Mutation, Notice, Release, Tell};
pub use state::{public_key, InvitationKey, LineKey, MembershipKey, RoomKey, UploadKey};

/// One live room as an inventory reads it.
pub struct LiveRoom<'a, C> {
	pub key: &'a RoomKey,
	pub entry_id: &'a str,
	pub name: &'a str,
	/// The name durable authority files the room under.
	pub durable_name: &'a str,
	pub listed: bool,
	pub members: Vec<LiveMember<C>>,
	/// Line capabilities this room generation still answers edits on.
	pub lines: usize,
	/// Uploads in flight into this room.
	pub uploads: usize,
}

pub struct LiveMember<C> {
	pub membership: MembershipKey,
	pub nick: String,
	pub connection: C,
	/// Why the member has stepped away; empty while they are here.
	pub away: String,
}

use super::{history, links::Authority};
use crate::{
	directory::{registration::Id, RoomInfo},
	failure::FailureCode,
	files::{FileLimits, FileStore},
	room::policy::{MembershipKind, RoomPolicy},
};
use alloc::{collections::BTreeMap, format, string::String, vec::Vec};
use state::{Invitation, Line, Room, Upload};

pub const MAX_ROOM_MEMBERS: usize = 256;
pub const MAX_ROOMS_PER_CREATOR: usize = 256;
pub const MAX_ROOM_INVITATIONS: usize = 64;
pub use crate::room::membership::MAX_AWAY;
pub const MAX_TOPIC: usize = super::document::MAX_TOPIC;
pub const MAX_ROOM: usize = super::document::MAX_ROOM;
/// The lines a room membership's `history` answers.
pub const HISTORY_ANSWERED: usize = 100;

/// A refusal the caller hears as a break: a Rooms failure code and its
/// detail when a client acts on it, or the detail alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
	pub code: Option<FailureCode>,
	pub detail: String,
}
impl Refusal {
	pub(super) fn coded(code: FailureCode, detail: impl Into<String>) -> Self {
		Self {
			code: Some(code),
			detail: detail.into(),
		}
	}
	pub(super) fn plain(detail: impl Into<String>) -> Self {
		Self {
			code: None,
			detail: detail.into(),
		}
	}
	pub fn reason(&self) -> String {
		match self.code {
			Some(code) => format!("{}: {}", code.wire(), self.detail),
			None => self.detail.clone(),
		}
	}
}
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(&self.reason())
	}
}
/// The break reason a caller hears.
impl From<Refusal> for String {
	fn from(refusal: Refusal) -> Self {
		refusal.reason()
	}
}
impl From<super::links::Refusal> for Refusal {
	fn from(refusal: super::links::Refusal) -> Self {
		Self {
			code: refusal.code,
			detail: refusal.detail,
		}
	}
}

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
	/// Listed rooms by public key, and reservations a policy change holds.
	public: BTreeMap<String, RoomKey>,
	reserved: BTreeMap<String, u64>,
	by_entry: BTreeMap<String, RoomKey>,
	per_owner: BTreeMap<C, usize>,
	lines: BTreeMap<LineKey, Line>,
	uploads: BTreeMap<UploadKey, Upload<C>>,
	invitations: BTreeMap<InvitationKey, Invitation<C>>,
	files: FileStore,
	history: Option<history::Index>,
	next: u64,
}

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	/// `history` is the retention policy the operator stated; `None` keeps
	/// nothing, and `history` on a membership is then not a method.
	pub fn new(history: Option<history::Index>, limits: FileLimits) -> Self {
		Self {
			rooms: BTreeMap::new(),
			public: BTreeMap::new(),
			reserved: BTreeMap::new(),
			by_entry: BTreeMap::new(),
			per_owner: BTreeMap::new(),
			lines: BTreeMap::new(),
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
					nick: member.nick.clone(),
					connection: member.connection,
					away: member.away.clone(),
				})
				.collect(),
			lines: self.lines.values().filter(|line| line.room == room.key).count(),
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
		self.public.get(&state::public_key(name)).cloned()
	}
	/// Whether a public name is taken by a live listed room or a reservation.
	pub fn public_name_taken(&self, name: &str) -> bool {
		let key = state::public_key(name);
		self.public.contains_key(&key) || self.reserved.contains_key(&key)
	}
	/// A fresh registration id for a public-room generation, drawn by the
	/// adapter; the policy checks it names nothing live.
	pub fn entry_id_known(&self, id: &Id) -> bool {
		self.by_entry.contains_key(id.as_str())
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
		authority.managed_room(key).map(|managed| managed.policy)
	}
	pub(super) fn public_kind(policy: RoomPolicy) -> MembershipKind {
		policy.public_membership().unwrap_or(MembershipKind::Observer)
	}
}
