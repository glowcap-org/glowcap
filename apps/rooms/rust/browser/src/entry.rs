//! The production browser boundary. Loading the module admits durable choices
//! without opening a Host, so controller selection precedes runtime ownership.
use crate::js_text::{address_text, scalar};
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

/// Which direct rows reach the member holding `registration` through
/// `directory`, by the application rule the session holds
/// (`workspace::direct_reach`). `rows` is a JSON array with one entry per
/// conversation: `null` for a room, and `{ directory, registration, closed }`
/// for a direct row, `registration` being null when nothing introduced it.
/// Resolves `{ open, reopened }`, each a position in `rows` or null.
#[wasm_bindgen(js_name = directReach)]
pub fn direct_reach(
	rows: js_sys::JsString,
	directory: js_sys::JsString,
	registration: js_sys::JsString,
) -> Result<String, JsValue> {
	use rooms_application::content::session::{custody, workspace};
	#[derive(serde::Deserialize)]
	struct Row {
		directory: String,
		registration: Option<String>,
		closed: bool,
	}
	let invalid = || JsValue::from(js_sys::Error::new("Invalid direct reach"));
	let rows = scalar(&rows, custody::MAX_AUTHORITY_BYTES).map_err(|_| invalid())?;
	let rows: Vec<Option<Row>> = serde_json::from_str(&rows).map_err(|_| invalid())?;
	if rows.len() > rooms_application::session::checkpoint::MAX_CONVERSATIONS {
		return Err(invalid());
	}
	let (Some(directory), Some(registration)) = (address_text(directory), address_text(registration)) else {
		return Err(invalid());
	};
	let reaching = rows.iter().map(|row| {
		row.as_ref().map(|row| workspace::Reaching {
			directory: &row.directory,
			registration: row.registration.as_deref(),
			closed: row.closed,
		})
	});
	let reach = workspace::direct_reach(reaching, &directory, &registration);
	Ok(serde_json::json!({ "open": reach.open, "reopened": reach.reopened }).to_string())
}

/// Stable directory identity uses the same policy and locator parser as host
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

/// How this browser, with no Rooms server, would reach a typed address: the
/// relay of the door it opens by itself, and whether a door needs a server.
#[wasm_bindgen(js_name = browserDoors)]
pub fn browser_doors(value: js_sys::JsString) -> Result<Option<String>, JsValue> {
	doors(value, crate::transport::browser_doors)
}

/// The same for a pasted capability link: a session, a management control, an
/// archive peer, or an operations capability.
#[wasm_bindgen(js_name = browserCapabilityDoors)]
pub fn browser_capability_doors(value: js_sys::JsString) -> Result<Option<String>, JsValue> {
	doors(value, crate::transport::browser_capability_doors)
}

fn doors(
	value: js_sys::JsString,
	read: fn(&str) -> rooms_glowcap::routes::Result<Option<crate::transport::Doors>>,
) -> Result<Option<String>, JsValue> {
	let Some(value) = address_text(value) else {
		return Ok(None);
	};
	let Some(doors) = read(&value).map_err(|error| js_sys::Error::new(&error.to_string()))? else {
		return Ok(None);
	};
	Ok(Some(
		serde_json::json!({ "relay": doors.relay, "throughServer": doors.through_server }).to_string(),
	))
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

#[wasm_bindgen(js_name = workspaceConversationLimit)]
pub fn workspace_conversation_limit() -> usize {
	rooms_application::session::checkpoint::MAX_CONVERSATIONS
}
