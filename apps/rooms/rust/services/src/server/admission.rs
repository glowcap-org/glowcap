//! Data work has one process-local accounting owner. Capability possession
//! still decides authority. This module attributes cost to the calling peer,
//! including a facet handed across connections, never to its original minter.
use super::Error;
use super::state::State;
use rooms_application::admission::{Charge, Class, CleanupReserve, Policy, Rate, Registry, Settings};
use sha2::{Digest, Sha256};
use std::fmt;

/// Why this admission owner refused on its own account. Display is the exact
/// line the caller and the peer read. The registry's own refusals stay typed
/// in the application crate and render at the owner's edge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AdmissionRefusal {
	/// The room generation the work attaches to has ended.
	GenerationEnded,
	/// The introduction's target no longer carries the name it was offered. status-allow: lifecycle transition
	TargetRenamed,
	/// The calling connection never completed registration.
	RequiresRegistration,
}

impl fmt::Display for AdmissionRefusal {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::GenerationEnded => f.write_str("room generation has ended"),
			Self::TargetRenamed => f.write_str("introduction target no longer has that name"),
			Self::RequiresRegistration => f.write_str("introduction requires registration"),
		}
	}
}

impl std::error::Error for AdmissionRefusal {}

impl From<AdmissionRefusal> for String {
	fn from(refusal: AdmissionRefusal) -> Self {
		refusal.to_string()
	}
}

