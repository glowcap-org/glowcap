//! Rooms another directory publishes here. A peering holder hands this
//! server a room capability under a name; once the room resolves, the
//! directory lists it beside its own and hands the same capability to
//! whoever enters. Nothing here persists: a publication lives exactly as
//! long as the session that made it, or until its lease revokes it.
use crate::{
	directory::{registration::Id, Event, OriginProof, PublicationKind, RoomChange, RoomInfo},
	failure::FailureCode,
	fields::{Nullable, Text},
	room::policy::MembershipKind,
};
use alloc::{collections::BTreeMap, format, string::String, vec::Vec};

/// Foreign rooms one directory lists at once.
pub const MAX_PEERED_ROOMS: usize = 4096;
/// Foreign rooms one publishing session may hold.
pub const MAX_PEERED_ROOMS_PER_SOURCE: usize = 256;
pub const MAX_ROOM: usize = super::document::MAX_ROOM;
/// How long a handed room may take to resolve.
pub const READY_TIMEOUT_MS: u64 = 15_000;

/// A refusal the publisher hears as a break.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
	pub code: Option<FailureCode>,
	pub detail: String,
}
impl Refusal {
	pub fn reason(&self) -> String {
		match self.code {
			Some(code) => format!("{}: {}", code.wire(), self.detail),
			None => self.detail.clone(),
		}
	}
}
impl From<Refusal> for String {
	fn from(refusal: Refusal) -> Self {
		refusal.reason()
	}
}

/// Who published a room and how well the directory knows them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Source {
	pub origin: String,
	pub proof: OriginProof,
}

/// One publication: reserved, then live once its room resolved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry<C, R> {
	pub id: String,
	pub name: String,
	pub key: String,
	pub connection: C,
	pub source: Source,
	/// The room, once it resolved.
	pub room: Option<R>,
}

impl<C, R> Entry<C, R> {
	pub fn is_live(&self) -> bool {
		self.room.is_some()
	}
	/// The record the directory lists a live publication as. Occupancy is
	/// never invented for a room somebody else hosts.
	pub fn info(&self) -> RoomInfo {
		RoomInfo {
			id: Text(self.id.as_str().into()),
			name: Text(self.name.as_str().into()),
			kind: PublicationKind::Foreign,
			count: Nullable::Null,
			origin: Text(self.source.origin.as_str().into()),
			proof: self.source.proof,
			offers: Nullable::Value(MembershipKind::Participant),
		}
	}
}

fn key(name: &str) -> String {
	super::rooms::public_key(name)
}

/// The foreign rooms, reserved and live, by key.
pub struct Foreign<C, R> {
	entries: BTreeMap<String, Entry<C, R>>,
	by_id: BTreeMap<String, String>,
}

impl<C, R> Default for Foreign<C, R> {
	fn default() -> Self {
		Self {
			entries: BTreeMap::new(),
			by_id: BTreeMap::new(),
		}
	}
}

