//! The production browser boundary. Loading the module admits durable choices
//! without opening a Host, so controller selection precedes runtime ownership.
use rooms_application::workspace::Workspace;
use rooms_glowcap::routes::CheckpointRoutes;
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

/// Return a normalized, validated document, or absence for an invalid saved
/// document. The page keeps invalid storage intact and reports the refusal.
#[wasm_bindgen(js_name = readWorkspace)]
pub fn read_workspace(raw: js_sys::JsString) -> Option<String> {
	decode_workspace(raw).ok()?.encode().ok()
}

#[wasm_bindgen(js_name = exportWorkspace)]
pub fn export_workspace(raw: js_sys::JsString, include_capabilities: bool) -> Result<String, JsValue> {
	decode_workspace(raw)
		.and_then(|workspace| workspace.export(include_capabilities).map_err(|e| e.to_string()))
		.map_err(|error| js_sys::Error::new(&error).into())
}

pub(crate) fn decode_workspace(raw: js_sys::JsString) -> Result<Workspace, String> {
	if raw.length() as usize > rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS {
		return Err("Rooms workspace exceeds its document bound".into());
	}
	let scalar = raw.as_string().ok_or("Rooms workspace is not text")?;
	// JsString/str equality converts through another lossy Rust string.
	// Comparing two JavaScript strings detects that the bulk transfer changed.
	let round_trip = js_sys::JsString::from(scalar.as_str());
	let workspace = if round_trip == raw {
		Workspace::decode(&scalar, &CheckpointRoutes)
	} else {
		// Only the unusual non-scalar document crosses one code unit at a
		// time. Ordinary JSON takes the binding's bulk UTF-8 transfer.
		Workspace::decode_utf16(&raw.iter().collect::<Vec<_>>(), &CheckpointRoutes)
	};
	workspace.map_err(|e| e.to_string())
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
	rooms_application::session::diagnosis::attachment(&prefix.as_string()?).map(str::to_owned)
}

#[wasm_bindgen(js_name = emptySessionCheckpoint)]
pub fn empty_session_checkpoint() -> Result<String, JsValue> {
	rooms_application::session::checkpoint::Checkpoint::empty()
		.encode_for(rooms_application::grants::Access::Admin)
		.map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = workspaceStorageKey)]
pub fn workspace_storage_key() -> String {
	rooms_application::workspace::STORAGE_KEY.into()
}

#[wasm_bindgen(js_name = workspaceConversationLimit)]
pub fn workspace_conversation_limit() -> usize {
	rooms_application::session::checkpoint::MAX_CONVERSATIONS
}
