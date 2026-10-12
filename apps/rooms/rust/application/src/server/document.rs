//! The version-one durable Rooms server document, `rooms.json`. The server's
//! Host identity and room-link secret live here beside the small set of rooms
//! somebody asked for durable authority over. Live membership is never
//! written. A document that fails the relations below is refused whole, and
//! never rewritten into shape.
use crate::{
	directory::creation::RecoveryKey,
	fields::{Hex, List, SafeInteger, Text},
	room::policy::RoomPolicy,
};
use alloc::{collections::BTreeSet, string::String, vec::Vec};
use serde::{Deserialize, Serialize};

pub const FILE: &str = "rooms.json";
pub const VERSION: u64 = 1;
pub const KEY_BYTES: usize = 32;
pub const MAX_BYTES: usize = 4 * 1024 * 1024;
/// Rooms one server keeps durable authority rows for.
pub const MAX_ROOM_LINKS: usize = 4096;
/// A durable room name: a public name, or a managed room's opaque key.
pub const MAX_DURABLE_ROOM: usize = 33;
pub const MAX_ROOM: usize = 32;
pub const MAX_TOPIC: usize = 300;

pub type DurableName = Text<MAX_DURABLE_ROOM, true>;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Generation {
	pub name: DurableName,
	pub generation: SafeInteger<true>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Steward {
	pub name: DurableName,
	pub generation: SafeInteger<true>,
	pub issued: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManagedRoom {
	pub id: DurableName,
	pub name: Text<MAX_ROOM, true>,
	pub generation: SafeInteger<true>,
	pub policy: RoomPolicy,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Topic {
	pub name: DurableName,
	pub topic: Text<MAX_TOPIC, true>,
}

/// The whole server document. It carries the identity seed and the room-link
/// secret, so its `Debug` prints the relation counts and never the secrets.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Document {
	pub version: u64,
	pub identity_seed: Hex<KEY_BYTES>,
	pub room_link_secret: Hex<KEY_BYTES>,
	pub linked_rooms: List<DurableName, MAX_ROOM_LINKS>,
	pub revoked_rooms: List<DurableName, MAX_ROOM_LINKS>,
	pub room_link_generations: List<Generation, MAX_ROOM_LINKS>,
	pub stewards: List<Steward, MAX_ROOM_LINKS>,
	pub managers: List<Steward, MAX_ROOM_LINKS>,
	pub managed_rooms: List<ManagedRoom, MAX_ROOM_LINKS>,
	pub topics: List<Topic, MAX_ROOM_LINKS>,
}

impl core::fmt::Debug for Document {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.debug_struct("Document")
			.field("version", &self.version)
			.field("linked_rooms", &self.linked_rooms.0.len())
			.field("revoked_rooms", &self.revoked_rooms.0.len())
			.field("stewards", &self.stewards.0.len())
			.field("managers", &self.managers.0.len())
			.field("managed_rooms", &self.managed_rooms.0.len())
			.field("topics", &self.topics.0.len())
			.finish_non_exhaustive()
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Json,
	Version,
	Shape,
	/// Linked, revoked, and stewarded room authority disagree.
	Relations,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Json => "rooms state is not JSON",
			Self::Version => "rooms state version is not supported",
			Self::Shape => "rooms state is invalid",
			Self::Relations => "linked, revoked, and stewarded room authority is inconsistent",
		})
	}
}
impl core::error::Error for Error {}

