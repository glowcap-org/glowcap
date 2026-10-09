//! Presentation transfer for the shared operations-bundle grammar.
use rooms_application::server::operations::bundle::{Draft, MAX_BUNDLE_BYTES};
use wasm_bindgen::prelude::*;

fn text(raw: js_sys::JsString) -> Result<String, JsValue> {
	if raw.length() as usize > MAX_BUNDLE_BYTES {
		return Err(js_sys::Error::new("The capability set exceeds its text limit.").into());
	}
	let scalar = String::from(&raw);
	let round_trip = js_sys::JsString::from(scalar.as_str());
	if round_trip != raw {
		return Err(js_sys::Error::new("Operations capabilities must contain Unicode scalar text.").into());
	}
	Ok(scalar)
}
fn project(draft: Draft) -> String {
	serde_json::json!({
		"entries": draft.entries().collect::<Vec<_>>(),
		"ready": draft.ready(),
		"formatted": draft.format(),
	})
	.to_string()
}
#[wasm_bindgen(js_name = operationsBundleDraft)]
pub fn operations_bundle_draft(raw: js_sys::JsString, pasted: bool) -> Result<String, JsValue> {
	Draft::parse(&text(raw)?, pasted)
		.map(project)
		.map_err(|error| js_sys::Error::new(&error).into())
}
#[wasm_bindgen(js_name = operationsBundleEntries)]
pub fn operations_bundle_entries(raw: js_sys::JsString) -> Result<String, JsValue> {
	let entries: Vec<(String, String)> =
		serde_json::from_str(&text(raw)?).map_err(|_| js_sys::Error::new("Invalid operations bundle entries."))?;
	let mut draft = Draft::default();
	for (capability, swiss) in entries {
		draft
			.insert(&capability, &swiss)
			.map_err(|error| js_sys::Error::new(&error))?;
	}
	Ok(project(draft))
}
