//! Retained management requests distinguish a proved admission conflict from
//! a refusal that admitted nothing and from a missing acknowledgement. Only a
//! conflict permits explicit reapplication, only an acknowledgement that never
//! came keeps the request for replay, and a refusal frees it with its reason.
use super::*;

/// Preserve terminal diagnostic data separately from a failed result read.
pub(super) fn result(value: core::result::Result<Argument, rooms_glowcap::client::Error>) -> Result<JsValue> {
	match value {
		Ok(value) => committed_data(&value),
		Err(
			error
			@ (rooms_glowcap::client::Error::Observation(_) | rooms_glowcap::client::Error::RefusedObservation(_)),
		) => {
			let known_absent = error.known_absent();
			let error = RuntimeError::from(error);
			json(&serde_json::json!({"observationFailure": error.to_string(), "knownAbsent": known_absent, "failure": crate::failure::project(&error).value()}).to_string())
		}
		Err(error) => Err(error.into()),
	}
}

/// A submitted request's outcome as the page reads it: `committed`, a proved
/// `conflict`, a `refused` request the peer admitted nothing of, or
/// `uncertain` when nothing settled the question. Every outcome but the
/// first carries the reason the client saw.
fn submission(status: &str, error: Option<&RuntimeError>) -> Result<JsValue> {
	let mut outcome = serde_json::json!({ "status": status });
	if let Some(error) = error {
		outcome["reason"] = error.to_string().into();
		outcome["failure"] = crate::failure::project(error).value();
	}
	json(&outcome.to_string())
}

pub(super) fn acquisition(result: core::result::Result<(), rooms_glowcap::client::Error>) -> Result<JsValue> {
	match result {
		Ok(()) => submission("committed", None),
		Err(error) => failed(error),
	}
}

/// A session command reads like an acquisition, except that an admitted one
/// reports its receipt's status (`pending`, `committed`, `unsent`, `unknown`)
/// and the session's own admission conflict arrives as a status.
pub(super) fn command(
	result: core::result::Result<rooms_glowcap::client::workspace::EffectStatus, rooms_glowcap::client::Error>,
) -> Result<JsValue> {
	match result {
		Ok(status) => submission(status.wire(), None),
		Err(error) => failed(error),
	}
}

pub(super) fn failed(error: rooms_glowcap::client::Error) -> Result<JsValue> {
	use rooms_glowcap::client::Error;
	let conflict = matches!(&error, Error::WorkspaceConflict | Error::ControlConflict(_));
	// Only a proved absence is a refusal: a bare break, a closed connection,
	// or a missed deadline leaves the outcome unknown and the request held.
	let status = if conflict {
		"conflict"
	} else if error.known_absent() {
		"refused"
	} else {
		"uncertain"
	};
	submission(status, Some(&error.into()))
}
