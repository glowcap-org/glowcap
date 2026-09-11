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
	let text = crate::commands::read_text(text, 65_536).map_err(|error| js_sys::Error::new(&error.to_string()))?;
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
		interpret::{interpret, Context, Place},
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
	crate::commands::read_text(text, 65_536).map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

#[wasm_bindgen(js_name = prepareComposer)]
pub fn prepare_composer(raw: js_sys::JsString) -> Result<String, JsValue> {
	if raw.length() as usize > rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS {
		return Err(js_sys::Error::new("Rooms composer input exceeds its document bound").into());
	}
	let raw = raw
		.as_string()
		.ok_or_else(|| js_sys::Error::new("Rooms composer input is not text"))?;
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