impl<C: Copy + PartialEq, R: Clone> Foreign<C, R> {
	/// Reserve `name` for `connection`'s publication. `taken` says whether a
	/// local room holds the name.
	pub fn reserve(
		&mut self,
		connection: C,
		name: &str,
		source: Source,
		id: Id,
		taken: impl Fn(&str) -> bool,
	) -> Result<&Entry<C, R>, Refusal> {
		let key = key(name);
		if self.entries.contains_key(&key) || taken(name) {
			return Err(Refusal {
				code: Some(FailureCode::RoomExists),
				detail: format!("room \"{name}\" already exists"),
			});
		}
		if self.entries.len() >= MAX_PEERED_ROOMS {
			return Err(Refusal {
				code: Some(FailureCode::TooManyPeeredRooms),
				detail: format!("this directory lists at most {MAX_PEERED_ROOMS} peered rooms"),
			});
		}
		let held = self
			.entries
			.values()
			.filter(|entry| entry.connection == connection)
			.count();
		if held >= MAX_PEERED_ROOMS_PER_SOURCE {
			return Err(Refusal {
				code: Some(FailureCode::TooManyPeeredRooms),
				detail: format!("one source publishes at most {MAX_PEERED_ROOMS_PER_SOURCE} peered rooms"),
			});
		}
		self.by_id.insert(id.as_str().into(), key.clone());
		self.entries.insert(
			key.clone(),
			Entry {
				id: id.as_str().into(),
				name: name.into(),
				key: key.clone(),
				connection,
				source,
				room: None,
			},
		);
		Ok(&self.entries[&key])
	}
	/// The room resolved: the publication is live. Answers the event to
	/// announce, or nothing when the reservation is gone.
	pub fn commit(&mut self, id: &str, room: R) -> Option<Event> {
		let key = self.by_id.get(id)?;
		let entry = self.entries.get_mut(key)?;
		entry.room = Some(room);
		Some(Event::Room {
			kind: RoomChange::Opened,
			entry: entry.info(),
		})
	}
	/// Take one publication out, live or not. A live one answers the event
	/// to announce beside the capability to let go.
	pub fn forget(&mut self, id: &str) -> Option<(Entry<C, R>, Option<Event>)> {
		let key = self.by_id.remove(id)?;
		let entry = self.entries.remove(&key)?;
		let event = entry.room.is_some().then(|| Event::Room {
			kind: RoomChange::Closed,
			entry: entry.info(),
		});
		Some((entry, event))
	}
	/// Every publication from `connection`, taken out.
	pub fn forget_from(&mut self, connection: C) -> Vec<(Entry<C, R>, Option<Event>)> {
		let ids: Vec<String> = self
			.entries
			.values()
			.filter(|entry| entry.connection == connection)
			.map(|entry| entry.id.clone())
			.collect();
		ids.iter().filter_map(|id| self.forget(id)).collect()
	}
	pub fn listed(&self) -> impl Iterator<Item = RoomInfo> + '_ {
		self.entries.values().filter(|entry| entry.is_live()).map(Entry::info)
	}
	pub fn entries(&self) -> impl Iterator<Item = &Entry<C, R>> {
		self.entries.values()
	}
	pub fn by_name(&self, name: &str) -> Option<&Entry<C, R>> {
		self.entries.get(&key(name)).filter(|entry| entry.is_live())
	}
	pub fn by_id(&self, id: &str) -> Option<&Entry<C, R>> {
		self.by_id.get(id).and_then(|key| self.entries.get(key))
	}
	pub fn holds_name(&self, name: &str) -> bool {
		self.entries.contains_key(&key(name))
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn source() -> Source {
		Source {
			origin: "abc".into(),
			proof: OriginProof::Session,
		}
	}

	#[test]
	fn a_publication_is_reserved_listed_once_live_and_bounded_per_source() {
		let mut foreign: Foreign<u8, &str> = Foreign::default();
		let id = Id::from_entropy([1; 16]);
		let reserved = foreign.reserve(1, "Garden", source(), id.clone(), |_| false).unwrap();
		assert_eq!(reserved.key, "#garden");
		assert!(foreign.listed().next().is_none(), "not listed before it resolves");
		let taken = foreign
			.reserve(2, "garden", source(), Id::from_entropy([2; 16]), |_| false)
			.unwrap_err();
		assert_eq!(taken.code, Some(FailureCode::RoomExists));
		let local = foreign
			.reserve(2, "lobby", source(), Id::from_entropy([3; 16]), |name| name == "lobby")
			.unwrap_err();
		assert_eq!(local.code, Some(FailureCode::RoomExists));
		let opened = foreign.commit(id.as_str(), "room").unwrap();
		assert!(matches!(
			opened,
			Event::Room {
				kind: RoomChange::Opened,
				..
			}
		));
		let listed: Vec<RoomInfo> = foreign.listed().collect();
		assert_eq!(listed.len(), 1);
		assert_eq!(listed[0].kind, PublicationKind::Foreign);
		assert_eq!(listed[0].count, Nullable::Null);
		assert_eq!(foreign.by_name("GARDEN").unwrap().room, Some("room"));
		let (_, closed) = foreign.forget(id.as_str()).unwrap();
		assert!(closed.is_some());
		assert!(foreign.by_name("garden").is_none());
		for n in 0..MAX_PEERED_ROOMS_PER_SOURCE {
			let mut entropy = [9u8; 16];
			entropy[0] = n as u8;
			entropy[1] = (n >> 8) as u8;
			foreign
				.reserve(7, &format!("r{n}"), source(), Id::from_entropy(entropy), |_| false)
				.unwrap();
		}
		let over = foreign
			.reserve(7, "one-more", source(), Id::from_entropy([8; 16]), |_| false)
			.unwrap_err();
		assert_eq!(over.code, Some(FailureCode::TooManyPeeredRooms));
		assert_eq!(foreign.forget_from(7).len(), MAX_PEERED_ROOMS_PER_SOURCE);
	}
}
