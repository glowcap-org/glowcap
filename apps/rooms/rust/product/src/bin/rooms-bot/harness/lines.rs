//! Reading helpers the adapters share: one JSON object per line, UUID checks
//! for session ids, and the one-line cut of an agent's error output.
use super::{FailureKind, Signal};
use serde_json::Value;

/// The longest error line the bot quotes from an agent, in characters.
const LINE_CHARS: usize = 80;

/// The JSON object a line holds. Anything else is not a harness event.
pub fn parse(line: &str) -> Option<Value> {
	serde_json::from_str::<Value>(line).ok().filter(Value::is_object)
}

/// The string at a JSON pointer such as `/message/role`.
pub fn str_at<'a>(value: &'a Value, pointer: &str) -> Option<&'a str> {
	value.pointer(pointer).and_then(Value::as_str)
}

/// Whether a harness session id has the 8-4-4-4-12 hexadecimal form every
/// supported harness uses. An id is untrusted input to a command line, so
/// nothing else is ever passed on.
pub fn is_uuid(id: &str) -> bool {
	id.len() == 36
		&& id.bytes().enumerate().all(|(at, byte)| match at {
			8 | 13 | 18 | 23 => byte == b'-',
			_ => byte.is_ascii_hexdigit(),
		})
}

/// A session signal for an id a harness reported, when it has the expected
/// form. A malformed id is dropped so it can never be stored and resumed.
pub fn session(id: Option<&str>) -> Option<Signal> {
	id.filter(|id| is_uuid(id)).map(|id| Signal::Session(id.to_owned()))
}

/// The session to resume, when the stored one is well formed. A damaged
/// sessions file starts a fresh conversation instead of reaching a command line.
pub fn resumable(session: Option<&str>) -> Option<String> {
	session.filter(|id| is_uuid(id)).map(str::to_owned)
}

/// Text flattened to one line and cut to [`LINE_CHARS`].
fn shorten(text: &str) -> String {
	let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
	if flat.chars().count() <= LINE_CHARS {
		return flat;
	}
	let mut cut: String = flat.chars().take(LINE_CHARS - 3).collect();
	cut.push_str("...");
	cut
}

/// What an HTTP status in a provider error means for the turn. Other
/// statuses carry no fixed meaning, so they stay unclassified.
pub fn status_kind(status: u64) -> Option<FailureKind> {
	match status {
		401 | 403 => Some(FailureKind::Auth),
		429 => Some(FailureKind::RateLimit),
		_ => None,
	}
}

/// The line a failed exit reports. A signal explains itself, so stderr is not
/// quoted as its cause. A status with stderr text quotes the text, without the
/// warnings an agent prints on every run.
pub fn exit_detail(code: Option<i32>, stderr_tail: &str) -> String {
	let Some(code) = code else {
		return "the agent was ended by a signal".to_owned();
	};
	let errors: Vec<&str> = stderr_tail
		.lines()
		.map(str::trim)
		.filter(|line| !line.is_empty() && !line.starts_with("WARNING:"))
		.collect();
	if errors.is_empty() {
		return format!("the agent exited with status {code}");
	}
	shorten(&errors.join(" "))
}

#[cfg(test)]
pub fn words(invocation: &super::Invocation) -> Vec<String> {
	invocation
		.args
		.iter()
		.map(|arg| arg.to_string_lossy().into_owned())
		.collect()
}

#[cfg(test)]
pub fn replay(harness: &dyn super::Harness, fixture: &str) -> Vec<Signal> {
	fixture.lines().flat_map(|line| harness.read(line)).collect()
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn session_ids_must_have_the_uuid_form() {
		assert!(is_uuid("01a1fcd3-8dff-72f3-987e-070caf3d1096"));
		for bad in [
			"",
			"garbage",
			"01a1fcd3-8dff-72f3-987e-070caf3d109",
			"--model=x-8dff-72f3-987e-070caf3d1096",
		] {
			assert!(!is_uuid(bad), "{bad}");
		}
		assert_eq!(resumable(Some("-p")), None);
	}

	#[test]
	fn an_exit_is_explained_by_its_status_and_not_by_a_warning() {
		let warning = "WARNING: proceeding, even though we could not create PATH aliases\n";
		assert_eq!(exit_detail(None, warning), "the agent was ended by a signal");
		assert_eq!(exit_detail(Some(1), warning), "the agent exited with status 1");
		assert_eq!(
			exit_detail(Some(1), &format!("{warning}Error: no rollout found\n")),
			"Error: no rollout found"
		);
	}

	#[test]
	fn an_error_line_is_one_short_line() {
		assert_eq!(shorten("ls  -la\n/"), "ls -la /");
		assert!(shorten(&"x".repeat(500)).chars().count() <= LINE_CHARS);
	}

	#[test]
	fn only_objects_parse() {
		assert!(parse("[1]").is_none());
		assert!(parse("not json").is_none());
		assert!(parse("{}").is_some());
	}
}
