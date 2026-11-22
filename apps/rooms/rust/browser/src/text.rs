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

/// A browser receives only Rooms' inert document projection. Authored source
/// remains the wire and archive value. A line is read as the parts the page
/// draws: one per IRC formatting run, each with its own document. Parsing
/// failure is represented inside a document as literal text rather than
/// crossing this boundary as a lost message.
#[wasm_bindgen(js_name = richText)]
pub fn rich_text(text: &str) -> Result<String, JsValue> {
	serde_json::to_string(&rooms_application::markdown::rich::read(text))
		.map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

/// Whom a line addresses, as `{"member":bool,"room":bool}`. `own` is the name
/// the reader answers to in the room, or absent before one is known. This is
/// the question the session answers for every live line, asked of a line that
/// no activity row carries, such as one read from history or an archive.
#[wasm_bindgen(js_name = lineMentions)]
pub fn line_mentions(from: &str, text: &str, own: Option<String>) -> Result<String, JsValue> {
	let found = rooms_application::room::mentions::Mentions::of_line(from, text, own.as_deref());
	serde_json::to_string(&found).map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = openGraphTargets)]
pub fn open_graph_targets(text: &str) -> Result<String, JsValue> {
	serde_json::to_string(&rooms_application::markdown::Document::read(text).preview_targets())
		.map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = openGraphSelection)]
pub fn open_graph_selection(text: &str, encoded: &str) -> Option<String> {
	rooms_application::open_graph::Selection::decode(text, encoded)
		.ok()
		.map(|selection| selection.encode())
}

#[wasm_bindgen(js_name = openGraphMetadata)]
pub fn open_graph_metadata(encoded: &str) -> Option<String> {
	rooms_application::open_graph::Metadata::decode(encoded).and_then(|metadata| serde_json::to_string(&metadata).ok())
}
