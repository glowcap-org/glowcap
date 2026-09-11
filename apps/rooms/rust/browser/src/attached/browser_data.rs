use super::RoomsBrowserSession;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
impl RoomsBrowserSession {
	/// Browser data belongs to this device even when the view is attached to a
	/// remote session. No remote retention setting or archive authority is used.
	#[wasm_bindgen(js_name = eraseBrowserArchive)]
	pub fn erase_browser_archive(&self) -> js_sys::Promise {
		self.driver.submit(0, |environment| async move {
			match &environment.local {
				Some(local) => local.erase_browser_archive().await?,
				None => environment.browser_archive.erase().await.map_err(|e| e.to_string())?,
			}
			Ok(JsValue::UNDEFINED)
		})
	}
}
