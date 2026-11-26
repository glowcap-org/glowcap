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
pub fn action_key(root: &Path) -> Result<[u8; 16], Error> {
	read(root)?
		.map(|identity| *identity.entropy())
		.ok_or_else(|| Error::unreadable(FILE, "restore the identity belonging to this bot directory"))
}

fn mac(key: &[u8; 16], nonce: &str) -> Hmac<Sha256> {
	#[expect(clippy::expect_used, reason = "HMAC accepts a 16-byte key")]
	let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts a 16-byte key");
	mac.update(b"glowcap Rooms bot action v1\0");
	mac.update(nonce.as_bytes());
	mac
}

pub fn new_action(root: &Path) -> Result<String, Error> {
	let key = action_key(root)?;
	let mut nonce = [0; 16];
	rooms_platform::entropy::fill(&mut nonce).map_err(|error| Error::Entropy(error.to_string()))?;
	Ok(sign(&key, &lower_hex(&nonce)))
}

pub fn sign(key: &[u8; 16], nonce: &str) -> String {
	format!("{nonce}-{}", lower_hex(&mac(key, nonce).finalize().into_bytes()))
}

pub fn legacy_id(id: &str) -> bool {
	id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

pub fn signed_id(id: &str) -> Option<(&str, Hex<32>)> {
	let (nonce, tag) = id.split_once('-')?;
	if !legacy_id(nonce) || nonce.bytes().chain(tag.bytes()).any(|b| b.is_ascii_uppercase()) {
		return None;
	}
	use serde::Deserialize;
	let tag = Hex::deserialize(serde::de::value::StrDeserializer::<serde::de::value::Error>::new(tag)).ok()?;
	Some((nonce, tag))
}

pub fn owns_action(key: &[u8; 16], id: &str) -> bool {
	signed_id(id).is_some_and(|(nonce, tag)| mac(key, nonce).verify_slice(tag.bytes()).is_ok())
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
		assert!(owns_action(&action_key(moved.root()).unwrap(), &id));
		let missing = Store::open(&dir.join("missing")).unwrap();
		assert!(action_key(missing.root()).is_err());
		assert!(!missing.root().join(FILE).exists());
		missing.write_bytes("turns.json", b"{}").unwrap();
		assert!(seed(&missing).is_err());
		assert!(!missing.root().join(FILE).exists());
	}
}
