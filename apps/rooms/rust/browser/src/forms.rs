//! Bounded form transfer. Shared declarations own required answers and secret
//! separation; browser widgets retain only their currently edited input.
use rooms_application::bridge::{self, Answers, Form};
use wasm_bindgen::prelude::*;

fn text(raw: js_sys::JsString, limit: usize) -> Result<String, String> {
	let text = crate::commands::read_text(raw, limit).map_err(|error| error.to_string())?;
	text.as_str()
		.map(str::to_owned)
		.ok_or_else(|| "JSON input must escape isolated UTF-16 surrogates".into())
}

#[wasm_bindgen(js_name = prepareBridgeForm)]
pub fn prepare_bridge_form(
	form: js_sys::JsString,
	action: js_sys::JsString,
	answers: js_sys::JsString,
	toggles: js_sys::Array,
) -> String {
	let prepare = || {
		// Check the complete boundary before copying any collection element.
		if form.length() as usize > bridge::MAX_JSON
			|| answers.length() as usize > bridge::MAX_JSON
			|| action.length() > 32
			|| toggles.length() as usize > bridge::MAX_FIELDS
		{
			return Err(bridge::Error::Size.to_string());
		}
		let form = Form::decode(&text(form, bridge::MAX_JSON)?).map_err(|error| error.to_string())?;
		let answers = Answers::decode(&text(answers, bridge::MAX_JSON)?).map_err(|error| error.to_string())?;
		let action = text(action, 32)?;
		let toggles: Vec<String> = toggles
			.iter()
			.map(|value| {
				if !value.is_string() {
					return Err("Invalid bridge toggle".into());
				}
				text(value.unchecked_into(), 32)
			})
			.collect::<Result<_, String>>()?;
		let toggles: Vec<&str> = toggles.iter().map(String::as_str).collect();
		let submission = form
			.submission(&action, &answers, &toggles)
			.map_err(|error| error.to_string())?;
		// This explicit transfer is transient. Stored intent only receives the
		// public half through the shared session's bridge command.
		#[derive(serde::Serialize)]
		struct Transfer<'a> {
			answers: &'a Answers,
			secrets: &'a Answers,
		}
		serde_json::to_string(&Transfer {
			answers: submission.answers(),
			secrets: submission.secrets(),
		})
		.map_err(|error| error.to_string())
	};
	match prepare() {
		Ok(output) => output,
		Err(why) => serde_json::json!({ "why": why }).to_string(),
	}
}

#[wasm_bindgen(js_name = roomPolicyForPreset)]
pub fn room_policy_for_preset(preset: js_sys::JsString) -> Result<String, JsValue> {
	let preset = text(preset, 32).map_err(|error| js_sys::Error::new(&error))?;
	let policy = rooms_application::room::policy::RoomPolicy::from_preset(&preset)
		.ok_or_else(|| js_sys::Error::new("Unknown room access preset"))?;
	serde_json::to_string(&policy).map_err(|error| js_sys::Error::new(&error.to_string()).into())
}
