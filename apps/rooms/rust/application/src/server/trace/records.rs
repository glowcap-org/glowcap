//! What a producer may say to the live timeline: one JSON object per line,
//! of a kind the schema names, with only the fields that kind allows and
//! every one bounded. Anything else is refused whole, because a viewer
//! commits what the endpoint forwards.
use super::{MAX_FIELD_BYTES, MAX_LINE_BYTES};
use alloc::{string::String, vec::Vec};
use serde_json::{Map, Value};

pub const OPENED: &str = "ocapn.session-opened";
pub const MESSAGE: &str = "ocapn.message-decoded";
pub const CLOSED: &str = "ocapn.session-closed";
pub const META: &str = "ocapn.session-meta";
pub const KINDS: [&str; 4] = [OPENED, MESSAGE, CLOSED, META];

fn allowed(kind: &str) -> &'static [&'static str] {
	match kind {
		OPENED => &[
			"v",
			"sim_t_ns",
			"kind",
			"session",
			"a",
			"a_label",
			"a_profile",
			"b",
			"transport",
			"session_id",
			"provenance",
			"codec",
			"captp_version",
			"dropped",
		],
		MESSAGE => &[
			"v",
			"sim_t_ns",
			"kind",
			"session",
			"outbound",
			"op",
			"digest",
			"len",
			"bytes_b64",
			"summary",
			"dropped",
		],
		CLOSED => &["v", "sim_t_ns", "kind", "session", "dropped"],
		META => &["v", "sim_t_ns", "kind", "session", "meta"],
		_ => &[],
	}
}

fn bounded_string(value: Option<&Value>, required: bool) -> bool {
	match value {
		Some(Value::String(text)) => (!required || !text.is_empty()) && text.len() <= MAX_FIELD_BYTES,
		Some(_) => false,
		None => !required,
	}
}

fn non_negative_integer(value: &Value) -> bool {
	value.as_u64().is_some_and(|n| n < (1u64 << 53))
}

fn non_negative_number(value: &Value) -> bool {
	value.as_f64().is_some_and(|n| n.is_finite() && n >= 0.0)
}

fn base64_value(byte: u8) -> Option<u8> {
	Some(match byte {
		b'A'..=b'Z' => byte - b'A',
		b'a'..=b'z' => byte - b'a' + 26,
		b'0'..=b'9' => byte - b'0' + 52,
		b'+' => 62,
		b'/' => 63,
		_ => return None,
	})
}

/// The decoded length of canonical RFC 4648 base64, or `None` for text that
/// is not that: wrong length, a stray character, or padding that leaves set
/// bits beyond the decoded bytes.
pub fn base64_decoded_length(text: &str) -> Option<usize> {
	let bytes = text.as_bytes();
	if bytes.is_empty() {
		return Some(0);
	}
	if !bytes.len().is_multiple_of(4) {
		return None;
	}
	let padding = bytes.iter().rev().take(2).take_while(|byte| **byte == b'=').count();
	let data = bytes.len() - padding;
	if bytes[..data].iter().any(|byte| base64_value(*byte).is_none()) {
		return None;
	}
	let last = base64_value(bytes[data - 1])?;
	if padding == 2 && last & 0x0f != 0 {
		return None;
	}
	if padding == 1 && last & 0x03 != 0 {
		return None;
	}
	Some(bytes.len() / 4 * 3 - padding)
}

fn valid_common(rec: &Map<String, Value>, kind: &str) -> bool {
	if rec.get("v") != Some(&Value::from(1)) {
		return false;
	}
	if !rec.get("sim_t_ns").is_some_and(non_negative_number) {
		return false;
	}
	if !bounded_string(rec.get("session"), true) {
		return false;
	}
	if rec.get("dropped").is_some_and(|dropped| !non_negative_integer(dropped)) {
		return false;
	}
	let allowed = allowed(kind);
	rec.keys().all(|field| allowed.contains(&field.as_str()))
}

fn hex_of(text: &str, len: usize) -> bool {
	text.len() == len && text.bytes().all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
}

