//! Receiving DMs has its own admission owner. Directory introductions cannot
//! protect bytes delivered directly to a callback. Source keys are proved
//! channel identities. Local and unproved callers share the safety pool.
use glowcap::Session;
use rooms_application::admission::{Charge, Class, CleanupReserve, Policy, Profile, Rate, Registry, Settings};
use sha2::{Digest, Sha256};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
	Recipient,
	Sender([u8; 32]),
}
struct Rates {
	individual: Profile,
	recipient: Profile,
}
impl Policy<Key> for Rates {
	fn rate(&self, key: Key, class: Class) -> Rate {
		match key {
			Key::Recipient => self.recipient.rate(class),
			Key::Sender(_) => self.individual.rate(class),
		}
	}
}
pub(super) struct Admission {
	registry: Registry<Key, Rates>,
	cleanup: CleanupReserve,
}
impl Admission {
	pub fn new(settings: Settings) -> Self {
		Self {
			cleanup: CleanupReserve::new(settings.aggregate().rate(Class::Cleanup)),
			registry: Registry::new(
				Rates {
					individual: settings.profile(),
					recipient: settings.aggregate(),
				},
				settings.rows(),
			),
		}
	}
	pub fn receive(&mut self, sender: [u8; 32], verb: &str, bytes: usize, now: u64) -> Result<(), String> {
		use rooms_application::{direct, protocol_data as protocol};
		// Withdrawal is an idempotent cleanup effect on an exact line actor.
		let class = match verb {
			protocol::WITHDRAW => Class::Cleanup,
			direct::DM | protocol::EDIT | protocol::REFILE => Class::Message,
			direct::TYPING => Class::RoomTransient,
			direct::READY => Class::Recipient,
			_ => Class::Create,
		};
		let bytes = if class == Class::Message {
			// Binary payload arrives through bounded file readers; this measures
			// retained scalar message material, before any callback input copy.
			u32::try_from(bytes).map_err(|_| "request-too-large: incoming message bytes overflow")?
		} else {
			0
		};
		let charges = [
			Charge {
				key: Key::Sender(sender),
				class,
				amount: 1,
			},
			Charge {
				key: Key::Recipient,
				class,
				amount: 1,
			},
			Charge {
				key: Key::Sender(sender),
				class: Class::MessageBytes,
				amount: bytes,
			},
			Charge {
				key: Key::Recipient,
				class: Class::MessageBytes,
				amount: bytes,
			},
		];
		let count = if bytes == 0 { 2 } else { 4 };
		let result = if class == Class::Cleanup {
			self.registry.admit_cleanup(&charges[..count], now, &mut self.cleanup)
		} else {
			self.registry.admit(&charges[..count], now)
		};
		result.map_err(|error| error.reason_at(rooms_application::admission::Owner::DirectInbox))
	}
}

/// Cache only the last calling channel's proved key. Steady traffic needs no
/// identity projection or hash. Replacement channels re-prove the same key and
/// spend the same retained row. This cache owns no admission debt.
#[derive(Default)]
pub(super) struct Sender {
	last: Option<(Session, [u8; 32])>,
}
impl Sender {
	pub fn key(&mut self, session: Option<&Session>) -> Result<[u8; 32], String> {
		let Some(session) = session else {
			return Ok([0; 32]);
		};
		if let Some((prior, key)) = &self.last
			&& prior.same_connection(session)
		{
			return Ok(*key);
		}
		let identity = session.partner_identity().map_err(|e| e.to_string())?;
		let key = if identity.durable_identity_authenticated() && !identity.designator.is_empty() {
			let mut hash = Sha256::new();
			hash.update(b"rooms:direct-sender:v1:");
			hash.update(identity.designator.as_bytes());
			hash.finalize().into()
		} else {
			[0; 32]
		};
		self.last = Some((session.borrowed(), key));
		Ok(key)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn one_sender_exhaustion_keeps_another_sender_and_withdrawal_available() {
		let mut policy = Admission::new(Settings::defaults(32, 8));
		for _ in 0..Class::Message.default_rate().burst() {
			policy.receive([1; 32], rooms_application::direct::DM, 10, 0).unwrap();
		}
		assert!(policy.receive([1; 32], rooms_application::direct::DM, 10, 0).is_err());
		policy.receive([2; 32], rooms_application::direct::DM, 10, 0).unwrap();
		policy
			.receive([1; 32], rooms_application::protocol_data::WITHDRAW, 0, 0)
			.unwrap();
		policy
			.receive([1; 32], rooms_application::direct::DM, 10, 1000)
			.unwrap();
	}

	#[test]
	fn withdrawal_for_an_absent_sender_survives_full_accounting() {
		let mut admission = Admission::new(Settings::defaults(2, 8));
		admission.receive([1; 32], rooms_application::direct::DM, 1, 0).unwrap();
		assert!(admission.receive([2; 32], rooms_application::direct::DM, 1, 0).is_err());
		admission
			.receive([2; 32], rooms_application::protocol_data::WITHDRAW, 0, 0)
			.unwrap();
	}
}
