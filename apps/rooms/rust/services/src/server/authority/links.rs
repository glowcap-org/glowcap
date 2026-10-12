//! The durable names this server has published, by kind and folded name, and
//! the refusals an authority decision can give. A token is looked up by its
//! SHA-256 digest, so lookup time does not depend on how many leading bytes of
//! a guess match a real token. The text stays in the value for `published`.
use super::super::error::Error;
use rooms_application::room::stewardship::Kind;
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fmt};

/// A durable token exactly as published. Never a folded name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Swiss(String);

impl Swiss {
	pub(crate) fn as_str(&self) -> &str {
		&self.0
	}
	fn digest(text: &str) -> SwissDigest {
		SwissDigest(Sha256::digest(text.as_bytes()).into())
	}
}

impl From<String> for Swiss {
	fn from(text: String) -> Self {
		Self(text)
	}
}

impl From<Swiss> for String {
	fn from(swiss: Swiss) -> Self {
		swiss.0
	}
}

/// The case-folded key a name resolves under. Never a token.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct FoldedName(String);

impl FoldedName {
	fn of(name: &str) -> Self {
		Self(name.to_lowercase())
	}
}

/// SHA-256 of a token's text: the key tokens are looked up by.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct SwissDigest([u8; 32]);

/// Why an authority decision refused. `Display` is the exact line the caller
/// and the peer read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AuthorityRefusal {
	/// The token names a generation of `Kind` that is no longer current.
	StaleGeneration(Kind),
	/// The token is current, but for another room than the manager holds.
	DifferentRoom,
	/// No published manager derives this management identity.
	UnknownManager,
	/// The bounded identity cache is full and this name is not in it.
	IdentityCapacity,
	/// A room asked to record a management identity other than the one held.
	IdentityChanged,
	/// Two rooms derived the same management identity.
	IdentityCollision,
	/// The manager generation the caller holds was revoked.
	ManagerRevoked,
}

impl fmt::Display for AuthorityRefusal {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::StaleGeneration(kind) => write!(
				f,
				"that {} capability generation is no longer current",
				match kind {
					Kind::Room => "room link",
					Kind::Steward => "moderator",
					Kind::Manager => "manager",
				}
			),
			Self::DifferentRoom => f.write_str("that authority token belongs to a different room"),
			Self::UnknownManager => f.write_str("that room management identity is not known to this directory"),
			Self::IdentityCapacity => f.write_str("room management identity capacity reached"),
			Self::IdentityChanged => f.write_str("a room changed its stable management identity"),
			Self::IdentityCollision => f.write_str("two rooms derived the same management identity"),
			Self::ManagerRevoked => f.write_str("this room manager capability was revoked"),
		}
	}
}

impl std::error::Error for AuthorityRefusal {}

impl From<AuthorityRefusal> for String {
	fn from(refusal: AuthorityRefusal) -> Self {
		refusal.to_string()
	}
}

impl From<AuthorityRefusal> for Error {
	fn from(refusal: AuthorityRefusal) -> Self {
		Error::refused(refusal.to_string())
	}
}

/// The durable names this server has published, by kind and folded name.
#[derive(Default)]
pub(crate) struct Links {
	room: BTreeMap<FoldedName, Swiss>,
	steward: BTreeMap<FoldedName, Swiss>,
	manager: BTreeMap<FoldedName, Swiss>,
	/// Keyed by the token's digest. The value keeps the kind, the name as
	/// published, and the token text.
	by_swiss: BTreeMap<SwissDigest, (Kind, String, Swiss)>,
	identity_by_name: BTreeMap<FoldedName, String>,
	name_by_identity: BTreeMap<String, String>,
}

