//! Builds the binding's CapTP arguments for every Rooms wire shape, the write
//! side of `Value`.
use glowcap::Argument;
use rooms_application::room::{BuildArguments, DataEncoder};

/// The one builder of CapTP arguments for the Rooms wire shapes.
pub struct Arguments;
/// A wire integer carries every `u64` without loss. Values beyond `i64` take
/// the binding's arbitrary-precision form.
fn integer(value: u64) -> Argument {
	match i64::try_from(value) {
		Ok(value) => Argument::Integer(value),
		Err(_) => Argument::BigInteger {
			negative: false,
			digits: value.to_string(),
		},
	}
}
impl BuildArguments for Arguments {
	type Value = Argument;
	fn text(value: &str) -> Argument {
		Argument::String(value.into())
	}
	fn integer(value: u64) -> Argument {
		integer(value)
	}
	fn boolean(value: bool) -> Argument {
		Argument::Boolean(value)
	}
	fn null() -> Argument {
		Argument::Void
	}
	fn list(values: Vec<Argument>) -> Argument {
		Argument::List(values)
	}
}

impl DataEncoder for Arguments {
	type Value = Argument;
	fn text(&mut self, value: String) -> Argument {
		Argument::String(value)
	}
	fn integer(&mut self, value: u64) -> Argument {
		integer(value)
	}
	fn boolean(&mut self, value: bool) -> Argument {
		Argument::Boolean(value)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn integers_convert_without_loss() {
		assert!(matches!(integer(i64::MAX as u64), Argument::Integer(i64::MAX)));
		assert!(matches!(integer(0), Argument::Integer(0)));
		match integer(u64::MAX) {
			Argument::BigInteger { negative, digits } => {
				assert!(!negative);
				assert_eq!(digits, "18446744073709551615");
			}
			other => panic!("u64::MAX did not widen: {other:?}"),
		}
		assert!(matches!(
			integer(i64::MAX as u64 + 1),
			Argument::BigInteger { negative: false, .. }
		));
	}
}
