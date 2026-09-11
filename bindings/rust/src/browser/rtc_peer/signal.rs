use crate::abi_constants::{WEBRTC_MAX_ICE_CANDIDATE_BYTES, WEBRTC_MAX_SIGNAL_BYTES};
use js_sys::{Array, JsString, Reflect, JSON};
use std::io;
use wasm_bindgen::{JsCast, JsValue};
use web_sys::{RtcIceCandidate, RtcIceCandidateInit};

fn invalid() -> io::Error {
	io::Error::new(
		io::ErrorKind::InvalidData,
		"invalid or oversized WebRTC signaling value",
	)
}
pub(super) fn description(text: &str) -> io::Result<()> {
	if text.is_empty() || text.len() > WEBRTC_MAX_SIGNAL_BYTES {
		Err(invalid())
	} else {
		Ok(())
	}
}

fn platform_text(value: &JsValue, limit: usize) -> io::Result<String> {
	let text = value.dyn_ref::<JsString>().ok_or_else(invalid)?;
	// Bound the platform UTF-16 length before conversion. UTF-8 conversion has
	// a bounded transient allocation of at most three bytes per code unit; only
	// text inside the exact UTF-8 envelope is admitted into a retained queue.
	if text.length() as usize > limit {
		return Err(invalid());
	}
	let text = value.as_string().ok_or_else(invalid)?;
	if text.len() > limit {
		Err(invalid())
	} else {
		Ok(text)
	}
}
pub(super) fn description_value(value: &JsValue) -> io::Result<String> {
	let value = Reflect::get(value, &"sdp".into()).map_err(super::super::socket::js_error)?;
	let text = platform_text(&value, WEBRTC_MAX_SIGNAL_BYTES)?;
	description(&text)?;
	Ok(text)
}
pub(super) fn local_candidate(candidate: &RtcIceCandidate) -> io::Result<String> {
	let text = JSON::stringify(&candidate.to_json()).map_err(super::super::socket::js_error)?;
	platform_text(&text, WEBRTC_MAX_ICE_CANDIDATE_BYTES)
}

pub(super) fn candidate(text: &str) -> io::Result<RtcIceCandidateInit> {
	if text.is_empty() || text.len() > WEBRTC_MAX_ICE_CANDIDATE_BYTES {
		return Err(invalid());
	}
	let value = JSON::parse(text).map_err(super::super::socket::js_error)?;
	if !value.is_object() || value.is_null() || Array::is_array(&value) {
		return Err(invalid());
	}
	// Web IDL would coerce strings and numbers. The signaling boundary instead
	// accepts exactly its declared field types, as the native/browser protocol
	// clients do, before passing this bounded dictionary to the browser.
	for field in ["candidate", "sdpMid", "usernameFragment"] {
		let part = Reflect::get(&value, &field.into()).map_err(super::super::socket::js_error)?;
		if !part.is_null() && !part.is_undefined() && !part.is_string() {
			return Err(invalid());
		}
	}
	let line = Reflect::get(&value, &"sdpMLineIndex".into()).map_err(super::super::socket::js_error)?;
	if !line.is_null() && !line.is_undefined() {
		let number = line.as_f64().ok_or_else(invalid)?;
		if !number.is_finite() || number.fract() != 0.0 || !(0.0..=u16::MAX as f64).contains(&number) {
			return Err(invalid());
		}
	}
	Ok(value.unchecked_into())
}
