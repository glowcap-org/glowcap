//! An invitation's retry receipt belongs to its claimant, across observations.
use alloc::string::String;

pub const MINT: &str = "mintInvitation";
pub const CLAIM: &str = "claimInvitation";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Entropy,
	Invitation,
	Entrance,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Entropy => "could not obtain randomness for an invitation claim",
			Self::Invitation => "the membership answered without an invitation capability",
			Self::Entrance => "the room invitation answered without an entrance capability",
		})
	}
}
impl core::error::Error for Error {}

/// Construct once from 128 bits of platform entropy. A failed or cancelled
/// claim must reuse this exact receipt; another receipt competes for authority.
/// The receipt is intentionally neither Debug nor serializable.
pub struct Receipt(String);
impl Receipt {
	pub fn from_entropy(bytes: [u8; 16]) -> Self {
		const HEX: &[u8; 16] = b"0123456789abcdef";
		let mut text = String::with_capacity(32);
		for byte in bytes {
			text.push(HEX[(byte >> 4) as usize] as char);
			text.push(HEX[(byte & 15) as usize] as char);
		}
		Self(text)
	}
	pub fn as_str(&self) -> &str {
		&self.0
	}
}