impl Document {
	/// A server with nothing durable yet, named by the entropy the adapter drew.
	pub fn fresh(identity_seed: [u8; KEY_BYTES], room_link_secret: [u8; KEY_BYTES]) -> Self {
		Self {
			version: VERSION,
			identity_seed: Hex(identity_seed),
			room_link_secret: Hex(room_link_secret),
			linked_rooms: List(Vec::new()),
			revoked_rooms: List(Vec::new()),
			room_link_generations: List(Vec::new()),
			stewards: List(Vec::new()),
			managers: List(Vec::new()),
			managed_rooms: List(Vec::new()),
			topics: List(Vec::new()),
		}
	}
	pub fn identity_seed(&self) -> &[u8; KEY_BYTES] {
		&self.identity_seed.0
	}
	pub fn room_link_secret(&self) -> &[u8; KEY_BYTES] {
		&self.room_link_secret.0
	}
	pub fn decode(text: &str) -> Result<Self, Error> {
		let value: serde_json::Value = serde_json::from_str(text).map_err(|_| Error::Json)?;
		if value.get("version").and_then(serde_json::Value::as_u64) != Some(VERSION) {
			return Err(Error::Version);
		}
		let document: Self = serde_json::from_value(value).map_err(|_| Error::Shape)?;
		document.validate()?;
		Ok(document)
	}
	pub fn encode(&self) -> Result<String, Error> {
		self.validate()?;
		serde_json::to_string(self).map_err(|_| Error::Shape)
	}
	/// The relations a server document holds: names fold case-insensitively,
	/// stewards only over linked rooms, managers over linked or revoked ones,
	/// managed rooms under a manager with distinct listed names, generations
	/// and topics over rooms this document knows.
	pub fn validate(&self) -> Result<(), Error> {
		let fold = |name: &DurableName| name.text().lowercase();
		let mut linked = BTreeSet::new();
		for name in &self.linked_rooms.0 {
			if !linked.insert(fold(name)) {
				return Err(Error::Relations);
			}
		}
		let mut revoked = BTreeSet::new();
		for name in &self.revoked_rooms.0 {
			let key = fold(name);
			if linked.contains(&key) || !revoked.insert(key) {
				return Err(Error::Relations);
			}
		}
		let mut stewarded = BTreeSet::new();
		for steward in &self.stewards.0 {
			let key = fold(&steward.name);
			if !linked.contains(&key) || !stewarded.insert(key) {
				return Err(Error::Relations);
			}
		}
		let mut managed = BTreeSet::new();
		for manager in &self.managers.0 {
			let key = fold(&manager.name);
			if (!linked.contains(&key) && !revoked.contains(&key)) || !managed.insert(key) {
				return Err(Error::Relations);
			}
		}
		let mut managed_rooms = BTreeSet::new();
		let mut listed = BTreeSet::new();
		for room in &self.managed_rooms.0 {
			let key = fold(&room.id);
			if !managed.contains(&key) || !managed_rooms.insert(key) {
				return Err(Error::Relations);
			}
			if room.policy.is_listed() && !listed.insert(room.name.text().lowercase()) {
				return Err(Error::Relations);
			}
		}
		let mut generations = BTreeSet::new();
		for row in &self.room_link_generations.0 {
			let key = fold(&row.name);
			if (!linked.contains(&key) && !revoked.contains(&key)) || !generations.insert(key) {
				return Err(Error::Relations);
			}
		}
		let mut topics = BTreeSet::new();
		for topic in &self.topics.0 {
			let key = fold(&topic.name);
			let managed_key = topic.name.text().as_str().is_some_and(RecoveryKey::accepts);
			if (managed_key && !linked.contains(&key)) || !topics.insert(key) {
				return Err(Error::Relations);
			}
		}
		Ok(())
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use alloc::{format, string::ToString};

	/// A kept document for a server with one linked room,
	/// a steward, a manager, and a managed room under it.
	const KEPT: &str = r#"{"version":1,"identitySeed":"0101010101010101010101010101010101010101010101010101010101010101","roomLinkSecret":"0202020202020202020202020202020202020202020202020202020202020202","linkedRooms":["Garden","~00000000000000000000000000000001"],"revokedRooms":["old"],"roomLinkGenerations":[{"name":"garden","generation":3}],"stewards":[{"name":"garden","generation":1,"issued":true}],"managers":[{"name":"~00000000000000000000000000000001","generation":2,"issued":false},{"name":"old","generation":1,"issued":true}],"managedRooms":[{"id":"~00000000000000000000000000000001","name":"Garden","generation":2,"policy":{"visibility":"listed","entry":"open","speaking":"moderated"}}],"topics":[{"name":"garden","topic":"seedlings"},{"name":"~00000000000000000000000000000001","topic":"kept"}]}"#;

	#[test]
	fn a_kept_document_decodes_and_encodes_to_the_same_relations() {
		let document = Document::decode(KEPT).unwrap();
		assert_eq!(document.identity_seed(), &[1; 32]);
		assert_eq!(document.linked_rooms.0.len(), 2);
		assert_eq!(document.managed_rooms.0[0].policy, RoomPolicy::Moderated);
		let again = Document::decode(&document.encode().unwrap()).unwrap();
		assert!(again == document, "a decoded document round-trips");
	}

	#[test]
	fn a_fresh_document_is_empty_and_valid() {
		let fresh = Document::fresh([7; 32], [9; 32]);
		let text = fresh.encode().unwrap();
		assert!(text.contains("\"linkedRooms\":[]"));
		assert!(
			Document::decode(&text).unwrap() == fresh,
			"a fresh document round-trips"
		);
	}

	#[test]
	fn corrupt_documents_are_refused_whole() {
		assert_eq!(Document::decode("{").unwrap_err(), Error::Json);
		assert_eq!(
			Document::decode(&KEPT.replace("\"version\":1", "\"version\":2")).unwrap_err(),
			Error::Version
		);
		assert_eq!(
			Document::decode(&KEPT.replace("\"topics\"", "\"extra\":1,\"topics\"")).unwrap_err(),
			Error::Shape
		);
		assert_eq!(
			Document::decode(&KEPT.replace("0101010101010101", "010101010101010")).unwrap_err(),
			Error::Shape
		);
		// A steward over an unlinked room, a linked room revoked, and a managed
		// room without its manager each break the relations.
		let unlinked = KEPT.replace(
			"\"stewards\":[{\"name\":\"garden\"",
			"\"stewards\":[{\"name\":\"other\"",
		);
		assert_eq!(Document::decode(&unlinked).unwrap_err(), Error::Relations);
		let revoked_twice = KEPT.replace("\"revokedRooms\":[\"old\"]", "\"revokedRooms\":[\"GARDEN\"]");
		assert_eq!(Document::decode(&revoked_twice).unwrap_err(), Error::Relations);
		let unmanaged = KEPT.replace(
			"{\"name\":\"~00000000000000000000000000000001\",\"generation\":2,\"issued\":false},",
			"",
		);
		assert_eq!(Document::decode(&unmanaged).unwrap_err(), Error::Relations);
	}

	#[test]
	fn the_error_names_what_was_wrong() {
		assert_eq!(Error::Relations.to_string(), format!("{}", Error::Relations));
		assert!(Error::Version.to_string().contains("version"));
	}
}
