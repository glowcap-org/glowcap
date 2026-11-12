//! Embeddings select startup policy explicitly. Saved workspace data cannot
//! replace live accounting. The portable Settings parser owns validation.
use super::Result;
use rooms_application::admission::{POOLED_AGGREGATE_SCALE, SESSION_ROWS, Settings};
use rooms_runtime::Error as RuntimeError;

pub(super) fn settings(encoded: Option<&str>) -> Result<Settings> {
	let Some(encoded) = encoded else {
		return Ok(Settings::defaults(SESSION_ROWS, POOLED_AGGREGATE_SCALE));
	};
	if encoded.len() > 8192 {
		return Err(RuntimeError::invalid("Admission configuration exceeds 8192 bytes"));
	}
	let values: std::collections::BTreeMap<String, String> =
		serde_json::from_str(encoded).map_err(RuntimeError::invalid_by)?;
	if values.keys().any(|key| !Settings::OPTIONS.contains(&key.as_str())) {
		return Err(RuntimeError::invalid("Unknown admission configuration option"));
	}
	Settings::parse(|key| values.get(key).cloned(), SESSION_ROWS, POOLED_AGGREGATE_SCALE)
		.map_err(RuntimeError::invalid_by)
}
