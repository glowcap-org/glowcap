//! Durable room authority: which room names this server made durable, the
//! stewards and managers issued over them, the managed rooms under those
//! managers, and the subjects remembered for them. Every value is a function of
//! the server document, and every change is a new authority whose document
//! the adapter persists before installing it, so a link is never handed out
//! that a restart would not answer.
//!
//! Sturdyref entropy is derived, never drawn: a MAC over the room name under
//! the stored secret rebuilds the same durable name on every start, and a
//! generation folded into the message retires an old link for good.
use super::document::{self, Document, DurableName, Generation, KEY_BYTES, KeptSubject, ManagedRoom, Steward};
use crate::{
	directory::creation::RecoveryKey,
	failure::FailureCode,
	fields::{Hex, List, SafeInteger, Text, lower_hex},
	room::{policy::RoomPolicy, subject::Subject},
	text::DocumentText,
};
use alloc::{collections::BTreeMap, format, string::String};
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
mod publications;

/// The Host derives a durable swiss name from this many embedder bytes.
pub const ENTROPY_BYTES: usize = 16;
const MAX_SAFE: u64 = (1 << 53) - 1;
const STEWARD_DOMAIN: &str = "steward\0";
const MANAGER_DOMAIN: &str = "manager\0";
const MANAGED_ROOM_DOMAIN: &str = "managed-room\0";
const ROOM_GENERATION_DOMAIN: &str = "room-generation\0";

pub use super::Refusal;

/// One issued or revoked steward or manager generation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Issue {
	pub name: String,
	pub generation: u64,
	pub issued: bool,
}

/// One managed room: an opaque durable id, the public name and policy under
/// it, and the generation that retires stale public entrances.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Managed {
	pub id: String,
	pub name: String,
	pub generation: u64,
	pub policy: RoomPolicy,
}

/// What a managed room's public name and policy become.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Registration<'a> {
	pub name: &'a str,
	pub policy: RoomPolicy,
}

/// The authority a server holds, read from its document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Authority {
	identity_seed: [u8; KEY_BYTES],
	secret: [u8; KEY_BYTES],
	linked: BTreeMap<String, String>,
	revoked: BTreeMap<String, String>,
	generations: BTreeMap<String, u64>,
	stewards: BTreeMap<String, Issue>,
	managers: BTreeMap<String, Issue>,
	managed: BTreeMap<String, Managed>,
	managed_by_name: BTreeMap<String, String>,
	publications: BTreeMap<String, String>,
	/// Each remembered subject under its folded room name, beside the name as
	/// it was written.
	subjects: BTreeMap<String, (String, Subject)>,
}

fn fold(name: &str) -> String {
	name.to_lowercase()
}

fn utf8(text: &DocumentText) -> Result<String, document::Error> {
	text.as_str().map(String::from).ok_or(document::Error::Shape)
}

fn durable(name: &str) -> DurableName {
	Text(name.into())
}

fn positive(value: u64) -> SafeInteger<true> {
	#[expect(
		clippy::expect_used,
		reason = "generations start at one and advance by one per change, far inside the 2^53 bound"
	)]
	SafeInteger::new(value).expect("generations stay within the safe range")
}

