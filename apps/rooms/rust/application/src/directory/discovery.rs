//! Directory discovery projects bounded room and member snapshots.
use super::*;
use crate::{
	fields::{Nullable, SafeInteger, Text},
	room::policy::MembershipKind,
};
use alloc::{collections::BTreeSet, vec::Vec};

fn text<A: Argument, const N: usize, const NONEMPTY: bool>(value: A) -> Option<Text<N, NONEMPTY>> {
	let value = value.text()?;
	Text::<N, NONEMPTY>::accepts_utf16(value.encode_utf16()).then(|| Text(value.into()))
}
fn natural(value: &impl crate::room::ArgumentView) -> Option<SafeInteger> {
	if let Some(integer) = value.integer() {
		return SafeInteger::new(u64::try_from(integer).ok()?);
	}
	let number = value.float()?;
	SafeInteger::new(number as u64).filter(|_| number >= 0.0 && number == (number as u64) as f64)
}
fn room<A: Argument>(length: usize, at: impl Fn(usize) -> Option<A>) -> Option<RoomInfo> {
	if length != 2 && length != 7 {
		return None;
	}
	let name: Text<32, true> = text(at(0)?)?;
	let raw_count = at(1)?;
	let count = if raw_count.is_null() {
		Nullable::Null
	} else {
		Nullable::Value(natural(&raw_count)?)
	};
	let entry = if length == 2 {
		RoomInfo {
			id: Text(name.text().clone()),
			name,
			count,
			kind: PublicationKind::Local,
			origin: Text("".into()),
			proof: OriginProof::Local,
			offers: Nullable::Value(MembershipKind::Participant),
		}
	} else {
		let kind = match at(3)?.text()? {
			"local" => PublicationKind::Local,
			"foreign" => PublicationKind::Foreign,
			"bridge" => PublicationKind::Bridge,
			_ => return None,
		};
		let proof = match at(5)?.text()? {
			"local" => OriginProof::Local,
			"authenticated" => OriginProof::Authenticated,
			"session" => OriginProof::Session,
			"bridge" => OriginProof::Bridge,
			_ => return None,
		};
		let raw_offers = at(6)?;
		let offers = if raw_offers.is_null() {
			Nullable::Null
		} else {
			Nullable::Value(MembershipKind::parse(raw_offers.text()?)?)
		};
		RoomInfo {
			name,
			count,
			id: text(at(2)?)?,
			kind,
			origin: text(at(4)?)?,
			proof,
			offers,
		}
	};
	entry.valid().then_some(entry)
}
pub fn rooms<A: Argument>(raw: &A) -> Result<Vec<RoomInfo>, Error> {
	let length = raw.list_len().filter(|n| *n <= MAX_ROWS).ok_or(Error::List)?;
	let mut result = Vec::with_capacity(length);
	let mut ids = BTreeSet::new();
	for i in 0..length {
		let row = raw.at(i).ok_or(Error::Row)?;
		let entry = room(row.list_len().ok_or(Error::Row)?, |i| row.at(i)).ok_or(Error::Row)?;
		if !ids.insert(entry.id.text().clone()) {
			return Err(Error::Row);
		}
		result.push(entry);
	}
	Ok(result)
}
#[derive(Debug, serde::Serialize)]
pub struct Snapshot {
	pub rooms: Vec<RoomInfo>,
	pub peers: Vec<Member>,
	pub omitted: u64,
}
pub fn snapshot<A: Argument>(raw: &A) -> Result<Snapshot, Error> {
	if raw.list_len() != Some(3) {
		return Err(Error::Snapshot);
	}
	let room_rows = raw.at(0).ok_or(Error::Snapshot)?;
	let peer_rows = raw.at(1).ok_or(Error::Snapshot)?;
	let nr = room_rows.list_len().filter(|n| *n <= MAX_ROWS).ok_or(Error::Snapshot)?;
	let np = peer_rows
		.list_len()
		.filter(|n| *n <= MAX_ROWS - nr)
		.ok_or(Error::Snapshot)?;
	let omitted = natural(&raw.at(2).ok_or(Error::Snapshot)?)
		.ok_or(Error::Snapshot)?
		.get();
	let rooms = rooms(&room_rows)?;
	let mut peers = Vec::with_capacity(np);
	let (mut names, mut ids) = (BTreeSet::new(), BTreeSet::new());
	for i in 0..np {
		let row = peer_rows.at(i).ok_or(Error::Snapshot)?;
		if row.list_len() != Some(2) {
			return Err(Error::Snapshot);
		}
		let name: Text<32, true> = text(row.at(0).ok_or(Error::Snapshot)?).ok_or(Error::Snapshot)?;
		let id: Text<36, true> = text(row.at(1).ok_or(Error::Snapshot)?).ok_or(Error::Snapshot)?;
		if !registration_id(id.text()) || !names.insert(name.text().lowercase()) || !ids.insert(id.text().clone()) {
			return Err(Error::Snapshot);
		}
		peers.push(Member {
			name,
			registration_id: id.0,
		});
	}
	Ok(Snapshot { rooms, peers, omitted })
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RoomChange {
	Opened,
	Closed,
	Count,
}
impl RoomChange {
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Opened => crate::protocol_data::OPENED,
			Self::Closed => crate::protocol_data::CLOSED,
			Self::Count => crate::protocol_data::COUNT,
		}
	}
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MemberChange {
	Registered,
	Unregistered,
}
impl MemberChange {
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Registered => crate::protocol_data::REGISTERED,
			Self::Unregistered => crate::protocol_data::UNREGISTERED,
		}
	}
}
#[derive(Debug, PartialEq, Eq)]
pub enum Event {
	Room {
		kind: RoomChange,
		entry: RoomInfo,
	},
	Member {
		kind: MemberChange,
		peer: Member,
		count: u64,
	},
	Truncated(u64),
}
pub fn event<A: Argument>(args: &A) -> Option<Event> {
	event_fields(args.list_len()?, |i| args.at(i))
}
pub fn event_fields<A: Argument>(len: usize, at: impl Fn(usize) -> Option<A>) -> Option<Event> {
	let kind = at(0)?;
	match kind.text()? {
		crate::protocol_data::TRUNCATED if len == 2 => Some(Event::Truncated(natural(&at(1)?)?.get())),
		crate::protocol_data::REGISTERED | crate::protocol_data::UNREGISTERED if len == 4 => {
			let name = text(at(1)?)?;
			let id: Text<36, true> = text(at(3)?)?;
			if !registration_id(id.text()) {
				return None;
			}
			Some(Event::Member {
				kind: if kind.text()? == crate::protocol_data::REGISTERED {
					MemberChange::Registered
				} else {
					MemberChange::Unregistered
				},
				peer: Member {
					name,
					registration_id: id.0,
				},
				count: natural(&at(2)?)?.get(),
			})
		}
		crate::protocol_data::OPENED | crate::protocol_data::CLOSED | crate::protocol_data::COUNT => {
			let change = match kind.text()? {
				crate::protocol_data::OPENED => RoomChange::Opened,
				crate::protocol_data::CLOSED => RoomChange::Closed,
				_ => RoomChange::Count,
			};
			Some(Event::Room {
				kind: change,
				entry: room(len.checked_sub(1)?, |i| at(i + 1))?,
			})
		}
		_ => None,
	}
}
impl serde::Serialize for Event {
	fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
		use serde::ser::SerializeStruct;
		let mut fields =
			serializer.serialize_struct("RoomEvent", if matches!(self, Self::Member { .. }) { 5 } else { 4 })?;
		match self {
			Self::Room { kind, entry } => {
				fields.serialize_field("kind", kind)?;
				fields.serialize_field("name", &entry.name)?;
				fields.serialize_field("count", &entry.count)?;
				fields.serialize_field("entry", entry)?;
			}
			Self::Member { kind, peer, count } => {
				fields.serialize_field("kind", kind)?;
				fields.serialize_field("name", &peer.name)?;
				fields.serialize_field("registrationId", &peer.registration_id)?;
				fields.serialize_field("count", count)?;
				fields.serialize_field("entry", &())?;
			}
			Self::Truncated(count) => {
				fields.serialize_field("kind", "truncated")?;
				fields.serialize_field("name", "")?;
				fields.serialize_field("count", count)?;
				fields.serialize_field("entry", &())?;
			}
		}
		fields.end()
	}
}
