//! Bounded discovery retained by one session directory owner. Insertion order
//! is presentation order; lookup scans at most 128 admitted rows.
use super::fields::Id;
use crate::{
	directory::{Event, Member, MemberChange, RoomChange, RoomInfo, Snapshot},
	text::DocumentText,
};
use alloc::vec::Vec;
use serde::{ser::SerializeSeq, Serialize, Serializer};

pub const MAX_ROWS: usize = 128;

pub struct DirectoryView {
	id: Id,
	rooms: Vec<RoomInfo>,
	peers: Vec<Peer>,
	truncated: bool,
}
struct Peer {
	key: DocumentText,
	member: Member,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Change {
	pub view: bool,
	pub publications: bool,
}
impl DirectoryView {
	/// Move the initial watch rows into this owner before applying queued
	/// notifications. Omitted rows remain visible as a sticky truncation flag.
	pub fn new(id: Id, snapshot: Snapshot) -> Self {
		let mut view = Self {
			id,
			rooms: Vec::new(),
			peers: Vec::new(),
			truncated: snapshot.omitted != 0,
		};
		for room in snapshot.rooms {
			view.set_room(room);
		}
		for peer in snapshot.peers {
			view.set_peer(peer, MemberChange::Registered);
		}
		view
	}
	pub fn id(&self) -> &Id {
		&self.id
	}
	pub fn room(&self, id: &DocumentText) -> Option<&RoomInfo> {
		self.rooms.iter().find(|r| r.id.text() == id)
	}
	pub fn room_named(&self, name: &DocumentText) -> Option<&RoomInfo> {
		let key = name.lowercase();
		self.rooms.iter().find(|r| r.name.text().lowercase() == key)
	}
	pub fn peer(&self, name: &DocumentText) -> Option<&Member> {
		let key = name.lowercase();
		self.peers.iter().find(|p| p.key == key).map(|p| &p.member)
	}
	pub fn apply(&mut self, event: Event) -> Change {
		let (view, publications) = match event {
			Event::Truncated(_) => (self.mark_truncated(), false),
			Event::Member { kind, peer, .. } => (self.set_peer(peer, kind), false),
			Event::Room { kind, entry } => {
				let changed = if matches!(kind, RoomChange::Closed) {
					if let Some(index) = self.rooms.iter().position(|r| r.id == entry.id) {
						self.rooms.remove(index);
						true
					} else {
						false
					}
				} else {
					self.set_room(entry)
				};
				(
					changed,
					changed && matches!(kind, RoomChange::Opened | RoomChange::Closed),
				)
			}
		};
		Change { view, publications }
	}
	fn set_room(&mut self, room: RoomInfo) -> bool {
		if let Some(prior) = self.rooms.iter_mut().find(|r| r.id == room.id) {
			let changed = *prior != room;
			*prior = room;
			changed
		} else if self.rooms.len() == MAX_ROWS {
			self.mark_truncated()
		} else {
			self.rooms.push(room);
			true
		}
	}
	fn set_peer(&mut self, member: Member, kind: MemberChange) -> bool {
		let key = member.name.text().lowercase();
		let index = self.peers.iter().position(|p| p.key == key);
		match (kind, index) {
			(MemberChange::Unregistered, Some(index))
				if self.peers[index].member.registration_id == member.registration_id =>
			{
				self.peers.remove(index);
				true
			}
			(MemberChange::Unregistered, _) => false,
			(MemberChange::Registered, Some(index)) => {
				if self.peers[index].member.registration_id == member.registration_id {
					return false;
				}
				// Replacing a registration spends no additional row, even at capacity.
				self.peers[index].member = member;
				true
			}
			(MemberChange::Registered, None) if self.peers.len() == MAX_ROWS => self.mark_truncated(),
			(MemberChange::Registered, None) => {
				self.peers.push(Peer { key, member });
				true
			}
		}
	}
	fn mark_truncated(&mut self) -> bool {
		!core::mem::replace(&mut self.truncated, true)
	}
	/// Borrow metadata directly, with rooms first within the combined row
	/// budget. A caller may tighten but cannot enlarge the producer's limit.
	pub fn snapshot(&self, limit: usize) -> View<'_> {
		let limit = limit.min(MAX_ROWS);
		let rooms = &self.rooms[..self.rooms.len().min(limit)];
		let peers = &self.peers[..self.peers.len().min(limit - rooms.len())];
		View {
			directory_id: &self.id,
			rooms,
			peers: Peers(peers),
			truncated: self.truncated || rooms.len() < self.rooms.len() || peers.len() < self.peers.len(),
		}
	}
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View<'a> {
	pub directory_id: &'a Id,
	pub rooms: &'a [RoomInfo],
	peers: Peers<'a>,
	pub truncated: bool,
}
impl View<'_> {
	pub fn peers(&self) -> impl ExactSizeIterator<Item = &Member> {
		self.peers.0.iter().map(|p| &p.member)
	}
}
struct Peers<'a>(&'a [Peer]);
impl Serialize for Peers<'_> {
	fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
		let mut sequence = serializer.serialize_seq(Some(self.0.len()))?;
		for peer in self.0 {
			sequence.serialize_element(&peer.member)?;
		}
		sequence.end()
	}
}
