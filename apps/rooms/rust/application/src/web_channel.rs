//! Application-authored browser byte-channel advice preserves the deployment's
//! exact route. Channel reachability supplies no capability or peer proof.
pub const HINT: &str = "captp-websocket";
pub const MAX_ENDPOINT_BYTES: usize = 2048;

/// Credentials and capability tokens stay outside channel routing. Validate
/// without rewriting the supplied endpoint, including deployment prefixes.
pub fn endpoint(raw: &str) -> Result<url::Url, &'static str> {
	if raw.len() > MAX_ENDPOINT_BYTES
		|| raw
			.bytes()
			.any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
	{
		return Err("byte-channel endpoint exceeds its bound or contains whitespace or controls");
	}
	let parsed = url::Url::parse(raw).map_err(|_| "byte-channel endpoint must be a websocket URL")?;
	if !matches!(parsed.scheme(), "ws" | "wss")
		|| parsed.host_str().is_none()
		|| !parsed.username().is_empty()
		|| parsed.password().is_some()
		|| parsed.fragment().is_some()
		|| parsed.query().is_some()
	{
		return Err("byte-channel endpoint must use ws or wss without credentials, query or fragment");
	}
	Ok(parsed)
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn endpoint_preserves_paths_and_refuses_ambiguous_authority() {
		let exact = "wss://example.test/deployment/captp%2Fchannel";
		assert_eq!(endpoint(exact).unwrap().as_str(), exact);
		for invalid in [
			"https://example.test/captp",
			"ws://user@example.test/captp",
			"ws://example.test/captp?cap=secret",
			"ws://example.test/captp#fragment",
			" ws://example.test/captp",
			"ws://example.test/cap\ttp",
		] {
			assert!(endpoint(invalid).is_err(), "{invalid}");
		}
	}
}
