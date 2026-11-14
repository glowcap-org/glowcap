//! Public bridge intent and private answers enter the existing command owner.
use super::*;
use rooms_application::{bridge::Answers, content::session::bridge::Request};
use rooms_runtime::Error as RuntimeError;

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = prepareBridge)]
	pub fn prepare_bridge(&self, intent: js_sys::JsString, secrets: js_sys::JsString) -> js_sys::Promise {
		let input = (|| -> Result<_> {
			let intent = scalar(intent, 262144)?;
			let secrets = scalar(secrets, rooms_application::bridge::MAX_JSON)?;
			let bytes = intent.len() + secrets.len();
			let intent = Request::read(&intent).map_err(|_| RuntimeError::invalid("Invalid bridge intent"))?;
			let secrets = Answers::decode(&secrets).map_err(RuntimeError::invalid_by)?;
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
				.map_err(RuntimeError::from)?;
			let bytes = command.retained_bytes();
			let command = driver.hold(command, bytes)?;
			Ok(RoomsManagedCommand { driver, command }.into())
		})
	}
}
