//! Retained management requests distinguish a proved admission conflict from
//! a missing acknowledgement. Only the former permits explicit reapplication.
use super::control::RoomsManagedEdit;
use super::*;

/// Preserve terminal diagnostic data separately from a failed result read.
pub(super) fn result(value: core::result::Result<Argument, rooms_glowcap::client::Error>) -> Result<JsValue> {
	match value {
		Ok(value) => committed_data(&value),
		Err(rooms_glowcap::client::Error::Observation(reason)) => {
			json(&serde_json::json!({"observationFailure": reason}).to_string())
		}
		Err(rooms_glowcap::client::Error::RefusedObservation(reason)) => {
			json(&serde_json::json!({"observationFailure": reason, "knownAbsent": true}).to_string())
		}
		Err(error) => Err(error.to_string()),
	}
}

pub(super) fn acquisition(result: core::result::Result<(), rooms_glowcap::client::Error>) -> Result<JsValue> {
	match result {
		Ok(()) => Ok("committed".into()),
		Err(rooms_glowcap::client::Error::WorkspaceConflict) => Ok("conflict".into()),
		Err(error) => Err(error.to_string()),
	}
}

pub(super) fn failed(error: rooms_glowcap::client::Error) -> Result<JsValue> {
	let conflict = matches!(&error,
		rooms_glowcap::client::Error::Binding(error)
			if error.kind() == glowcap::ErrorKind::Broken && matches!(error.message(), Some("RevisionConflict" | "OperationConflict")));
	json(
		&serde_json::json!({
			"status": if conflict { "conflict" } else { "uncertain" },
			"reason": error.to_string(),
		})
		.to_string(),
	)
}

#[wasm_bindgen]
impl RoomsManagedEdit {
	/// Failure keeps this exact request. An uncertain reply never authorizes a
	/// new sequence. Revision and sequence conflicts refuse before mutation.
	#[wasm_bindgen(js_name = submitOutcome)]
	pub fn submit_outcome(&self) -> js_sys::Promise {
		let request = self.request.clone();
		self.driver.submit(0, move |_| async move {
			match request.submit().await {
				Ok(()) => json(r#"{"status":"committed"}"#),
				Err(error) => failed(error),
			}
		})
	}
}
