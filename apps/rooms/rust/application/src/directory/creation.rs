use super::Error;
use alloc::string::String;

pub const OPEN: &str = "open";
pub const OPEN_MANAGED: &str = "openManaged";
pub const AUTHORITIES: &str = "roomAuthorities";
pub const PRIVATE_LINK: &str = "openPrivateLink";
pub const ENTER: &str = "enter";
pub const ENTER_PUBLICATION: &str = "enterPublication";
pub const LINK: &str = "link";
pub const LOCATION: &str = "advertisedLocation";

/// A caller-held recovery key must survive an uncertain creation result.
/// Reusing it retries that creation; generating a new one requests a new room.
pub struct RecoveryKey(String);
impl RecoveryKey {
	pub fn accepts(value: &str) -> bool {
		value.len() == 33
			&& value.starts_with('~')
			&& value.as_bytes()[1..]
				.iter()
				.all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
	}
	pub fn parse(value: String) -> Result<Self, Error> {
		if Self::accepts(&value) {
			Ok(Self(value))
		} else {
			Err(Error::RecoveryKey)
		}
	}
	/// A fresh key from caller-supplied entropy, in the one form `accepts`.
	pub fn from_entropy(entropy: [u8; 16]) -> Self {
		let mut key = alloc::string::String::with_capacity(33);
		key.push('~');
		for byte in entropy {
			key.push(HEX[(byte >> 4) as usize] as char);
			key.push(HEX[(byte & 0x0f) as usize] as char);
		}
		Self(key)
	}
	pub fn as_str(&self) -> &str {
		&self.0
	}
}

const HEX: &[u8; 16] = b"0123456789abcdef";
