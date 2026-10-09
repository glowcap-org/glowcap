//! Admission of a reader's explicit timeline endpoint. Stored values are
//! validated without rewriting the spelling chosen by the operator.
pub(crate) fn parse_endpoint(value: &str) -> Result<url::Url, &'static str> {
	if value != value.trim_matches(crate::text::js_whitespace) {
		return Err("The visualizer endpoint cannot begin or end with whitespace.");
	}
	let url = url::Url::parse(value).map_err(|_| "The visualizer endpoint must be a complete WebSocket URL.")?;
	if !matches!(url.scheme(), "ws" | "wss") {
		return Err("The visualizer endpoint must use ws:// or wss://.");
	}
	Ok(url)
}
