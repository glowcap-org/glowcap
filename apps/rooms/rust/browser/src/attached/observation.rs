//! Browser callbacks report failures through the shared application work owner.
use super::Result;
use wasm_bindgen::{JsCast, JsValue};
pub(super) fn call(function: &js_sys::Function, argument: JsValue) -> Result<()> {
	function
		.call1(&JsValue::UNDEFINED, &argument)
		.map(|_| ())
		.map_err(|error| {
			error
				.dyn_ref::<js_sys::Error>()
				.map(|error| String::from(error.message()))
				.or_else(|| error.as_string())
				.unwrap_or_else(|| "Rooms view callback failed".into())
		})
}
