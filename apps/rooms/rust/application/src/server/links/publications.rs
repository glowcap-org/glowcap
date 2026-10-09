//! Named public lookup follows durable room identity, independently of occupancy.
use super::Authority;
use crate::{
	directory::{OriginProof, PublicationKind, RoomInfo, creation::RecoveryKey, registration::Id},
	fields::{Nullable, SafeInteger, Text},
	room::policy::RoomPolicy,
};
use alloc::{format, string::String};

pub struct PublicRoom<'a> {
	pub id: &'a str,
	pub name: &'a str,
	pub generation: u64,
	pub policy: RoomPolicy,
	pub managed: bool,
}

impl Authority {
	fn public_room(&self, key: &str) -> Option<PublicRoom<'_>> {
		if let Some(room) = self.managed.get(key) {
			return room.policy.public_membership().map(|_| PublicRoom {
				id: &room.id,
				name: &room.name,
				generation: room.generation,
				policy: room.policy,
				managed: true,
			});
		}
		let name = self.linked.get(key)?;
		if RecoveryKey::accepts(name) {
			return None;
		}
		Some(PublicRoom {
			id: name,
			name,
			generation: self.room_link_generation(name),
			policy: RoomPolicy::Open,
			managed: false,
		})
	}
	/// A public witness is domain-separated from every bearer and control name.
	/// Its generation follows the persisted policy; no live room or secret grant
	/// is retained. The bounded public index is rebuilt from that same authority.
	fn publication_id(&self, room: &PublicRoom<'_>) -> String {
		Id::from_entropy(self.entropy_for(&format!(
			"public-room\0{}\0{}\0{}",
			room.managed,
			room.generation,
			super::fold(room.id)
		)))
		.as_str()
		.into()
	}
	/// Derived scalar index, bounded by MAX_ROOM_LINKS. Rebuilt only when
	/// restoring or admitting durable authority; it retains no live room state.
	pub(super) fn reindex_publications(&mut self) {
		self.publications = self
			.linked
			.keys()
			.filter(|key| !self.managed.contains_key(*key))
			.chain(self.managed.keys())
			.filter_map(|key| {
				self.public_room(key)
					.map(|room| (self.publication_id(&room), key.clone()))
			})
			.collect();
	}
	pub fn publication_room(&self, publication: &str) -> Option<PublicRoom<'_>> {
		self.publications.get(publication).and_then(|id| self.public_room(id))
	}
	/// Only listed policy is public; private names cannot be discovered here.
	pub fn named_publication(&self, name: &str) -> Option<RoomInfo> {
		let key = super::fold(self.managed_room_id_for_name(name).unwrap_or(name));
		let room = self.public_room(&key)?;
		Some(RoomInfo {
			id: Text(self.publication_id(&room).into()),
			name: Text(String::from(room.name).into()),
			kind: PublicationKind::Local,
			count: Nullable::Value(SafeInteger::new(0).expect("zero")),
			origin: Text(String::new().into()),
			proof: OriginProof::Local,
			offers: room.policy.public_membership().map_or(Nullable::Null, Nullable::Value),
		})
	}
}
