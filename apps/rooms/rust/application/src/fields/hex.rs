//! One lowercase hexadecimal grammar for Rooms identifiers and documents.
use alloc::string::String;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

struct LowerHex<'a>(&'a [u8]);
impl core::fmt::Display for LowerHex<'_> {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		const DIGITS: &[u8] = b"0123456789abcdef";
		for byte in self.0 {
			let pair = [DIGITS[(byte >> 4) as usize], DIGITS[(byte & 15) as usize]];
			f.write_str(core::str::from_utf8(&pair).map_err(|_| core::fmt::Error)?)?;
		}
		Ok(())
	}
}

/// Encode bytes with the lowercase hexadecimal grammar used by Rooms identities and digests.
pub fn lower_hex(bytes: &[u8]) -> String {
	use core::fmt::Write;
	let mut text = String::with_capacity(bytes.len() * 2);
	let _ = write!(text, "{}", LowerHex(bytes));
	text
}

/// A fixed lowercase hexadecimal field. Identity and publication seeds use
/// this same document grammar as digests, but never appear in Debug output.
#[derive(Clone, PartialEq, Eq)]
pub struct Hex<const N: usize>(pub(crate) [u8; N]);
impl<const N: usize> Hex<N> {
	/// Borrow the validated fixed identity at a storage or protocol boundary.
	pub fn bytes(&self) -> &[u8; N] {
		&self.0
	}
	/// Explicit scalar encoding for independently owned document keys.
	pub fn encode(&self) -> String {
		lower_hex(&self.0)
	}
}
impl<const N: usize> Serialize for Hex<N> {
	fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		s.collect_str(&LowerHex(&self.0))
	}
}
impl<'de, const N: usize> Deserialize<'de> for Hex<N> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		struct Read<const N: usize>;
		impl<const N: usize> serde::de::Visitor<'_> for Read<N> {
			type Value = Hex<N>;
			fn expecting(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
				write!(f, "{} lowercase hex digits", N * 2)
			}
			fn visit_str<E: serde::de::Error>(self, text: &str) -> Result<Self::Value, E> {
				if text.len() != N * 2 {
					return Err(E::custom("hex length"));
				}
				let mut value = [0; N];
				for (i, byte) in text.bytes().enumerate() {
					let digit = match byte {
						b'0'..=b'9' => byte - b'0',
						b'a'..=b'f' => byte - b'a' + 10,
						_ => return Err(E::custom("lowercase hex")),
					};
					value[i / 2] = value[i / 2] * 16 + digit;
				}
				Ok(Hex(value))
			}
		}
		d.deserialize_str(Read::<N>)
	}
}