impl From<AdmissionRefusal> for Error {
	fn from(refusal: AdmissionRefusal) -> Self {
		Error::refused(refusal.to_string())
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct Subject([u8; 32]);
impl Subject {
	pub fn new(proved: Option<&str>, connection: u64) -> Self {
		let mut hash = Sha256::new();
		match proved {
			Some(key) => {
				// AuthenticatedTransport proves the advertised durable key. A
				// carrier change must not mint a new allowance for that same key.
				hash.update(b"rooms:authenticated-key:v1:");
				hash.update(key.as_bytes());
			}
			None => {
				hash.update(b"rooms:unproved-connection:v1:");
				hash.update(connection.to_be_bytes());
			}
		}
		Self(hash.finalize().into())
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
	Deployment,
	Peer(Subject),
	Room(Subject, [u8; 32]),
}
struct Rates {
	individual: rooms_application::admission::Profile,
	aggregate: rooms_application::admission::Profile,
}
impl Policy<Key> for Rates {
	fn rate(&self, key: Key, class: Class) -> Rate {
		match key {
			Key::Deployment => self.aggregate.rate(class),
			_ => self.individual.rate(class),
		}
	}
}
pub(super) struct Admission {
	registry: Registry<Key, Rates>,
	cleanup: CleanupReserve,
	pub settings: Settings,
}
impl Admission {
	pub fn new(settings: Settings) -> Self {
		Self {
			cleanup: CleanupReserve::new(settings.aggregate().rate(Class::Cleanup)),
			registry: Registry::new(
				Rates {
					individual: settings.profile(),
					aggregate: settings.aggregate(),
				},
				settings.rows(),
			),
			settings,
		}
	}
	pub fn ingress(&mut self, subject: Subject, proved: bool, started: bool, now: u64) -> Result<(), String> {
		let peer = Charge {
			key: Key::Peer(subject),
			class: Class::Ingress,
			amount: 1,
		};
		let connection = Charge {
			key: peer.key,
			class: Class::Connection,
			amount: 1,
		};
		let deployment = Charge {
			key: Key::Deployment,
			class: Class::HttpStart,
			amount: 1,
		};
		let charges = [peer, connection, deployment];
		let count = if started {
			1
		} else if proved {
			2
		} else {
			3
		};
		// Ingress remains independent from operation allowance: malformed and
		// unauthorized attempts still spend their bounded reply budget.
		self.registry
			.admit(&charges[..count], now)
			.map_err(|refusal| refusal.reason_at(rooms_application::admission::Owner::Directory))
	}
	pub fn operation(&mut self, subject: Subject, class: Class, amount: u32, now: u64) -> Result<(), String> {
		let charges = [Charge {
			key: Key::Peer(subject),
			class,
			amount,
		}];
		let result = if class == Class::Cleanup {
			self.registry.admit_cleanup(&charges, now, &mut self.cleanup)
		} else {
			self.registry.admit(&charges, now)
		};
		result.map_err(|refusal| refusal.reason_at(rooms_application::admission::Owner::Directory))
	}
	pub fn join(&mut self, subject: Subject, generation: &str, now: u64) -> Result<(), String> {
		self.scoped(subject, generation, Class::Join, Class::RoomJoin, now)
	}
	pub fn transient(&mut self, subject: Subject, generation: &str, now: u64) -> Result<(), String> {
		self.scoped(subject, generation, Class::Transient, Class::RoomTransient, now)
	}
	fn scoped(
		&mut self,
		subject: Subject,
		generation: &str,
		aggregate: Class,
		scoped: Class,
		now: u64,
	) -> Result<(), String> {
		// Generations come from the admitted authority, including IRC and
		// foreign publications. Hash once at these infrequent lifecycle edges.
		let generation = Sha256::digest(generation.as_bytes()).into();
		self.registry
			.admit(
				&[
					Charge {
						key: Key::Peer(subject),
						class: aggregate,
						amount: 1,
					},
					Charge {
						key: Key::Room(subject, generation),
						class: scoped,
						amount: 1,
					},
				],
				now,
			)
			.map_err(|refusal| refusal.reason_at(rooms_application::admission::Owner::Directory))
	}
	pub fn message(&mut self, subject: Subject, bytes: usize, now: u64) -> Result<(), String> {
		let amount = u32::try_from(bytes).map_err(|_| {
			rooms_application::admission::Refusal::TooLarge {
				class: Class::MessageBytes,
			}
			.reason()
		})?;
		self.registry
			.admit(
				&[
					Charge {
						key: Key::Peer(subject),
						class: Class::Message,
						amount: 1,
					},
					Charge {
						key: Key::Peer(subject),
						class: Class::MessageBytes,
						amount,
					},
				],
				now,
			)
			.map_err(|refusal| refusal.reason_at(rooms_application::admission::Owner::Directory))
	}
	pub fn signaling(&mut self, sender: Subject, recipient: Subject, now: u64) -> Result<(), String> {
		self.paired(sender, recipient, Class::Signal, now)
	}
	pub fn introduction(&mut self, sender: Subject, recipient: Subject, now: u64) -> Result<(), String> {
		self.paired(sender, recipient, Class::Introduction, now)
	}
	fn paired(&mut self, sender: Subject, recipient: Subject, class: Class, now: u64) -> Result<(), String> {
		self.registry
			.admit(
				&[
					Charge {
						key: Key::Peer(sender),
						class,
						amount: 1,
					},
					Charge {
						key: Key::Peer(recipient),
						class: Class::Recipient,
						amount: 1,
					},
				],
				now,
			)
			.map_err(|refusal| refusal.reason_at(rooms_application::admission::Owner::Directory))
	}
	pub fn statistics(&self) -> (usize, rooms_application::admission::Statistics) {
		(self.registry.len(), self.registry.statistics())
	}
	pub fn coalesced(&mut self, class: Class) {
		self.registry.coalesced(class);
	}
}

impl State {
	pub fn admit_introduction(
		&mut self,
		connection: u64,
		nick: &str,
		id: &str,
		opening: Option<&str>,
	) -> Result<(), String> {
		let id = rooms_application::directory::registration::Id::parse(id).map_err(|e| e.to_string())?;
		let target = self.policy.registration_connection(&id).map_err(|r| r.reason())?;
		if self.policy.member_registration(nick).ok().as_ref() != Some(&id) {
			return Err(AdmissionRefusal::TargetRenamed.into());
		}
		if self.policy.registered_nick(connection).is_none() {
			return Err(AdmissionRefusal::RequiresRegistration.into());
		}
		let (sender, _, _) = self.admission_context(connection)?;
		// Consumption of a settled offer is a read, not a second opening.
		// Pending attempts still spend requester and recipient safety allowance
		// before any mint notification or deferred work can be queued.
		if opening.is_some_and(|opening| self.policy.introduction_ready(connection, nick, id.as_str(), opening)) {
			return self.admission.operation(sender, Class::Read, 1, self.now());
		}
		let (recipient, _, _) = self.admission_context(target)?;
		self.admission.introduction(sender, recipient, self.now())
	}
	pub fn ingress(&mut self, connection: u64) -> Result<(), String> {
		let (subject, proved, started) = self.admission_context(connection)?;
		self.admission.ingress(subject, proved, started, self.now())?;
		self.mark_data_admitted(connection);
		Ok(())
	}
	pub fn admit_work(&mut self, connection: u64, class: Class, amount: u32) -> Result<(), String> {
		let (subject, _, _) = self.admission_context(connection)?;
		self.admission.operation(subject, class, amount, self.now())
	}
	pub fn admit_join(&mut self, connection: u64, generation: &str) -> Result<(), String> {
		let (subject, _, _) = self.admission_context(connection)?;
		self.admission.join(subject, generation, self.now())
	}
	pub fn admit_transient(
		&mut self,
		connection: u64,
		room: &rooms_application::server::rooms::RoomKey,
	) -> Result<(), String> {
		let (subject, _, _) = self.admission_context(connection)?;
		let generation = self.rooms.generation(room).ok_or(AdmissionRefusal::GenerationEnded)?;
		self.admission.transient(subject, generation, self.now())
	}
	pub fn admit_message(&mut self, connection: u64, bytes: usize) -> Result<(), String> {
		let (subject, _, _) = self.admission_context(connection)?;
		self.admission.message(subject, bytes, self.now())
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn replacement_connection_keeps_proved_debt_and_other_peer_progresses() {
		let mut admission = Admission::new(Settings::defaults(8192, 1));
		let mut accepted = 0;
		for now in (0..=30_000).step_by(1000) {
			let subject = Subject::new(Some("proved-key"), now);
			if admission.ingress(subject, true, false, now).is_ok() {
				accepted += 1;
			}
			admission.message(Subject::new(Some("other-key"), now), 1, now).unwrap();
		}
		assert_eq!(accepted, 9);
	}
	#[test]
	fn changing_room_generation_does_not_restore_aggregate_join_allowance() {
		let mut admission = Admission::new(Settings::defaults(8192, 1));
		let subject = Subject::new(Some("proved-key"), 0);
		let burst = Class::Join.default_rate().burst();
		for index in 0..burst {
			admission.join(subject, &format!("{index:036}"), 0).unwrap();
		}
		assert!(
			admission
				.join(subject, &format!("{burst:036}"), 0)
				.unwrap_err()
				.starts_with("rate-limited:")
		);
		admission.operation(subject, Class::Read, 1, 0).unwrap();
	}
	#[test]
	fn transient_restore_is_room_scoped_and_one_rooms_debt_does_not_block_another() {
		let mut admission = Admission::new(Settings::defaults(8192, 1));
		let subject = Subject::new(Some("proved-key"), 0);
		for room in 0..256 {
			admission.transient(subject, &format!("{room:036}"), 0).unwrap();
		}
		// Refill the aggregate before checking a single room's independent debt.
		for _ in 0..4 {
			admission.transient(subject, "single-room", 60_000).unwrap();
		}
		assert!(admission.transient(subject, "single-room", 60_000).is_err());
		admission.transient(subject, "another-room", 60_000).unwrap();
	}

	#[test]
	fn cleanup_for_an_absent_peer_survives_full_accounting() {
		let mut admission = Admission::new(Settings::defaults(1, 1));
		let flooder = Subject::new(Some("flooder"), 1);
		let old_member = Subject::new(Some("old-member"), 2);
		admission.message(flooder, 1, 0).unwrap();
		assert!(admission.message(old_member, 1, 0).is_err());
		admission.operation(old_member, Class::Cleanup, 1, 0).unwrap();
	}
}
