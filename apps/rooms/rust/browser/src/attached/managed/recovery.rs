//! Cold receipt inspection restores the exact initiating endpoint's intent.
//! Descriptive rows cannot select a sibling grant or recreate a lost executor.
use super::*;
use rooms_glowcap::client::workspace::RecoveredEffect;

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	pub fn effects(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		self.driver.submit(0, move |_| async move {
			let rows = workspace.effects().await.map_err(|error| error.to_string())?;
			json(&serde_json::to_string(&rows.into_iter().map(|row| {
				serde_json::json!({"operation": row.operation, "status": format!("{:?}", row.status).to_lowercase(), "resumable": row.resumable})
			}).collect::<Vec<_>>()).map_err(|_| "Invalid receipt inventory")?)
		})
	}
	#[wasm_bindgen(js_name = recoverEffect)]
	pub fn recover_effect(&self, operation: js_sys::JsString) -> js_sys::Promise {
		let operation = match scalar(operation, 128) {
			Ok(operation) => operation,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(operation.len(), move |_| async move {
			let effect = workspace
				.recover_effect(&operation)
				.await
				.map_err(|error| error.to_string())?;
			let Some(effect) = effect else {
				return Ok(JsValue::UNDEFINED);
			};
			let bytes = effect.retained_bytes();
			let effect = driver.hold(effect, bytes)?;
			Ok(RoomsManagedRecoveredEffect { driver, effect }.into())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsManagedRecoveredEffect {
	driver: Driver,
	effect: Held<RecoveredEffect<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedRecoveredEffect {
	pub fn adopted(&self) -> js_sys::Promise {
		let effect = self.effect.clone();
		self.driver.submit(0, move |_| async move {
			effect
				.adopted()
				.await
				.map(Into::into)
				.map_err(|error| error.to_string())
		})
	}
	#[wasm_bindgen(js_name = originalIntent)]
	pub fn original_intent(&self) -> Result<JsValue> {
		json(self.effect.canonical())
	}
	pub fn status(&self) -> js_sys::Promise {
		let effect = self.effect.clone();
		self.driver.submit(0, move |_| async move {
			effect
				.status()
				.await
				.map(|status| format!("{status:?}").to_lowercase().into())
				.map_err(|error| error.to_string())
		})
	}
	pub fn result(&self) -> js_sys::Promise {
		let effect = self.effect.clone();
		self.driver
			.submit(0, move |_| async move { outcome::result(effect.result().await) })
	}
	pub fn receive(&self) -> js_sys::Promise {
		let effect = self.effect.clone();
		self.driver.submit(0, move |_| async move {
			effect
				.receive()
				.await
				.map(|status| format!("{status:?}").to_lowercase().into())
				.map_err(|e| e.to_string())
		})
	}
	#[wasm_bindgen(js_name = prepareResultAcquisition)]
	pub fn prepare_result_acquisition(
		&self,
		expected: js_sys::JsString,
		mappings: js_sys::JsString,
		releases: js_sys::JsString,
		intent: js_sys::JsString,
		source: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let effect = self.effect.clone();
		super::acquisition::result_acquisition(
			&self.driver,
			(expected, mappings, releases, intent, source),
			move |expected, imports, releases, intent, source| {
				effect.prepare_result_acquisition_with_source(expected, imports, releases, intent, source)
			},
		)
	}
	#[wasm_bindgen(js_name = prepareCreatedRoomAcquisition)]
	pub fn prepare_created_room_acquisition(
		&self,
		expected: js_sys::JsString,
		mappings: js_sys::JsString,
		releases: js_sys::JsString,
		intent: js_sys::JsString,
		source: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let effect = self.effect.clone();
		super::acquisition::result_acquisition(
			&self.driver,
			(expected, mappings, releases, intent, source),
			move |expected, imports, releases, intent, source| {
				effect
					.prepare_result_acquisition_with_source(expected, imports, releases, intent, source)?
					.created_room()
			},
		)
	}

	pub fn resume(&self) -> js_sys::Promise {
		let effect = self.effect.clone();
		self.driver.submit(0, move |_| async move {
			effect
				.resume()
				.await
				.map(|status| format!("{status:?}").to_lowercase().into())
				.map_err(|error| error.to_string())
		})
	}
	/// Give up on this receipt for good; see `RecoveredEffect::release`.
	pub fn release(&self) -> js_sys::Promise {
		let effect = self.effect.clone();
		self.driver.submit(0, move |_| async move {
			effect
				.release()
				.await
				.map(|()| JsValue::UNDEFINED)
				.map_err(|error| error.to_string())
		})
	}
}
#[wasm_bindgen]
impl RoomsManagedCommand {
	pub fn adopted(&self) -> js_sys::Promise {
		let command = self.command.clone();
		self.driver.submit(0, move |_| async move {
			command
				.adopted()
				.await
				.map(Into::into)
				.map_err(|error| error.to_string())
		})
	}
	#[wasm_bindgen(js_name = originalIntent)]
	pub fn original_intent(&self) -> Result<JsValue> {
		json(self.command.canonical())
	}
}
