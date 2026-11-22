//! The bot's own CapTP identity: the Host seed `serve` dials with, so the
//! session sees the same peer after a restart. It is made the way the archive
//! peer makes its identity, from platform entropy into one owner-only file,
//! and never replaces a file it cannot read.
use crate::bot::{error::Error, store::Store};
use rooms_application::archive::identity::{FILE, Identity, MAX_BYTES};
use rooms_platform::storage;

/// The stored seed, made on first use.
pub fn seed(store: &Store) -> Result<[u8; 32], Error> {
	let path = store.root().join(FILE);
	if let Some(bytes) = storage::read(&path, MAX_BYTES)? {
		let identity = Identity::decode(&bytes).map_err(|error| Error::unreadable(FILE, error))?;
		return Ok(*identity.seed());
	}
	let (mut seed, mut spare) = ([0; 32], [0; 16]);
	for bytes in [&mut seed[..], &mut spare[..]] {
		rooms_platform::entropy::fill(bytes).map_err(|error| Error::Entropy(error.to_string()))?;
	}
	store.write_bytes(FILE, &Identity::new(seed, spare).encode())?;
	Ok(seed)
}
