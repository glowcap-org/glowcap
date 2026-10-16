//! Successor authorities. Every change to what the server made durable is a
//! new `Authority` validated against the document's relations, which the
//! adapter persists before installing, so a link is never handed out that a
//! restart would not answer.
use super::*;

impl Authority {
	/// Make `name` durable. Also issues a steward or a manager when asked,
	/// and files a managed room under its opaque id. The successor is `None`
	/// when nothing changes.
	pub fn remembered(
		&self,
		name: &str,
		steward: bool,
		manager: bool,
		managed: Option<Registration<'_>>,
	) -> Result<Option<Self>, Refusal> {
		let key = fold(name);
		let existing_managed = self.managed.get(&key);
		let needs_managed = managed.as_ref().is_some_and(|managed| {
			existing_managed.is_none_or(|held| held.name != managed.name || held.policy != managed.policy)
		});
		if self.linked.contains_key(&key)
			&& (!steward || self.has_steward(name))
			&& (!manager || self.has_manager(name))
			&& !needs_managed
		{
			return Ok(None);
		}
		if managed.is_some() && !RecoveryKey::accepts(name) {
			return Err(Refusal::plain("managed room state needs opaque room identity"));
		}
		if needs_managed && existing_managed.is_some() {
			return Err(Refusal::plain(
				"managed room creation does not replace existing room state",
			));
		}
		if !self.linked.contains_key(&key)
			&& !self.revoked.contains_key(&key)
			&& self.linked.len() + self.revoked.len() >= document::MAX_ROOM_LINKS
		{
			return Err(Refusal::coded(
				FailureCode::RoomLinksFull,
				format!(
					"this server has already made {} room names durable",
					document::MAX_ROOM_LINKS
				),
			));
		}
		let mut next = self.clone();
		if !next.linked.contains_key(&key) && next.revoked.contains_key(&key) {
			let generation = next.generations.get(&key).copied().unwrap_or(0) + 1;
			if generation > MAX_SAFE {
				return Err(Refusal::plain(format!(
					"room \"{name}\" has exhausted link generations"
				)));
			}
			next.generations.insert(key.clone(), generation);
			next.revoked.remove(&key);
		}
		next.linked.insert(key.clone(), name.into());
		if steward && !next.has_steward(name) {
			let generation = next.stewards.get(&key).map_or(1, |row| row.generation + 1);
			if generation > MAX_SAFE {
				return Err(Refusal::plain(format!(
					"room \"{name}\" has exhausted stewardship generations"
				)));
			}
			next.stewards.insert(
				key.clone(),
				Issue {
					name: name.into(),
					generation,
					issued: true,
				},
			);
		}
		if manager && !next.has_manager(name) {
			let generation = next.managers.get(&key).map_or(1, |row| row.generation + 1);
			if generation > MAX_SAFE {
				return Err(Refusal::plain(format!("room \"{name}\" exhausted manager generations")));
			}
			next.managers.insert(
				key.clone(),
				Issue {
					name: name.into(),
					generation,
					issued: true,
				},
			);
		}
		if let Some(managed) = managed {
			next.file_managed(Managed {
				id: name.into(),
				name: managed.name.into(),
				generation: 1,
				policy: managed.policy,
			});
		}
		Ok(Some(Self::admitted(next)?))
	}
	/// Change a managed room's public name and policy. `None` when it already
	/// stands that way.
	pub fn with_managed_room_policy(&self, id: &str, name: &str, policy: RoomPolicy) -> Result<Option<Self>, Refusal> {
		let key = fold(id);
		let Some(current) = self.managed.get(&key).filter(|_| self.has_manager(id)) else {
			return Err(Refusal::plain("this manager has no current managed room"));
		};
		if current.name == name && current.policy == policy {
			return Ok(None);
		}
		if current.generation == MAX_SAFE {
			return Err(Refusal::plain(format!(
				"room \"{}\" exhausted public entrance generations",
				current.name
			)));
		}
		let mut next = self.clone();
		next.managed.insert(
			key,
			Managed {
				id: current.id.clone(),
				name: name.into(),
				generation: current.generation + 1,
				policy,
			},
		);
		next.refile_managed();
		Ok(Some(Self::admitted(next)?))
	}
	/// Remember or take down a room's subject. `None` when nothing changes,
	/// including for a room this server has no durable name for.
	pub fn with_subject(&self, name: &str, subject: &Subject) -> Result<Option<Self>, Refusal> {
		let key = fold(name);
		let durable = match self.linked.get(&key) {
			Some(name) => name.clone(),
			None if RecoveryKey::accepts(name) => return Ok(None),
			None => name.into(),
		};
		if self.subjects.get(&key).is_some_and(|(_, held)| held == subject) {
			return Ok(None);
		}
		let mut next = self.clone();
		if subject.is_empty() {
			if next.subjects.remove(&key).is_none() {
				return Ok(None);
			}
		} else {
			if !next.subjects.contains_key(&key) && next.subjects.len() == document::MAX_ROOM_LINKS {
				return Err(Refusal::plain(format!(
					"this server remembers subjects for at most {} rooms",
					document::MAX_ROOM_LINKS
				)));
			}
			next.subjects.insert(key, (durable, subject.clone()));
		}
		Ok(Some(Self::admitted(next)?))
	}
	/// Tombstone the current room publication generation. The name stays in
	/// the bounded registry until a later issue advances its generation.
	pub fn with_room_link_revoked(&self, name: &str) -> Result<Self, Refusal> {
		let key = fold(name);
		let Some(held) = self.linked.get(&key).cloned() else {
			return Err(Refusal::coded(
				FailureCode::NoSuchRoom,
				format!("this server has no room link for \"{name}\""),
			));
		};
		let mut next = self.clone();
		next.linked.remove(&key);
		next.stewards.remove(&key);
		if RecoveryKey::accepts(&held) && !next.managed.contains_key(&key) {
			next.subjects.remove(&key);
		}
		next.revoked.insert(key, held);
		Self::admitted(next)
	}
	/// Invalidate the issued steward generation. Answers the next generation.
	pub fn with_steward_revoked(&self, name: &str) -> Result<(Self, u64), Refusal> {
		let key = fold(name);
		let Some(existing) = self.stewards.get(&key).filter(|row| row.issued) else {
			return Err(Refusal::coded(
				FailureCode::NotSteward,
				format!("room \"{name}\" has no issued stewardship"),
			));
		};
		if existing.generation == MAX_SAFE {
			return Err(Refusal::plain(format!(
				"room \"{name}\" has exhausted stewardship generations"
			)));
		}
		let generation = existing.generation + 1;
		let mut next = self.clone();
		next.stewards.insert(
			key,
			Issue {
				name: existing.name.clone(),
				generation,
				issued: false,
			},
		);
		Ok((Self::admitted(next)?, generation))
	}
	pub fn with_manager_revoked(&self, name: &str) -> Result<(Self, u64), Refusal> {
		let key = fold(name);
		let Some(existing) = self.managers.get(&key).filter(|row| row.issued) else {
			return Err(Refusal::plain(format!(
				"room \"{name}\" has no current manager capability"
			)));
		};
		if existing.generation == MAX_SAFE {
			return Err(Refusal::plain(format!("room \"{name}\" exhausted manager generations")));
		}
		let generation = existing.generation + 1;
		let mut next = self.clone();
		next.managers.insert(
			key,
			Issue {
				name: existing.name.clone(),
				generation,
				issued: false,
			},
		);
		Ok((Self::admitted(next)?, generation))
	}
	/// Rotate the secret and clear every authority row, keeping the Host
	/// identity and the subjects of public rooms. Old links derive from the
	/// retired secret and can never collide with what is minted after this.
	pub fn factory_reset(&self, secret: [u8; KEY_BYTES]) -> Self {
		let mut next = self.clone();
		next.secret = secret;
		next.linked.clear();
		next.revoked.clear();
		next.generations.clear();
		next.stewards.clear();
		next.managers.clear();
		next.managed.clear();
		next.managed_by_name.clear();
		next.publications.clear();
		next.subjects.retain(|_, (name, _)| !RecoveryKey::accepts(name));
		next
	}
}
