//! The browser projects the shared command vocabulary and original-text spans.
use wasm_bindgen::prelude::*;

#[wasm_bindgen(js_name = slashCatalog)]
pub fn slash_catalog() -> Result<String, JsValue> {
	serde_json::to_string(rooms_application::slash::catalog::CATALOG)
		.map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = readSlashCommand)]
pub fn read_slash_command(text: js_sys::JsString) -> Result<Option<String>, JsValue> {
	if text.char_code_at(0) != f64::from(b'/') {
		return Ok(None);
	}
	let text = crate::js_text::document(&text, 65_536).map_err(|error| js_sys::Error::new(&error.to_string()))?;
	rooms_application::slash::read(&text)
		.map(|read| serde_json::to_string(&read).map_err(|error| js_sys::Error::new(&error.to_string()).into()))
		.transpose()
}

#[wasm_bindgen(js_name = interpretSlashCommand)]
pub fn interpret_slash_command(
	name: &str,
	rest: js_sys::JsString,
	place: &str,
	you: js_sys::JsString,
	away: bool,
) -> Result<String, JsValue> {
	use rooms_application::slash::{
		catalog::Name,
		interpret::{Context, Place, interpret},
	};
	let name = Name::parse(name).ok_or_else(|| js_sys::Error::new("Unknown Rooms command"))?;
	let place = match place {
		"none" => Place::None,
		"room" => Place::Room,
		"direct" => Place::Direct,
		"directory" => Place::Directory,
		_ => return Err(js_sys::Error::new("Unknown Rooms command context").into()),
	};
	let rest = input(rest)?;
	let you = input(you)?;
	serde_json::to_string(&interpret(name, &rest, &Context { place, you: &you, away }))
		.map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = readRoomJoin)]
pub fn read_room_join(text: js_sys::JsString) -> Result<Option<String>, JsValue> {
	rooms_application::slash::input::join(&input(text)?)
		.map(|join| serde_json::to_string(&join).map_err(|error| js_sys::Error::new(&error.to_string()).into()))
		.transpose()
}

#[wasm_bindgen(js_name = roomInviteRefusal)]
pub fn room_invite_refusal(who: js_sys::JsString, you: js_sys::JsString) -> Result<Option<String>, JsValue> {
	Ok(rooms_application::slash::interpret::invite_refusal(
		&input(who)?,
		&input(you)?,
	))
}

#[wasm_bindgen(js_name = addressesEveryone)]
pub fn addresses_everyone(who: js_sys::JsString) -> Result<bool, JsValue> {
	Ok(rooms_application::slash::interpret::everyone(&input(who)?))
}

fn input(text: js_sys::JsString) -> Result<rooms_application::text::DocumentText, JsValue> {
	crate::js_text::document(&text, 65_536).map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = prepareComposer)]
pub fn prepare_composer(raw: js_sys::JsString) -> Result<String, JsValue> {
	let raw = crate::js_text::scalar(&raw, rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS)
		.map_err(|error| js_sys::Error::new(&error.to_string()))?;
	let submission: rooms_application::slash::composer::Submission =
		serde_json::from_str(&raw).map_err(|error| js_sys::Error::new(&error.to_string()))?;
	serde_json::to_string(&rooms_application::slash::composer::prepare(&submission))
		.map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = composerLineRefusal)]
pub fn composer_line_refusal(text: js_sys::JsString, maximum: Option<u32>) -> Result<Option<String>, JsValue> {
	Ok(rooms_application::slash::composer::line_refusal(
		&input(text)?,
		maximum.map(|value| value as usize),
	))
}

/// A proved revision conflict permits re-preparation only when the original
/// command selection remains unchanged. This comparison grants no authority.
#[wasm_bindgen(js_name = commandSelectionUnchanged)]
pub fn command_selection_unchanged(
	name: &str,
	arguments: js_sys::Array,
	before: js_sys::JsString,
	after: js_sys::JsString,
) -> Result<bool, JsValue> {
	let parse = |raw: js_sys::JsString| -> Result<serde_json::Value, JsValue> {
		let raw = crate::js_text::scalar(&raw, rooms_application::content::session::custody::MAX_AUTHORITY_BYTES)
			.map_err(|error| js_sys::Error::new(&error.to_string()))?;
		serde_json::from_str(&raw).map_err(|error| js_sys::Error::new(&error.to_string()).into())
	};
	if arguments.length() > rooms_application::session::command::MAX_ARGUMENTS as u32 {
		return Err(js_sys::Error::new("Command has too many arguments").into());
	}
	let arguments = arguments
		.iter()
		.map(|value| {
			value
				.as_string()
				.ok_or_else(|| js_sys::Error::new("Command argument must be text"))
		})
		.collect::<Result<Vec<_>, _>>()?;
	Ok(rooms_application::session::command::selection::unchanged(
		name,
		&arguments,
		&parse(before)?,
		&parse(after)?,
	))
}
