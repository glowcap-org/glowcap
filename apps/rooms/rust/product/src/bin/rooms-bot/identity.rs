//! One owner-only document holds two independent secrets. The Host seed
//! keeps the bot's CapTP identity stable. The other 16 random bytes let the
//! bot recognize its own agent actions after their local claims retire.
use crate::bot::{error::Error, store::Store};
use hmac::{Hmac, KeyInit, Mac};
use rooms_application::archive::identity::{FILE, Identity, MAX_BYTES};
use rooms_application::fields::{Hex, lower_hex};
use rooms_platform::storage;
use sha2::Sha256;
use std::path::Path;

/// The stored seed, made on first use.
pub fn seed(store: &Store) -> Result<[u8; 32], Error> {
	if let Some(identity) = read(store.root())? {
		return Ok(*identity.seed());
	}
	for existing in ["session.link", "turns.json"] {
		if store
			.root()
			.join(existing)
			.try_exists()
			.map_err(Error::io("checking existing bot state"))?
		{
			return Err(Error::unreadable(
				FILE,
				"restore the identity belonging to this bot directory",
			));
		}
	}
	let (mut seed, mut action_key) = ([0; 32], [0; 16]);
	for bytes in [&mut seed[..], &mut action_key[..]] {
		rooms_platform::entropy::fill(bytes).map_err(|error| Error::Entropy(error.to_string()))?;
	}
	store.write_bytes(FILE, &Identity::new(seed, action_key).encode())?;
	Ok(seed)
}

fn read(root: &Path) -> Result<Option<Identity>, Error> {
	storage::read(&root.join(FILE), MAX_BYTES)?
		.map(|bytes| Identity::decode(&bytes).map_err(|error| Error::unreadable(FILE, error)))
		.transpose()
}

/// Independent of the Host seed, the peer document's other 16 random bytes
/// authenticate the bot's action IDs after their turn claims are gone.
pub struct ActionKey([u8; 16]);

pub fn action_key(root: &Path) -> Result<ActionKey, Error> {
	read(root)?
		.map(|identity| ActionKey(*identity.entropy()))
		.ok_or_else(|| Error::unreadable(FILE, "restore the identity belonging to this bot directory"))
}

/// The canonical hexadecimal nonce covered by the MAC. Its text is part of
/// the stored operation ID and must authenticate identically after an upgrade.
struct ActionNonce<'a>(&'a str);

impl ActionKey {
	fn mac(&self, nonce: ActionNonce<'_>) -> Hmac<Sha256> {
		#[expect(clippy::expect_used, reason = "HMAC accepts a 16-byte key")]
		let mut mac = Hmac::<Sha256>::new_from_slice(&self.0).expect("HMAC accepts a 16-byte key");
		mac.update(b"glowcap Rooms bot action v1\0");
		mac.update(nonce.0.as_bytes());
		mac
	}

	pub fn mint(&self) -> Result<String, Error> {
		let mut fresh = [0; 16];
		rooms_platform::entropy::fill(&mut fresh).map_err(|error| Error::Entropy(error.to_string()))?;
		let nonce = lower_hex(&fresh);
		let tag = self.mac(ActionNonce(&nonce)).finalize().into_bytes();
		Ok(format!("{nonce}-{}", lower_hex(&tag)))
	}

	pub fn owns(&self, id: &str) -> bool {
		signed_parts(id).is_some_and(|(nonce, tag)| self.mac(nonce).verify_slice(tag.bytes()).is_ok())
	}
}

pub fn new_action(root: &Path) -> Result<String, Error> {
	action_key(root)?.mint()
}

pub fn legacy_id(id: &str) -> bool {
	id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

pub fn signed_id(id: &str) -> bool {
	signed_parts(id).is_some()
}

fn signed_parts(id: &str) -> Option<(ActionNonce<'_>, Hex<32>)> {
	let (nonce, tag) = id.split_once('-')?;
	if !legacy_id(nonce) || nonce.bytes().any(|b| b.is_ascii_uppercase()) {
		return None;
	}
	use serde::Deserialize;
	let tag = Hex::deserialize(serde::de::value::StrDeserializer::<serde::de::value::Error>::new(tag)).ok()?;
	Some((ActionNonce(nonce), tag))
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	#[test]
	fn an_action_follows_its_saved_identity_and_a_missing_identity_is_not_reminted() {
		let dir = Scratch::create("bot-action-identity");
		let store = Store::open(&dir.join("first")).unwrap();
		seed(&store).unwrap();
		let id = new_action(store.root()).unwrap();
		let moved = Store::open(&dir.join("moved")).unwrap();
		std::fs::copy(store.root().join(FILE), moved.root().join(FILE)).unwrap();
		assert!(action_key(moved.root()).unwrap().owns(&id));
		let missing = Store::open(&dir.join("missing")).unwrap();
		assert!(action_key(missing.root()).is_err());
		assert!(!missing.root().join(FILE).exists());
		missing.write_bytes("turns.json", b"{}").unwrap();
		assert!(seed(&missing).is_err());
		assert!(!missing.root().join(FILE).exists());
	}
}
