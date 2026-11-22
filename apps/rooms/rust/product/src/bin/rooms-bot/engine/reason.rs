//! The reason a failure line gives. An agent's own message says what went
//! wrong, such as a provider error or a refused sign-in, but it is output of a
//! process the bot does not control. So it is cut to one short line and
//! stripped of anything that names a place on this machine or a link, before
//! a person in a room reads it.
use crate::bot::harness::FailureKind;
use std::path::Path;

/// The most bytes of an agent's message a reason keeps.
const MAX_CAUSE_BYTES: usize = 160;
const HIDDEN: &str = "[hidden]";

/// Whether a word names a file, a directory, or a link, anywhere in it: a
/// path can follow a name and `=`, `:`, or an opening bracket or quote.
fn private(word: &str, root: &str) -> bool {
	let named = |part: &str| {
		let bare = part.trim_start_matches(|c: char| !c.is_alphanumeric() && c != '/' && c != '~' && c != '.');
		bare.starts_with(['/', '~']) || bare.starts_with("./") || bare.starts_with("../") || bare.starts_with("ocapn")
	};
	(!root.is_empty() && word.contains(root))
		|| word.contains("://")
		|| word.split(['=', ':', ',', '(', '[', '<', '"', '\'']).any(named)
}

/// An agent's message as one short line without control characters, paths, or
/// links. `root` is the bot directory.
pub fn clean(message: &str, root: &Path) -> String {
	let root = root.to_string_lossy();
	let flat: String = message.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
	let words: Vec<&str> = flat
		.split_whitespace()
		.map(|word| if private(word, &root) { HIDDEN } else { word })
		.collect();
	crate::bot::reply::prefix(&words.join(" "), MAX_CAUSE_BYTES)
		.trim_end()
		.to_owned()
}

/// The reason for a failure of `kind`, with the agent's own message when it
/// gave one.
pub fn of(kind: FailureKind, message: Option<&str>, root: &Path) -> String {
	match message
		.map(|message| clean(message, root))
		.filter(|text| !text.is_empty())
	{
		Some(text) => format!("{}: {text}", kind.label()),
		None => kind.label().to_owned(),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	const ROOT: &str = "/home/ann/.local/share/bot";

	#[test]
	fn a_provider_error_stays_readable_on_one_line() {
		let text = clean("500: upstream\nunavailable\u{1b}[31m now", Path::new(ROOT));
		assert_eq!(text, "500: upstream unavailable [31m now");
	}

	#[test]
	fn paths_and_links_never_reach_a_person() {
		let text = clean(
			"cannot read /home/ann/.local/share/bot/session.link or ~/x and ocapn://abc.tcp/s/z (\"/etc/hosts\")",
			Path::new(ROOT),
		);
		assert!(
			!text.contains("/home") && !text.contains("ocapn") && !text.contains("etc"),
			"{text}"
		);
		assert!(text.contains(HIDDEN));
		let joined = clean(
			"cannot open file=/home/ann/.ssh/id or error:~/x (at:./y)",
			Path::new(ROOT),
		);
		assert_eq!(joined, "cannot open [hidden] or [hidden] [hidden]");
		assert_eq!(
			clean("model anthropic/claude-x not found", Path::new(ROOT)),
			"model anthropic/claude-x not found"
		);
	}

	#[test]
	fn a_long_message_is_cut_and_an_empty_one_is_left_out() {
		let long = "word ".repeat(100);
		assert!(clean(&long, Path::new(ROOT)).len() <= MAX_CAUSE_BYTES);
		assert_eq!(
			of(FailureKind::Crash, Some(" \n "), Path::new(ROOT)),
			FailureKind::Crash.label()
		);
		assert_eq!(
			of(FailureKind::RateLimit, Some("429: slow down"), Path::new(ROOT)),
			"the agent hit a usage limit: 429: slow down"
		);
	}
}
