//! The peer seed and archive publication entropy are one durable identity.
//! There is no Debug representation for authority-bearing bytes.
use crate::fields::{Hex, SafeInteger};
use alloc::vec::Vec;
use serde::{Deserialize, Serialize};
pub const FILE: &str = "peer.json";
pub const MAX_BYTES: usize = 4096;
/// An archive account's recording identity creates no peer or publication.
#[derive(Serialize, Deserialize)]
#[serde(transparent)]
pub struct RecordingIdentity(Hex<16>);
impl RecordingIdentity {
	pub fn new(entropy: [u8; 16]) -> Self {
		Self(Hex(entropy))
	}
	pub fn source(&self) -> crate::text::DocumentText {
		#[expect(
			clippy::expect_used,
			reason = "a 16-byte hex newtype has no failing serialization arm"
		)]
		let encoded = serde_json::to_string(self).expect("fixed recording identity");
		#[expect(clippy::expect_used, reason = "serde_json always quotes a string")]
		let inner = encoded
			.strip_prefix('"')
			.and_then(|quoted| quoted.strip_suffix('"'))
			.expect("a JSON string is quoted");
		inner.into()
	}
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
	version: u8,
	identity_seed: Hex<32>,
	archive_entropy: Hex<16>,
}
impl Identity {
	pub fn new(seed: [u8; 32], entropy: [u8; 16]) -> Self {
		Self {
			version: 1,
			identity_seed: Hex(seed),
			archive_entropy: Hex(entropy),
		}
	}
	pub fn seed(&self) -> &[u8; 32] {
		&self.identity_seed.0
	}
	pub fn entropy(&self) -> &[u8; 16] {
		&self.archive_entropy.0
	}
	pub fn decode(bytes: &[u8]) -> Result<Self, super::Error> {
		#[derive(Deserialize)]
		#[serde(deny_unknown_fields, rename_all = "camelCase")]
		struct Raw {
			version: SafeInteger,
			identity_seed: Hex<32>,
			archive_entropy: Hex<16>,
		}
		if bytes.len() > MAX_BYTES {
			return Err(super::Error::Document);
		}
		let text = core::str::from_utf8(bytes).map_err(|_| super::Error::Document)?;
		let raw: Raw =
			serde_json::from_str(text.strip_prefix('\u{feff}').unwrap_or(text)).map_err(|_| super::Error::Document)?;
		if raw.version.get() != 1 {
			return Err(super::Error::Document);
		}
		Ok(Self {
			version: 1,
			identity_seed: raw.identity_seed,
			archive_entropy: raw.archive_entropy,
		})
	}
	pub fn encode(&self) -> Vec<u8> {
		#[expect(
			clippy::expect_used,
			reason = "three fixed integer and byte fields have no failing serialization arm"
		)]
		let mut bytes = serde_json::to_vec(self).expect("fixed identity fields serialize");
		bytes.push(b'\n');
		bytes
	}
}
