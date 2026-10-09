//! Borrowed Rooms protocol views over the existing glowcap Rust binding.
//! Shared by services and browser Wasm; platform adapters own I/O.

pub mod archive;
pub mod client;
#[cfg(feature = "loam")]
pub mod policy;
pub mod routes;
pub mod snapshot;

use glowcap::{Argument, Ref};
use rooms_application::{
	files::FileArgument,
	room::{ArgumentView, attachment::AttachmentArgument},
};

/// Rooms peers offer the glowcap-next profile and full optional feature set. The
/// binding negotiates the supported intersection, including the interop floor.
/// Application hosts must share this posture so identity routes survive across
/// directory, session, archive and browser connections.
pub fn host_options() -> glowcap::HostOptions {
	glowcap::HostOptions {
		features: glowcap::FeatureSet::FULL,
		..glowcap::HostOptions::with_profile(glowcap::HostProfile::Native)
	}
}

/// A view keeps custody with the binding's original delivered argument. Only
/// an admitted attachment clones its capability guard; no numeric lookup exists.
#[derive(Clone, Copy)]
pub struct Value<'a>(pub &'a Argument);
impl rooms_application::room::authority::Reply for Value<'_> {
	fn text(&self) -> Option<&str> {
		self.0.as_str()
	}
	fn list_len(&self) -> Option<usize> {
		self.0.as_list().map(<[Argument]>::len)
	}
	fn list_text(&self, index: usize) -> Option<&str> {
		self.0.as_list()?.get(index)?.as_str()
	}
}
impl rooms_application::room::ListArgument for Value<'_> {
	fn list_len(&self) -> Option<usize> {
		self.0.as_list().map(<[Argument]>::len)
	}
	fn at(&self, index: usize) -> Option<Self> {
		self.0.as_list()?.get(index).map(Self)
	}
}

pub fn values(args: &[Argument]) -> impl ExactSizeIterator<Item = Value<'_>> {
	args.iter().map(Value)
}

/// Project application-owned mutation data into binding values. Capability
/// arguments come exclusively from the executor's retained target custody.
pub fn effect_argument(value: rooms_application::session::effect::Argument) -> Argument {
	use rooms_application::session::effect::Argument as Data;
	match value {
		Data::Text(value) => Argument::String(value),
		Data::Integer(value) => Argument::Integer(value),
		Data::List(values) => Argument::List(values.into_iter().map(effect_argument).collect()),
	}
}

impl ArgumentView for Value<'_> {
	fn boolean(&self) -> Option<bool> {
		self.0.as_bool()
	}
	fn is_null(&self) -> bool {
		matches!(self.0, Argument::Void)
	}
	fn text(&self) -> Option<&str> {
		self.0.as_str()
	}
	fn integer(&self) -> Option<i128> {
		match self.0 {
			Argument::Integer(value) => Some(*value as i128),
			Argument::BigInteger { negative, digits } => {
				// Negative accumulation also admits i128::MIN without allocating a
				// signed copy of the decimal magnitude.
				let mut number = 0i128;
				for digit in digits.bytes() {
					let digit = digit.checked_sub(b'0').filter(|v| *v < 10)? as i128;
					number = number.checked_mul(10)?;
					number = if *negative {
						number.checked_sub(digit)?
					} else {
						number.checked_add(digit)?
					};
				}
				Some(number)
			}
			_ => None,
		}
	}
	fn float(&self) -> Option<f64> {
		self.0.as_f64()
	}
	fn contains_capability(&self) -> bool {
		match self.0 {
			Argument::Reference(_) => true,
			Argument::List(items) | Argument::Set(items) | Argument::Tagged { value: items, .. } => {
				values(items).any(|v| v.contains_capability())
			}
			Argument::Struct(fields) => fields.iter().any(|(_, v)| Value(v).contains_capability()),
			_ => false,
		}
	}
}

impl FileArgument for Value<'_> {
	fn bytes(&self) -> Option<&[u8]> {
		self.0.as_bytes()
	}
	fn natural(&self) -> Option<u64> {
		match self.0 {
			Argument::Integer(value) => u64::try_from(*value).ok(),
			Argument::BigInteger {
				negative: false,
				digits,
			} => {
				let mut number = 0u64;
				for digit in digits.bytes() {
					let digit = digit.checked_sub(b'0').filter(|v| *v < 10)? as u64;
					number = number.saturating_mul(10).saturating_add(digit);
				}
				Some(number)
			}
			_ => None,
		}
	}
}

impl AttachmentArgument for Value<'_> {
	type Capability = Ref;
	fn capability(&self) -> Option<&Ref> {
		match self.0 {
			Argument::Reference(cap) => Some(cap),
			_ => None,
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn integer_views_preserve_wire_kind_and_signed_boundaries() {
		for (decimal, negative, expected) in [
			("9223372036854775808", false, Some(9223372036854775808)),
			("170141183460469231731687303715884105727", false, Some(i128::MAX)),
			("170141183460469231731687303715884105728", true, Some(i128::MIN)),
			("170141183460469231731687303715884105728", false, None),
			("170141183460469231731687303715884105729", true, None),
		] {
			let value = Argument::BigInteger {
				negative,
				digits: decimal.into(),
			};
			assert_eq!(Value(&value).integer(), expected);
			if negative {
				assert_eq!(Value(&value).natural(), None);
			}
		}
		let maximum = Argument::BigInteger {
			negative: false,
			digits: u64::MAX.to_string(),
		};
		assert_eq!(Value(&maximum).natural(), Some(u64::MAX));
		let beyond = Argument::BigInteger {
			negative: false,
			digits: "9".repeat(80),
		};
		assert_eq!(Value(&beyond).natural(), Some(u64::MAX));
		assert_eq!(Value(&Argument::Integer(-1)).natural(), None);
		assert_eq!(Value(&Argument::Float(1.0)).integer(), None);
		assert_eq!(Value(&Argument::Float(1.0)).natural(), None);
	}
}
