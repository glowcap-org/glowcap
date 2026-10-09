//! The production browser boundary. Loading the module admits durable choices
//! without opening a Host, so controller selection precedes runtime ownership.
use wasm_bindgen::prelude::*;

#[wasm_bindgen(js_name = directConversationId)]
pub fn direct_conversation_id(directory: js_sys::JsString, registration: js_sys::JsString) -> Result<String, JsValue> {
	let identity = (|| -> Option<_> {
		let directory = address_text(directory)?;
		let registration = rooms_application::directory::registration::Id::parse(&address_text(registration)?).ok()?;
		rooms_application::session::checkpoint::direct_id(&directory, &registration)
	})();
	identity
		.and_then(|id| id.text().as_str().map(str::to_owned))
		.ok_or_else(|| js_sys::Error::new("Invalid direct conversation identity").into())
}

/// Stable directory identity uses the same policy and locator parser as native
/// Rooms. This does not dial, create a Host, or install a JavaScript ABI adapter.
#[wasm_bindgen(js_name = directoryAuthority)]
pub fn directory_authority(locator: js_sys::JsString) -> Result<Option<String>, JsValue> {
	let Some(value) = address_text(locator) else {
		return Ok(None);
	};
	rooms_glowcap::routes::Address::directory(&value)
		.map(|address| address.map(|address| address.authority))
		.map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = directoryCapability)]
pub fn directory_capability(route: js_sys::JsString) -> Result<String, JsValue> {
	let route = address_text(route).ok_or_else(|| js_sys::Error::new("Invalid directory address"))?;
	rooms_glowcap::routes::directory_recipe(&route).map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

/// Inspect an address before a browser chooses a live application owner.
#[wasm_bindgen(js_name = inspectDirectory)]
pub fn inspect_directory(value: js_sys::JsString) -> Result<Option<String>, JsValue> {
	inspect(value, rooms_glowcap::routes::Address::directory)
}

/// Inspect a Rooms v1.0 capability's route without enlivening its authority.
#[wasm_bindgen(js_name = inspectCapability)]
pub fn inspect_capability(value: js_sys::JsString) -> Result<Option<String>, JsValue> {
	inspect(value, rooms_glowcap::routes::Address::capability)
}

#[wasm_bindgen(js_name = roomAuthorityToken)]
pub fn room_authority_token(value: js_sys::JsString) -> Result<String, JsValue> {
	let value = address_text(value).ok_or_else(|| js_sys::Error::new("Invalid Rooms authority text"))?;
	rooms_glowcap::routes::authority_token(&value)
		.map_err(|error| JsValue::from(js_sys::Error::new(&error.to_string())))?
		.ok_or_else(|| js_sys::Error::new("a room authority sturdyref has no publication identity").into())
}

fn inspect(
	value: js_sys::JsString,
	read: impl FnOnce(&str) -> rooms_glowcap::routes::Result<Option<rooms_glowcap::routes::Address>>,
) -> Result<Option<String>, JsValue> {
	let Some(value) = address_text(value) else {
		return Ok(None);
	};
	let Some(address) = read(&value).map_err(|error| js_sys::Error::new(&error.to_string()))? else {
		return Ok(None);
	};
	Ok(Some(
		serde_json::json!({
			"authority": address.authority,
			"address": address.address,
			"transport": address.transport,
			"designator": address.designator,
		})
		.to_string(),
	))
}

fn address_text(value: js_sys::JsString) -> Option<String> {
	if value.length() > 65536 {
		return None;
	}
	let scalar = value.as_string()?;
	// Compare JS strings: the str comparison would itself lose surrogates.
	let round_trip = js_sys::JsString::from(scalar.as_str());
	if round_trip != value {
		return None;
	}
	Some(scalar)
}

/// Diagnostic presentation must not bulk-copy an unbounded JavaScript error.
#[wasm_bindgen(js_name = attachmentFailureAdvice)]
pub fn attachment_failure_advice(reason: js_sys::JsString) -> Option<String> {
	let prefix = reason.slice(
		0,
		reason.length().min(rooms_application::failure::MAX_REASON_BYTES as u32),
	);
	let scalar = prefix.as_string()?;
	let prefix = rooms_application::failure::reason_prefix(&scalar);
	rooms_application::session::diagnosis::attachment(prefix).and_then(|advice| serde_json::to_string(&advice).ok())
}

#[wasm_bindgen(js_name = workspaceConversationLimit)]
pub fn workspace_conversation_limit() -> usize {
	rooms_application::session::checkpoint::MAX_CONVERSATIONS
}
