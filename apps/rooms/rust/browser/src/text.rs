//! Stateless UI admission and measurement through the shared application.
use wasm_bindgen::prelude::*;

#[wasm_bindgen(js_name = nicknameRefusal)]
pub fn nickname_refusal(text: js_sys::JsString) -> Option<String> {
	if text.length() as usize > rooms_application::room::inbox::MAX_NICK {
		return Some(format!(
			"a name may be at most {} characters",
			rooms_application::room::inbox::MAX_NICK
		));
	}
	rooms_application::room::inbox::nick_refusal(&String::from(text))
}

#[wasm_bindgen(js_name = lineBytes)]
pub fn line_bytes(text: &str) -> usize {
	text.len()
}

#[wasm_bindgen(js_name = visualizerOverrideRefusal)]
pub fn visualizer_override_refusal(text: &str) -> Option<String> {
	rooms_application::session::visualizer::override_refusal(text).map(str::to_owned)
}
