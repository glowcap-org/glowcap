//! Fetch once, then retain a replacement of the original Operations selection.
use super::*;
use rooms_glowcap::client::{
	Deadline,
	workspace::{OperationsAcquisition, OperationsSelection},
};

#[wasm_bindgen]
pub struct RoomsManagedOperationsAcquisition {
	driver: Driver,
	acquisition: Held<OperationsAcquisition<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedOperationsAcquisition {
	pub fn submit(&self) -> js_sys::Promise {
		let acquisition = self.acquisition.clone();
		self.driver.submit(
			0,
			move |_| async move { outcome::acquisition(acquisition.submit().await) },
		)
	}
	pub fn reprepare(&self) -> js_sys::Promise {
		let acquisition = self.acquisition.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |_| async move {
			let acquisition = acquisition.reprepare().await.map_err(|error| error.to_string())?;
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedOperationsAcquisition { driver, acquisition }.into())
		})
	}
}
#[wasm_bindgen]
impl RoomsManagedWorkspace {
	/// Fetch every bounded import once. Up to six refused entries own diagnostic
	/// JSON projections until JS receives them. Those copies preserve each cause
	/// after the job and its successful temporary occurrences have retired.
	#[wasm_bindgen(js_name = prepareOperationsAcquisition)]
	pub fn prepare_operations_acquisition(
		&self,
		imports: js_sys::JsString,
		original: js_sys::JsString,
		replacement: js_sys::JsString,
	) -> js_sys::Promise {
		let input = (|| {
			let imports = scalar(imports, 131072)?;
			let original = scalar(original, OperationsSelection::MAX_JSON_BYTES)?;
			let replacement = scalar(replacement, 8192)?;
			let bytes = imports.len() + original.len() + replacement.len();
			let imports: Vec<workspace::ImportRecipe> =
				serde_json::from_str(&imports).map_err(|_| "Invalid operations imports")?;
			if imports.len() > rooms_application::server::operations::BOOT_CAPABILITIES.len() {
				return Err("Operations imports exceed the boot capability inventory".into());
			}
			acquisition::validate_recipes(&imports)?;
			let original: OperationsSelection =
				serde_json::from_str(&original).map_err(|_| "Invalid original operations selection")?;
			let replacement: OperationsSelection =
				serde_json::from_str(&replacement).map_err(|_| "Invalid replacement operations selection")?;
			Ok((imports, original, replacement, bytes))
		})();
		let (incoming, original, replacement, bytes) = match input {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(bytes, move |environment| async move {
			let mut imports = Vec::with_capacity(incoming.len());
			// At most six diagnostic rows cross into JS. Successful occurrences
			// stay in this job until all fetches finish, then either move together
			// into one candidate or retire without any workspace mutation.
			let mut failures = None;
			for entry in incoming {
				let capability = replacement
					.capability_at(entry.coordinate)
					.ok_or("Operations import is not in the replacement selection")?;
				let reference = environment
					.platform
					.within(
						rooms_application::room::authority::REQUEST_TIMEOUT_MS,
						environment.runtime.host().enliven(&entry.uri),
					)
					.await
					.ok_or_else(|| "Operations acquisition did not answer".to_owned())
					.and_then(|answer| answer.map_err(|error| error.to_string()));
				let reference = match reference {
					Ok(reference) => reference,
					Err(reason) => {
						let advice = rooms_application::session::diagnosis::operations(capability, &reason);
						failures.get_or_insert_with(js_sys::Array::new).push(&json(
							&serde_json::json!({
								"capability": capability, "reason": reason, "advice": advice,
							})
							.to_string(),
						)?);
						continue;
					}
				};
				imports.push(Import {
					coordinate: entry.coordinate,
					reference,
					uri: Some(entry.uri),
				});
			}
			if let Some(failures) = failures {
				let refused = json(r#"{"status":"refused"}"#)?;
				super::super::view::set(&refused, "failures", failures.into())?;
				return Ok(refused);
			}
			let acquisition = workspace
				.prepare_operations(imports, original, replacement)
				.await
				.map_err(|error| error.to_string())?;
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedOperationsAcquisition { driver, acquisition }.into())
		})
	}
}