impl Authority {
	/// Read the document. The derivations below hash the UTF-8 bytes of a
	/// name, so a name carrying an isolated surrogate is refused here.
	pub fn read(document: &Document) -> Result<Self, document::Error> {
		document.validate()?;
		let mut authority = Self {
			identity_seed: document.identity_seed.0,
			secret: document.room_link_secret.0,
			linked: BTreeMap::new(),
			revoked: BTreeMap::new(),
			generations: BTreeMap::new(),
			stewards: BTreeMap::new(),
			managers: BTreeMap::new(),
			managed: BTreeMap::new(),
			managed_by_name: BTreeMap::new(),
			publications: BTreeMap::new(),
			subjects: BTreeMap::new(),
		};
		for name in document.linked_rooms.as_slice() {
			let name = utf8(name.text())?;
			authority.linked.insert(fold(&name), name);
		}
		for name in document.revoked_rooms.as_slice() {
			let name = utf8(name.text())?;
			authority.revoked.insert(fold(&name), name);
		}
		for row in document.room_link_generations.as_slice() {
			authority
				.generations
				.insert(fold(&utf8(row.name.text())?), row.generation.get());
		}
		let issue = |row: &Steward| -> Result<(String, Issue), document::Error> {
			let name = utf8(row.name.text())?;
			Ok((
				fold(&name),
				Issue {
					name,
					generation: row.generation.get(),
					issued: row.issued,
				},
			))
		};
		for row in document.stewards.as_slice() {
			let (key, row) = issue(row)?;
			authority.stewards.insert(key, row);
		}
		for row in document.managers.as_slice() {
			let (key, row) = issue(row)?;
			authority.managers.insert(key, row);
		}
		for room in document.managed_rooms.as_slice() {
			let managed = Managed {
				id: utf8(room.id.text())?,
				name: utf8(room.name.text())?,
				generation: room.generation.get(),
				policy: room.policy,
			};
			authority.file_managed(managed);
		}
		for row in document.subjects.as_slice() {
			let name = utf8(row.name.text())?;
			let link = row.link.as_ref().map(|link| utf8(link.text())).transpose()?;
			let subject = Subject::new(utf8(row.description.text())?, link).map_err(|_| document::Error::Shape)?;
			authority.subjects.insert(fold(&name), (name, subject));
		}
		authority.reindex_publications();
		Ok(authority)
	}
	/// The document this authority persists as.
	pub fn document(&self) -> Document {
		let issues = |rows: &BTreeMap<String, Issue>| {
			List(
				rows.values()
					.map(|row| Steward {
						name: durable(&row.name),
						generation: positive(row.generation),
						issued: row.issued,
					})
					.collect(),
			)
		};
		Document {
			version: document::VERSION,
			identity_seed: Hex(self.identity_seed),
			room_link_secret: Hex(self.secret),
			linked_rooms: List(self.linked.values().map(|name| durable(name)).collect()),
			revoked_rooms: List(self.revoked.values().map(|name| durable(name)).collect()),
			room_link_generations: List(
				self.generations
					.iter()
					.filter(|(_, generation)| **generation != 0)
					.filter_map(|(key, generation)| {
						let name = self.linked.get(key).or_else(|| self.revoked.get(key))?;
						Some(Generation {
							name: durable(name),
							generation: positive(*generation),
						})
					})
					.collect(),
			),
			stewards: issues(&self.stewards),
			managers: issues(&self.managers),
			managed_rooms: List(
				self.managed
					.values()
					.map(|room| ManagedRoom {
						id: durable(&room.id),
						name: Text(room.name.as_str().into()),
						generation: positive(room.generation),
						policy: room.policy,
					})
					.collect(),
			),
			subjects: List(
				self.subjects
					.values()
					.map(|(name, subject)| KeptSubject {
						name: durable(name),
						description: Text(subject.description().into()),
						link: subject.link().map(|link| Text(link.into())),
					})
					.collect(),
			),
		}
	}
	pub fn identity_seed(&self) -> &[u8; KEY_BYTES] {
		&self.identity_seed
	}

	/// A successor stands only if its document still holds the relations
	/// `Document::validate` checks.
	fn admitted(mut next: Self) -> Result<Self, Refusal> {
		next.document()
			.validate()
			.map_err(|error| Refusal::plain(format!("rooms state change is invalid: {error}")))?;
		next.reindex_publications();
		Ok(next)
	}
	fn file_managed(&mut self, room: Managed) {
		let key = fold(&room.id);
		if room.policy.is_listed() {
			self.managed_by_name.insert(fold(&room.name), room.id.clone());
		}
		self.managed.insert(key, room);
	}
	fn refile_managed(&mut self) {
		self.managed_by_name.clear();
		for room in self.managed.values() {
			if room.policy.is_listed() {
				self.managed_by_name.insert(fold(&room.name), room.id.clone());
			}
		}
	}

