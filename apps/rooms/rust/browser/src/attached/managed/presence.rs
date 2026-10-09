//! The browser owns an opaque typing sender over an exact managed selection.
use super::*;
use rooms_glowcap::client::workspace::Typing;

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = typingSender)]
	pub fn typing_sender(&self, conversation: js_sys::JsString, selected: js_sys::JsString) -> js_sys::Promise {
		let input = (|| {
			let conversation = scalar(conversation, 1024)?;
			let selected = scalar(selected, 256)?;
			let target = custody::Coordinate::decode(&selected).map_err(|_| "Invalid typing coordinate".to_string())?;
			Ok((conversation, target))
		})();
		let (conversation, target) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		let workspace = self.workspace.clone();
		self.driver.submit(conversation.len() + 256, move |_| async move {
			let sender = workspace
				.typing_sender(&conversation, target)
				.await
				.map_err(|e| e.to_string())?;
			let sender = driver.hold(sender, size_of::<Typing<Platform>>())?;
			Ok(RoomsManagedTyping { driver, sender }.into())
		})
	}
}
#[wasm_bindgen]
/// One opaque sender owns the shared facade and its typed caller. Driver::hold
/// charges handle count and the fixed Typing size through release, so JavaScript
/// retention cannot create an unbounded set of capability owners.
pub struct RoomsManagedTyping {
	driver: Driver,
	sender: Held<Typing<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedTyping {
	pub fn set(&self, on: bool) -> js_sys::Promise {
		let sender = self.sender.clone();
		self.driver.submit(0, move |_| async move {
			sender.set(on).await.map_err(|e| e.to_string())?;
			Ok(JsValue::UNDEFINED)
		})
	}
}