fn valid_opened(rec: &Map<String, Value>) -> bool {
	if !bounded_string(rec.get("a"), true)
		|| !bounded_string(rec.get("b"), true)
		|| !bounded_string(rec.get("transport"), true)
	{
		return false;
	}
	if !bounded_string(rec.get("a_label"), false) || !bounded_string(rec.get("a_profile"), false) {
		return false;
	}
	if let Some(id) = rec.get("session_id")
		&& !id.as_str().is_some_and(|id| hex_of(id, 64))
	{
		return false;
	}
	let one_of = |field: &str, words: &[&str]| match rec.get(field) {
		None => true,
		Some(Value::String(word)) => words.contains(&word.as_str()),
		Some(_) => false,
	};
	one_of("codec", &["syrup", "capnp"])
		&& one_of("captp_version", &["1.0", "glowcap-next"])
		&& one_of("provenance", &["authenticated-transport", "unauthenticated"])
}

fn valid_message(rec: &Map<String, Value>) -> bool {
	if !rec.get("outbound").is_some_and(Value::is_boolean) {
		return false;
	}
	if !bounded_string(rec.get("op"), false) {
		return false;
	}
	if !rec
		.get("digest")
		.and_then(Value::as_str)
		.is_some_and(|digest| hex_of(digest, 32))
	{
		return false;
	}
	let len = match rec.get("len") {
		None => None,
		Some(len) if non_negative_integer(len) => len.as_u64(),
		Some(_) => return false,
	};
	// Payload text is bounded by the aggregate line budget: 4096 captured
	// bytes need more base64 than the ordinary field cap allows.
	if let Some(bytes) = rec.get("bytes_b64") {
		let (Some(bytes), Some(len)) = (bytes.as_str(), len) else {
			return false;
		};
		if base64_decoded_length(bytes).is_none_or(|decoded| decoded as u64 != len) {
			return false;
		}
		if rec.contains_key("summary") {
			return false;
		}
	}
	let Some(summary) = rec.get("summary") else {
		return true;
	};
	let Some(summary) = summary.as_object() else {
		return false;
	};
	if summary.keys().any(|field| field != "len" && field != "head_b64") {
		return false;
	}
	let Some(summary_len) = summary
		.get("len")
		.filter(|len| non_negative_integer(len))
		.and_then(Value::as_u64)
	else {
		return false;
	};
	if Some(summary_len) != len {
		return false;
	}
	summary
		.get("head_b64")
		.and_then(Value::as_str)
		.and_then(base64_decoded_length)
		.is_some_and(|head| head as u64 <= summary_len)
}

fn valid_meta(rec: &Map<String, Value>) -> bool {
	let Some(meta) = rec.get("meta").and_then(Value::as_object) else {
		return false;
	};
	if meta.keys().any(|field| field != "label") {
		return false;
	}
	match meta.get("label") {
		None | Some(Value::Null) => true,
		label => bounded_string(label, false),
	}
}

/// Admit only a bounded record of a kind the schema names. The producer's
/// `seq`, `epoch`, and `replay` are stripped first: those are the
/// endpoint's to stamp.
pub fn parse_record(line: &str) -> Option<Map<String, Value>> {
	if line.len() > MAX_LINE_BYTES {
		return None;
	}
	let Value::Object(mut rec) = serde_json::from_str::<Value>(line).ok()? else {
		return None;
	};
	let kind = rec.get("kind")?.as_str()?;
	if !KINDS.contains(&kind) {
		return None;
	}
	let kind = String::from(kind);
	rec.remove("seq");
	rec.remove("epoch");
	rec.remove("replay");
	if !valid_common(&rec, &kind) {
		return None;
	}
	let valid = match kind.as_str() {
		OPENED => valid_opened(&rec),
		MESSAGE => valid_message(&rec),
		META => valid_meta(&rec),
		_ => true,
	};
	valid.then_some(rec)
}

/// The lines a (re)connecting viewer replays: every still-live session's
/// open and, when set, its latest annotation, in `seq` order, each marked
/// `replay: true` by a prefix splice into the stored line.
pub fn replay_lines<'a>(
	opens: impl Iterator<Item = (u64, &'a str)>,
	metas: impl Iterator<Item = (u64, &'a str)>,
) -> Vec<String> {
	let mut state: Vec<(u64, &str)> = opens.chain(metas).collect();
	state.sort_by_key(|(seq, _)| *seq);
	state
		.into_iter()
		.map(|(_, line)| alloc::format!("{{\"replay\":true,{}", &line[1..]))
		.collect()
}
