//! Retained management requests distinguish a proved admission conflict from
//! a refusal that admitted nothing and from a missing acknowledgement. Only a
//! conflict permits explicit reapplication, only an acknowledgement that never
//! came keeps the request for replay, and a refusal frees it with its reason.
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

/// A submitted request's outcome as the page reads it: `committed`, a proved
/// `conflict`, a `refused` request the peer admitted nothing of, or
/// `uncertain` when nothing settled the question. Every outcome but the
/// first carries the reason the client saw.
fn submission(status: &str, reason: Option<&str>) -> Result<JsValue> {
	let mut outcome = serde_json::json!({ "status": status });
	if let Some(reason) = reason {
		outcome["reason"] = reason.into();
	}
	json(&outcome.to_string())
}

pub(super) fn acquisition(result: core::result::Result<(), rooms_glowcap::client::Error>) -> Result<JsValue> {
	match result {
		Ok(()) => submission("committed", None),
		Err(error) => failed(error),
	}
}

pub(super) fn failed(error: rooms_glowcap::client::Error) -> Result<JsValue> {
	use rooms_glowcap::client::Error;
	let conflict = match &error {
		Error::WorkspaceConflict => true,
		Error::Binding(error) => {
			error.kind() == glowcap::ErrorKind::Broken
				&& matches!(error.message(), Some("RevisionConflict" | "OperationConflict"))
		}
		_ => false,
	};
	let status = if conflict {
		"conflict"
	} else if error.refused() {
		"refused"
	} else {
		"uncertain"
	};
	submission(status, Some(&error.to_string()))
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
				Ok(()) => submission("committed", None),
				Err(error) => failed(error),
			}
		})
	}
}