impl Links {
	fn table(&self, kind: Kind) -> &BTreeMap<FoldedName, Swiss> {
		match kind {
			Kind::Room => &self.room,
			Kind::Steward => &self.steward,
			Kind::Manager => &self.manager,
		}
	}
	fn table_mut(&mut self, kind: Kind) -> &mut BTreeMap<FoldedName, Swiss> {
		match kind {
			Kind::Room => &mut self.room,
			Kind::Steward => &mut self.steward,
			Kind::Manager => &mut self.manager,
		}
	}
	pub fn swiss(&self, kind: Kind, name: &str) -> Option<&str> {
		self.table(kind).get(&FoldedName::of(name)).map(Swiss::as_str)
	}
	/// Every published name of `kind` with its current swiss.
	pub fn published(&self, kind: Kind) -> impl Iterator<Item = (String, String)> + '_ {
		self.by_swiss
			.values()
			.filter(move |(held, _, _)| *held == kind)
			.map(|(_, name, swiss)| (name.clone(), swiss.0.clone()))
	}
	pub(super) fn set(&mut self, kind: Kind, name: &str, swiss: Swiss) {
		let digest = Swiss::digest(&swiss.0);
		if let Some(previous) = self.table_mut(kind).insert(FoldedName::of(name), swiss.clone()) {
			self.by_swiss.remove(&Swiss::digest(&previous.0));
		}
		self.by_swiss.insert(digest, (kind, name.into(), swiss));
	}
	pub(super) fn drop(&mut self, kind: Kind, name: &str) -> Option<Swiss> {
		let swiss = self.table_mut(kind).remove(&FoldedName::of(name))?;
		self.by_swiss.remove(&Swiss::digest(&swiss.0));
		Some(swiss)
	}
	/// The name a current token stands for, when it is the current
	/// generation of that kind.
	pub fn resolve(&self, kind: Kind, token: &str) -> Result<String, AuthorityRefusal> {
		match self.by_swiss.get(&Swiss::digest(token)) {
			Some((held, name, _)) if *held == kind => Ok(name.clone()),
			_ => Err(AuthorityRefusal::StaleGeneration(kind)),
		}
	}
	/// Knowledge of a current token does not extend a held manager's room.
	pub(super) fn resolve_for(&self, kind: Kind, token: &str, room: &str) -> Result<String, AuthorityRefusal> {
		let resolved = self.resolve(kind, token)?;
		if FoldedName::of(&resolved) != FoldedName::of(room) {
			return Err(AuthorityRefusal::DifferentRoom);
		}
		Ok(resolved)
	}
	pub(crate) fn manager_name(&self, identity: &str) -> Result<&str, AuthorityRefusal> {
		self.name_by_identity
			.get(identity)
			.map(String::as_str)
			.ok_or(AuthorityRefusal::UnknownManager)
	}

	/// A live baseline room can name its management identity before it becomes
	/// durable. Bound these optional lookups without refusing restoration or
	/// publication of the separately bounded durable manager registry.
	pub(crate) fn cache_identity(&mut self, name: &str, identity: String) -> Result<(), AuthorityRefusal> {
		if self.identity_by_name.len() >= rooms_application::server::document::MAX_ROOM_LINKS
			&& !self.identity_by_name.contains_key(&FoldedName::of(name))
		{
			return Err(AuthorityRefusal::IdentityCapacity);
		}
		self.set_identity(name, identity)
	}

	pub(super) fn set_identity(&mut self, name: &str, identity: String) -> Result<(), AuthorityRefusal> {
		let key = FoldedName::of(name);
		if self.identity_by_name.get(&key).is_some_and(|held| *held != identity) {
			return Err(AuthorityRefusal::IdentityChanged);
		}
		if self
			.name_by_identity
			.get(&identity)
			.is_some_and(|held| FoldedName::of(held) != key)
		{
			return Err(AuthorityRefusal::IdentityCollision);
		}
		self.identity_by_name.insert(key, identity.clone());
		self.name_by_identity.insert(identity, name.into());
		Ok(())
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_token_resolves_by_digest_and_a_near_miss_does_not() {
		let mut links = Links::default();
		links.set(
			Kind::Room,
			"Garden",
			Swiss::from("abcdefghijklmnopqrstuvwxyz012345".to_string()),
		);
		assert_eq!(
			links.resolve(Kind::Room, "abcdefghijklmnopqrstuvwxyz012345").unwrap(),
			"Garden"
		);
		assert_eq!(
			links.resolve(Kind::Room, "abcdefghijklmnopqrstuvwxyz012346"),
			Err(AuthorityRefusal::StaleGeneration(Kind::Room))
		);
		assert_eq!(
			links.resolve(Kind::Steward, "abcdefghijklmnopqrstuvwxyz012345"),
			Err(AuthorityRefusal::StaleGeneration(Kind::Steward))
		);
		assert_eq!(
			links.swiss(Kind::Room, "garden"),
			Some("abcdefghijklmnopqrstuvwxyz012345")
		);
	}

	#[test]
	fn replacing_a_name_retires_the_previous_token() {
		let mut links = Links::default();
		links.set(Kind::Manager, "garden", Swiss::from("first".to_string()));
		links.set(Kind::Manager, "GARDEN", Swiss::from("second".to_string()));
		assert!(links.resolve(Kind::Manager, "first").is_err());
		// The name resolves as the replacement published it; folding is for the key only.
		assert_eq!(links.resolve(Kind::Manager, "second").unwrap(), "GARDEN");
		assert_eq!(links.published(Kind::Manager).count(), 1);
		assert_eq!(
			links.drop(Kind::Manager, "Garden").map(String::from),
			Some("second".to_string())
		);
		assert!(links.published(Kind::Manager).next().is_none());
	}

	#[test]
	fn refusal_text_is_the_line_the_peer_reads() {
		assert_eq!(
			AuthorityRefusal::StaleGeneration(Kind::Steward).to_string(),
			"that moderator capability generation is no longer current"
		);
		assert_eq!(
			String::from(AuthorityRefusal::DifferentRoom),
			"that authority token belongs to a different room"
		);
	}
}
