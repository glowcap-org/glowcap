//! Property projection for managed browser capability wrappers.
use super::Result;
use rooms_runtime::Error as RuntimeError;
use wasm_bindgen::JsValue;
pub(super) fn set(object: &JsValue, key: &str, value: JsValue) -> Result<()> {
	js_sys::Reflect::set(object, &key.into(), &value)
		.map_err(|_| RuntimeError::platform_message("Rooms view property could not be written"))?
		.then_some(())
		.ok_or_else(|| RuntimeError::platform_message("Rooms view property was refused"))
}
