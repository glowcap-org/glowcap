//! Command input is application syntax. Resulting effects still require live
//! session authority. Rendering consumes the catalog and performs view gestures.
pub mod catalog;
pub mod composer;
pub mod input;
pub mod interpret;
use crate::text::{DocumentText, js_whitespace};
use alloc::string::String;
use catalog::Name;
use serde::Serialize;

/// Offset into the original UTF-16 input. Reading a command does not copy its
/// possibly large argument or change isolated surrogates in a retained draft.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Read {
	pub name: &'static str,
	pub rest_start: usize,
}

pub fn read(text: &DocumentText) -> Option<Read> {
	let mut units = text.utf16().enumerate().peekable();
	if units.next()?.1 != u16::from(b'/') {
		return None;
	}
	// The vocabulary bounds the command token. Text that names no command is
	// ordinary text here, and `unknown` below says which of it the composer
	// refuses instead.
	let mut name = [0u8; 64];
	let mut length = 0;
	while let Some(&(_, unit)) = units.peek() {
		if unit > 127 || !(unit as u8).is_ascii_alphanumeric() && !matches!(unit as u8, b'_' | b'?') {
			break;
		}
		if length == name.len() {
			return None;
		}
		name[length] = unit as u8;
		length += 1;
		units.next();
	}
	let name = Name::parse(core::str::from_utf8(&name[..length]).ok()?)?;
	let mut rest_start = length + 1;
	if units.peek().is_some_and(|&(_, unit)| !white(unit)) {
		return None;
	}
	while let Some(&(at, unit)) = units.peek() {
		if !white(unit) {
			break;
		}
		rest_start = at + 1;
		units.next();
	}
	Some(Read {
		name: name.definition().name,
		rest_start,
	})
}

/// The command a line tries to name when the catalog has none: a slash, two
/// or more ASCII letters, then whitespace or the end. `/etc/hosts`, `/1`, and
/// a lone `/` are ordinary text. A typo such as `/ignored` is refused by the
/// composer rather than said to the room.
pub fn unknown(text: &DocumentText) -> Option<String> {
	let mut units = text.utf16();
	if units.next()? != u16::from(b'/') {
		return None;
	}
	let mut token = String::new();
	for unit in units {
		if white(unit) {
			break;
		}
		if unit > 127 || !(unit as u8).is_ascii_alphabetic() || token.len() == 64 {
			return None;
		}
		token.push(char::from(unit as u8));
	}
	if token.len() < 2 || Name::parse(&token).is_some() {
		return None;
	}
	Some(token)
}

fn white(unit: u16) -> bool {
	char::from_u32(u32::from(unit)).is_some_and(js_whitespace)
}
