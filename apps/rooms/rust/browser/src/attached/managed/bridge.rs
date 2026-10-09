//! Public bridge intent and private answers enter the existing command owner.
use super::*;
use rooms_application::{bridge::Answers, content::session::bridge::Request};

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = prepareForgetBridge)]
	pub fn prepare_forget_bridge(&self, base: js_sys::JsString, room: js_sys::JsString) -> js_sys::Promise {
		let input = (|| -> Result<_> { Ok((revision(&scalar(base, 20)?)?, scalar(room, 1024)?)) })();
		let (base, room) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(room.len(), move |_| async move {
			let acquisition = workspace
				.prepare_forget_bridge(base, &room)
				.await
				.map_err(|error| error.to_string())?;
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedAcquisition { driver, acquisition }.into())
		})
	}
	#[wasm_bindgen(js_name = prepareBridge)]
	pub fn prepare_bridge(&self, intent: js_sys::JsString, secrets: js_sys::JsString) -> js_sys::Promise {
		let input = (|| -> Result<_> {
			let intent = scalar(intent, 262144)?;
			let secrets = scalar(secrets, rooms_application::bridge::MAX_JSON)?;
			let bytes = intent.len() + secrets.len();
			let intent = Request::read(&intent).map_err(|_| "Invalid bridge intent")?;
			let secrets = Answers::decode(&secrets).map_err(|error| error.to_string())?;
			Ok((intent, secrets, bytes))
		})();
		let (intent, secrets, bytes) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(bytes, move |_| async move {
			let command = workspace
				.prepare_bridge(&intent, &secrets)
				.map_err(|error| error.to_string())?;
			let bytes = command.retained_bytes();
			let command = driver.hold(command, bytes)?;
			Ok(RoomsManagedCommand { driver, command }.into())
		})
	}
	#[wasm_bindgen(js_name = prepareBridgeReapplication)]
	pub fn prepare_bridge_reapplication(
		&self,
		operation: js_sys::JsString,
		base: js_sys::JsString,
		room: js_sys::JsString,
	) -> js_sys::Promise {
		let input = (|| -> Result<_> {
			let operation = scalar(operation, 1024)?;
			let base = revision(&scalar(base, 20)?)?;
			let room = scalar(room, 1024)?;
			Ok((operation, base, room))
		})();
		let (operation, base, room) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(operation.len() + room.len(), move |_| async move {
			let command = workspace
				.prepare_bridge_reapplication(&operation, base, &room)
				.await
				.map_err(|error| error.to_string())?;
			let bytes = command.retained_bytes();
			let command = driver.hold(command, bytes)?;
			Ok(RoomsManagedCommand { driver, command }.into())
		})
	}
}