	pub fn linked_rooms(&self) -> impl Iterator<Item = &str> {
		self.linked.values().map(String::as_str)
	}
	/// Public names remain claimed even when no live room holds members.
	/// Managed rooms claim their listed name, never their opaque durable id.
	pub fn public_rooms(&self) -> impl Iterator<Item = (&str, &str)> {
		self.linked
			.values()
			.filter(|name| self.managed_room(name).is_none())
			.map(|name| (name.as_str(), name.as_str()))
			.chain(
				self.managed
					.values()
					.filter(|room| room.policy.is_listed())
					.map(|room| (room.name.as_str(), room.id.as_str())),
			)
	}
	pub fn public_name_taken(&self, name: &str) -> bool {
		self.managed_room_id_for_name(name).is_some()
			|| (self.room_link_active(name) && self.managed_room(name).is_none())
	}
	pub fn room_link_active(&self, name: &str) -> bool {
		self.linked.contains_key(&fold(name))
	}
	pub fn room_link_generation(&self, name: &str) -> u64 {
		self.generations.get(&fold(name)).copied().unwrap_or(0)
	}
	pub fn room_link_generation_is_current(&self, name: &str, generation: u64) -> bool {
		self.room_link_active(name) && self.room_link_generation(name) == generation
	}
	pub fn stewards(&self) -> impl Iterator<Item = &Issue> {
		self.stewards.values()
	}
	pub fn stewardship(&self, name: &str) -> Option<&Issue> {
		self.stewards.get(&fold(name))
	}
	pub fn has_steward(&self, name: &str) -> bool {
		self.stewardship(name).is_some_and(|row| row.issued)
	}
	pub fn steward_generation(&self, name: &str) -> u64 {
		self.stewardship(name).map_or(0, |row| row.generation)
	}
	pub fn steward_generation_is_current(&self, name: &str, generation: u64) -> bool {
		self.stewardship(name)
			.is_some_and(|row| row.issued && row.generation == generation)
	}
	pub fn managers(&self) -> impl Iterator<Item = &Issue> {
		self.managers.values()
	}
	pub fn has_manager(&self, name: &str) -> bool {
		self.managers.get(&fold(name)).is_some_and(|row| row.issued)
	}
	pub fn manager_generation(&self, name: &str) -> u64 {
		self.managers.get(&fold(name)).map_or(0, |row| row.generation)
	}
	pub fn manager_generation_is_current(&self, name: &str, generation: u64) -> bool {
		self.managers
			.get(&fold(name))
			.is_some_and(|row| row.issued && row.generation == generation)
	}
	pub fn managed_room(&self, id: &str) -> Option<&Managed> {
		self.managed.get(&fold(id))
	}
	pub fn managed_room_generation_is_current(&self, id: &str, generation: u64) -> bool {
		self.managed_room(id).is_some_and(|room| room.generation == generation)
	}
	pub fn managed_room_id_for_name(&self, name: &str) -> Option<&str> {
		self.managed_by_name.get(&fold(name)).map(String::as_str)
	}
	pub fn subject(&self, name: &str) -> Option<&Subject> {
		self.subjects.get(&fold(name)).map(|(_, subject)| subject)
	}

	fn entropy_for(&self, message: &str) -> [u8; ENTROPY_BYTES] {
		#[expect(
			clippy::expect_used,
			reason = "HMAC accepts a key of any length; new_from_slice refuses only fixed-key MACs"
		)]
		let mut mac = Hmac::<Sha256>::new_from_slice(&self.secret).expect("HMAC accepts a 32-byte key");
		mac.update(message.as_bytes());
		let digest = mac.finalize().into_bytes();
		let mut entropy = [0u8; ENTROPY_BYTES];
		entropy.copy_from_slice(&digest[..ENTROPY_BYTES]);
		entropy
	}
	/// The entropy one room's durable sturdyref is minted from. The name is
	/// not recoverable from the result, so holding one link discloses the room
	/// it opens and nothing about any other.
	pub fn room_entropy(&self, name: &str, generation: u64) -> [u8; ENTROPY_BYTES] {
		let durable = fold(name);
		if generation == 0 {
			self.entropy_for(&durable)
		} else {
			self.entropy_for(&format!("{ROOM_GENERATION_DOMAIN}{generation}\0{durable}"))
		}
	}
	/// A steward's durable name is reproducible with its room but can neither
	/// collide with nor be substituted for the room publication itself.
	pub fn steward_entropy(&self, name: &str, generation: u64) -> [u8; ENTROPY_BYTES] {
		let durable = fold(name);
		let room_generation = self.room_link_generation(name);
		let steward = if generation == 0 {
			format!("{STEWARD_DOMAIN}{durable}")
		} else {
			format!("{STEWARD_DOMAIN}{generation}\0{durable}")
		};
		if room_generation == 0 {
			self.entropy_for(&steward)
		} else {
			self.entropy_for(&format!("{ROOM_GENERATION_DOMAIN}{room_generation}\0{steward}"))
		}
	}
	pub fn manager_entropy(&self, name: &str, generation: u64) -> [u8; ENTROPY_BYTES] {
		self.entropy_for(&format!("{MANAGER_DOMAIN}{generation}\0{}", fold(name)))
	}
	/// A stable, public correlator for a room's management, as lowercase hex.
	pub fn manager_identity(&self, name: &str) -> String {
		let entropy = self.entropy_for(&format!("{MANAGED_ROOM_DOMAIN}{}", fold(name)));
		lower_hex(&entropy)
	}
}

impl Managed {
	pub fn registration(&self) -> Registration<'_> {
		Registration {
			name: &self.name,
			policy: self.policy,
		}
	}
}

impl core::fmt::Display for Issue {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		write!(
			f,
			"{} generation {} {}",
			self.name,
			self.generation,
			if self.issued { "issued" } else { "revoked" }
		)
	}
}

mod successors;
#[cfg(test)]
mod tests;
