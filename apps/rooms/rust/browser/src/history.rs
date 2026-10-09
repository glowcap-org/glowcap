//! Project the shared archive namespace without duplicating its derivation.
use wasm_bindgen::prelude::*;

#[wasm_bindgen(js_name = directHistoryId)]
pub fn direct_history_id(directory: js_sys::JsString, registration: js_sys::JsString) -> Result<String, JsValue> {
	let directory = crate::js_text::scalar(&directory, 4096).map_err(|error| js_sys::Error::new(&error.to_string()))?;
	let registration =
		crate::js_text::scalar(&registration, 64).map_err(|error| js_sys::Error::new(&error.to_string()))?;
	rooms_application::content::session::workspace::history::direct(&directory, &registration)
		.map(|id| id.text().as_str().expect("shared scalar history identity").to_owned())
		.map_err(|error| js_sys::Error::new(error).into())
}
