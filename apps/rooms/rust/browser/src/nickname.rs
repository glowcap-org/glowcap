//! Read-only nickname projection for keyboard-time feedback. The server's
//! atomic register remains authoritative; this only interprets bounded live
//! evidence already held by the browser.
use rooms_application::directory::registration::{nickname_availability, suggested_nick};
use wasm_bindgen::prelude::*;

const MAX_EVIDENCE_BYTES: usize = 128 * 1024;
const MAX_EVIDENCE_NAMES: usize = 1_024;

fn names(raw: Option<js_sys::Array>) -> Result<Option<Vec<String>>, JsValue> {
	let Some(raw) = raw else { return Ok(None) };
	if raw.length() as usize > MAX_EVIDENCE_NAMES {
		return Err(JsValue::from_str("invalid nickname evidence"));
	}
	let mut bytes = 0usize;
	let mut values = Vec::with_capacity(raw.length() as usize);
	for value in raw.iter() {
		let name = value
			.as_string()
			.ok_or_else(|| JsValue::from_str("invalid nickname evidence"))?;
		bytes = bytes
			.checked_add(name.len())
			.ok_or_else(|| JsValue::from_str("nickname evidence is too large"))?;
		if bytes > MAX_EVIDENCE_BYTES {
			return Err(JsValue::from_str("nickname evidence is too large"));
		}
		if !rooms_application::room::inbox::valid_nick(&name) {
			return Err(JsValue::from_str("invalid nickname evidence"));
		}
		values.push(name);
	}
	Ok(Some(values))
}

#[wasm_bindgen(js_name = nicknameAvailability)]
pub fn nickname_availability_js(
	nick: js_sys::JsString,
	own: Option<js_sys::JsString>,
	directory: Option<js_sys::Array>,
	room: Option<js_sys::Array>,
) -> Result<String, JsValue> {
	let nick = String::from(nick);
	let own = own.map(String::from);
	let directory = names(directory)?;
	let room = names(room)?;
	let answer = nickname_availability(
		&nick,
		own.as_deref(),
		directory.as_ref().map(|values| values.iter().map(String::as_str)),
		room.as_ref().map(|values| values.iter().map(String::as_str)),
	);
	serde_json::to_string(&answer).map_err(|_| JsValue::from_str("could not encode nickname availability"))
}

#[wasm_bindgen(js_name = suggestedNickname)]
pub fn suggested_nickname_js(nick: js_sys::JsString) -> String {
	suggested_nick(&String::from(nick))
}
