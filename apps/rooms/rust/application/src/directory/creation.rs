//! Room-creation verbs and caller-held retry keys.
use super::Error;
use crate::fields::lower_hex;
use alloc::string::String;

pub use crate::protocol_data::{
	ADVERTISED_LOCATION as LOCATION, ENTER, ENTER_PUBLICATION, LINK, OPEN, OPEN_MANAGED,
	OPEN_PRIVATE_LINK as PRIVATE_LINK, ROOM_AUTHORITIES as AUTHORITIES,
};

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
		key.push_str(&lower_hex(&entropy));
		Self(key)
	}
	pub fn as_str(&self) -> &str {
		&self.0
	}
}
