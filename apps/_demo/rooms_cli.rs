//! Shared Rooms CLI helpers. The codes come from `rooms_codes.rs`, which
//! `browser_metadata` generates from the Rust `FailureCode` table.

/// The Rooms code a room's refusal carries at the front of its reason,
/// `<code>: <detail>`. Empty for any other failure, so a transport or
/// marshalling error is never mistaken for the room's answer.
pub fn error_code(err: &glowcap::Error) -> &str {
	err.application_message()
		.and_then(|reason| reason.split_once(": "))
		.map_or("", |(code, _)| code)
}

#[cfg(test)]
mod tests {
	use super::error_code;

	#[test]
	fn a_failure_that_is_not_a_broken_answer_carries_no_room_code() {
		let io = glowcap::Error::from(std::io::Error::other("no-such-room: no room named lobby"));
		assert_eq!(error_code(&io), "");
	}
}
