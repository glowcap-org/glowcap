//! Lossless argument slicing. Normal scalar input remains on the UTF-8 path.
use crate::text::{DocumentText, js_whitespace};
use alloc::{format, vec::Vec};
use serde::Serialize;

pub(super) fn trimmed(text: &DocumentText) -> DocumentText {
	let mut text = text.clone();
	text.trim_js();
	text
}
pub(super) fn empty(text: &DocumentText) -> bool {
	text.utf16().next().is_none()
}
pub(super) fn decorate(prefix: &str, text: &DocumentText, suffix: &str) -> DocumentText {
	if let Some(text) = text.as_str() {
		return format!("{prefix}{text}{suffix}").into();
	}
	DocumentText::from_utf16(
		&prefix
			.encode_utf16()
			.chain(text.utf16())
			.chain(suffix.encode_utf16())
			.collect::<Vec<_>>(),
	)
}
pub(super) fn slice(text: &DocumentText, start: usize, end: usize) -> DocumentText {
	if let Some(scalar) = text.as_str() {
		let mut units = 0;
		let mut begin = scalar.len();
		let mut finish = scalar.len();
		for (at, c) in scalar.char_indices() {
			if units == start {
				begin = at;
			}
			if units == end {
				finish = at;
				break;
			}
			units += c.len_utf16();
		}
		return scalar[begin..finish].into();
	}
	DocumentText::from_utf16(
		&text
			.utf16()
			.skip(start)
			.take(end.saturating_sub(start))
			.collect::<Vec<_>>(),
	)
}
pub(super) fn strip(text: &DocumentText, marker: u8) -> DocumentText {
	if text.utf16().next() != Some(u16::from(marker)) {
		return text.clone();
	}
	slice(text, 1, usize::MAX)
}
pub(super) fn person(text: &DocumentText) -> DocumentText {
	let text = strip(text, b'@');
	let end = text.utf16().take_while(|&unit| !super::white(unit)).count();
	slice(&text, 0, end)
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Join {
	Name { name: DocumentText },
	Link { link: DocumentText, label: DocumentText },
}
/// A pasted `/link` answer may include prose before its URI. Recognition is
/// deliberately separate from route validation and capability enlivenment.
pub fn join(text: &DocumentText) -> Option<Join> {
	let text = trimmed(text);
	if empty(&text) {
		return None;
	}
	let scalar = text.utf8_lossy();
	let mut cursor = 0;
	while let Some(relative) = scalar.as_bytes()[cursor..]
		.windows(8)
		.position(|w| w.eq_ignore_ascii_case(b"ocapn://"))
	{
		let start = cursor + relative;
		let end = scalar[start..]
			.char_indices()
			.find(|(_, c)| js_whitespace(*c))
			.map_or(scalar.len(), |(at, _)| start + at);
		let uri = &scalar[start..end];
		if uri
			.as_bytes()
			.windows(3)
			.enumerate()
			.any(|(at, w)| w.eq_ignore_ascii_case(b"/s/") && at + 3 < uri.len())
		{
			let start_units = scalar[..start].encode_utf16().count();
			let end_units = scalar[..end].encode_utf16().count();
			return Some(Join::Link {
				link: slice(&text, start_units, end_units),
				label: trimmed(&slice(&text, end_units, usize::MAX)),
			});
		}
		// Skip the inspected token, so multiple non-sturdy locators before a
		// pasted entry link are scanned once rather than rescanning suffixes.
		cursor = end;
	}
	if scalar.contains("/s/") {
		let end = text.utf16().take_while(|&unit| !super::white(unit)).count();
		return Some(Join::Link {
			link: slice(&text, 0, end),
			label: trimmed(&slice(&text, end, usize::MAX)),
		});
	}
	let name = strip(&text, b'#');
	(!empty(&name)).then_some(Join::Name { name })
}
