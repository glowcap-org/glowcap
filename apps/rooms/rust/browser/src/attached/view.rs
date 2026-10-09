//! Property projection for managed browser capability wrappers.
use super::Result;
use wasm_bindgen::JsValue;
pub(super) fn set(object: &JsValue, key: &str, value: JsValue) -> Result<()> {
	js_sys::Reflect::set(object, &key.into(), &value)
		.map_err(|_| "Rooms view property could not be written".to_owned())?
		.then_some(())
		.ok_or_else(|| "Rooms view property was refused".into())
}
