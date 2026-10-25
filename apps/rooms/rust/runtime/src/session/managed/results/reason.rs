//! Formatting stops at the durable diagnostic bound before retaining text.
use rooms_application::content::session::custody::MAX_OBSERVATION_REASON_UNITS;
use std::fmt::{self, Write};

struct Diagnostic {
	text: String,
	units: usize,
	truncated: bool,
}
impl Write for Diagnostic {
	fn write_str(&mut self, text: &str) -> fmt::Result {
		let mut end = text.len();
		for (offset, character) in text.char_indices() {
			let units = character.len_utf16();
			if self.units + units > MAX_OBSERVATION_REASON_UNITS {
				end = offset;
				self.truncated = true;
				break;
			}
			self.units += units;
		}
		self.text
			.push_str(text.split_at_checked(end).map_or(text, |(head, _)| head));
		if self.truncated { Err(fmt::Error) } else { Ok(()) }
	}
}

pub(super) fn format(error: &glowcap::Error) -> String {
	let mut diagnostic = Diagnostic {
		text: String::new(),
		units: 0,
		truncated: false,
	};
	if write!(&mut diagnostic, "{error}").is_err() {
		assert!(
			diagnostic.truncated,
			"error formatting failed before reaching its bound"
		);
	}
	diagnostic.text
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn diagnostic_bounds_utf16_and_retained_capacity_before_formatting_large_errors() {
		for character in ['a', '界', '🦉'] {
			let error = glowcap::loam::refusal(character.to_string().repeat(1 << 18));
			let reason = format(&error);
			assert!(!reason.is_empty());
			assert!(reason.encode_utf16().count() <= MAX_OBSERVATION_REASON_UNITS);
			assert!(reason.capacity() <= 6 * MAX_OBSERVATION_REASON_UNITS);
		}
	}
}
