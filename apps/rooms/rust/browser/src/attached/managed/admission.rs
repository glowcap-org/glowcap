//! Embeddings select startup policy explicitly. Saved workspace data cannot
//! replace live accounting. The portable Settings parser owns validation.
use super::Result;
use rooms_application::admission::Settings;

pub(super) fn settings(encoded: Option<&str>) -> Result<Settings> {
	let Some(encoded) = encoded else {
		return Ok(Settings::defaults(4096, 8));
	};
	if encoded.len() > 8192 {
		return Err("Admission configuration exceeds 8192 bytes".into());
	}
	let values: std::collections::BTreeMap<String, String> =
		serde_json::from_str(encoded).map_err(|e| e.to_string())?;
	if values.keys().any(|key| !Settings::OPTIONS.contains(&key.as_str())) {
		return Err("Unknown admission configuration option".into());
	}
	Settings::parse(|key| values.get(key).cloned(), 4096, 8).map_err(String::from)
}
