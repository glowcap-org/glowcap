//! `/reset`: a line that asks the bot to start a new conversation with its
//! agent. The agent's saved conversation for that Rooms conversation is
//! dropped before the turn runs, and the bot says so in one line.

/// The line the bot posts when a reset is the whole of what it was asked.
pub const CONFIRMED: &str = "Started a new conversation. I no longer remember what was said here before.";

/// Whether `text` is exactly `/reset`, apart from mentions of the bot that
/// carried it into a room.
pub fn asks(text: &str) -> bool {
	let mut words = text.split_whitespace().filter(|word| !word.starts_with('@'));
	words.next() == Some("/reset") && words.next().is_none() && text.split_whitespace().count() <= 2
}

#[cfg(test)]
mod tests {
	use super::asks;

	#[test]
	fn only_a_line_that_is_exactly_reset_asks_for_one() {
		for yes in ["/reset", "  /reset\n", "@helper /reset", "/reset @helper"] {
			assert!(asks(yes), "{yes:?}");
		}
		for no in [
			"",
			"/reset now",
			"please /reset",
			"/RESET",
			"/resets",
			"@a @b /reset",
			"@helper",
		] {
			assert!(!asks(no), "{no:?}");
		}
	}
}
