//! A line as it is drawn and as it is read for who it addresses. IRC carries
//! emphasis as control characters that toggle rather than delimit, so a line
//! from an IRC bridge splits into runs by the formatting in force across each.
//! Every run is then read as its own Markdown document, so Markdown cannot open
//! on one side of a toggle and close under a different style. The browser draws
//! these parts and `Mentions::of_line` searches them, which keeps one reading
//! of a bridged line for both.
use super::Document;
use alloc::{string::String, vec::Vec};
use serde::Serialize;

const BOLD: char = '\u{02}';
const COLOUR: char = '\u{03}';
const RESET: char = '\u{0F}';
const MONO: char = '\u{11}';
const REVERSE: char = '\u{16}';
const ITALIC: char = '\u{1D}';
const STRIKE: char = '\u{1E}';
const UNDERLINE: char = '\u{1F}';

/// One stretch of a line, with the emphasis in force across it. Colours stay
/// the numbers the author picked, because what a number looks like belongs to
/// the stylesheet. Reverse swaps foreground and background without resolving
/// either.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
pub struct Run {
	pub text: String,
	pub bold: bool,
	pub italic: bool,
	pub underline: bool,
	pub strike: bool,
	pub mono: bool,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub fg: Option<u8>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub bg: Option<u8>,
}

/// One drawn piece of a line. A line with no IRC formatting is one part with
/// no `irc` run. In a run, the spaces and tabs at either edge stay outside the
/// document, so indentation cannot turn a run into a code block.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Part {
	#[serde(skip_serializing_if = "Option::is_none")]
	pub irc: Option<Run>,
	pub before: String,
	pub after: String,
	pub document: Document,
}

fn formatted(text: &str) -> bool {
	text.chars()
		.any(|c| matches!(c, BOLD | COLOUR | RESET | MONO | REVERSE | ITALIC | STRIKE | UNDERLINE))
}

/// Read a line into the parts it is drawn and searched as.
#[must_use]
pub fn read(text: &str) -> Vec<Part> {
	if !formatted(text) {
		return alloc::vec![Part {
			irc: None,
			before: String::new(),
			after: String::new(),
			document: Document::read(text),
		}];
	}
	runs(text)
		.into_iter()
		.map(|run| {
			let edge = |c: char| c == ' ' || c == '\t';
			let rest = run.text.trim_start_matches(edge);
			let body = rest.trim_end_matches(edge);
			let before = String::from(run.text.strip_suffix(rest).unwrap_or_default());
			let after = String::from(rest.strip_prefix(body).unwrap_or_default());
			let document = Document::read(body);
			Part {
				irc: Some(run),
				before,
				after,
				document,
			}
		})
		.collect()
}

/// Split a line into runs. A toggle flips its own state and leaves the rest
/// alone, a reset clears them all, and a toggle left on runs to the end of the
/// line. A colour byte alone clears colour, otherwise it takes up to two digits
/// of foreground and, after a comma, up to two of background.
fn runs(text: &str) -> Vec<Run> {
	let mut runs = Vec::new();
	let mut state = Run::default();
	let mut held = String::new();
	let mut chars = text.chars().peekable();
	while let Some(c) = chars.next() {
		if !matches!(c, BOLD | COLOUR | RESET | MONO | REVERSE | ITALIC | STRIKE | UNDERLINE) {
			held.push(c);
			continue;
		}
		if !held.is_empty() {
			runs.push(Run {
				text: core::mem::take(&mut held),
				..state.clone()
			});
		}
		match c {
			BOLD => state.bold = !state.bold,
			ITALIC => state.italic = !state.italic,
			UNDERLINE => state.underline = !state.underline,
			STRIKE => state.strike = !state.strike,
			MONO => state.mono = !state.mono,
			REVERSE => core::mem::swap(&mut state.fg, &mut state.bg),
			RESET => state = Run::default(),
			_ => match digits(&mut chars) {
				None => (state.fg, state.bg) = (None, None),
				Some(fg) => {
					state.fg = Some(fg);
					let mut ahead = chars.clone();
					if ahead.next() == Some(',')
						&& let Some(bg) = digits(&mut ahead)
					{
						state.bg = Some(bg);
						chars = ahead;
					}
				}
			},
		}
	}
	if !held.is_empty() {
		runs.push(Run { text: held, ..state });
	}
	runs
}

/// One or two ASCII digits, consumed from the front of `chars`.
fn digits(chars: &mut core::iter::Peekable<core::str::Chars<'_>>) -> Option<u8> {
	let mut value = chars.peek()?.to_digit(10)?;
	chars.next();
	if let Some(next) = chars.peek().and_then(|c| c.to_digit(10)) {
		value = value * 10 + next;
		chars.next();
	}
	u8::try_from(value).ok()
}

#[cfg(test)]
mod tests {
	use super::{Run, read};

	fn runs(text: &str) -> alloc::vec::Vec<Run> {
		read(text).into_iter().filter_map(|part| part.irc).collect()
	}

	#[test]
	fn a_line_with_no_formatting_is_one_plain_part() {
		let parts = read("**bold** @zoe");
		assert_eq!(parts.len(), 1);
		assert!(parts[0].irc.is_none());
		assert!(parts[0].before.is_empty() && parts[0].after.is_empty());
	}

	#[test]
	fn toggles_nest_by_state_and_a_reset_clears_them() {
		let found = runs("\x02\x1dboth\x02still italic\x0fplain");
		let kinds: alloc::vec::Vec<_> = found.iter().map(|r| (r.text.as_str(), r.bold, r.italic)).collect();
		assert_eq!(
			kinds,
			[
				("both", true, true),
				("still italic", false, true),
				("plain", false, false)
			]
		);
	}

	#[test]
	fn a_toggle_left_on_runs_to_the_end() {
		let found = runs("\x02never closed");
		assert_eq!(found.len(), 1);
		assert!(found[0].bold);
	}

	#[test]
	fn colour_keeps_the_numbers_and_reverse_swaps_them() {
		let found = runs("\x034red\x03 plain\x034,1black\x16swapped");
		assert_eq!((found[0].fg, found[0].bg), (Some(4), None));
		assert_eq!((found[1].fg, found[1].bg), (None, None));
		assert_eq!((found[2].fg, found[2].bg), (Some(4), Some(1)));
		assert_eq!((found[3].fg, found[3].bg), (Some(1), Some(4)));
	}

	#[test]
	fn a_comma_without_a_background_digit_stays_text() {
		let found = runs("\x034,x");
		assert_eq!(found[0].text, ",x");
		assert_eq!(found[0].fg, Some(4));
	}

	#[test]
	fn edge_spaces_stay_outside_the_document() {
		let parts = read("\x02  hi \t\x02");
		assert_eq!((parts[0].before.as_str(), parts[0].after.as_str()), ("  ", " \t"));
	}

	#[test]
	fn formatting_alone_has_no_parts() {
		assert!(read("\x02\x02").is_empty());
	}
}
