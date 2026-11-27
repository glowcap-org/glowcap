//! The instructions delivered to a harness and the facts of this turn.
use crate::bot::{
	actions::MAX_ACTIONS_PER_TURN,
	config::Config,
	reply::MAX_PARTS,
	rooms::{ConversationId, Kind},
};
use rooms_application::room::line::{MAX_LINE_BYTES, MAX_MESSAGE_FILES};
use std::{fmt::Write, os::unix::ffi::OsStrExt, path::Path};

const SYSTEM: &str = include_str!("../system.txt");

pub struct Facts<'a> {
	pub config: &'a Config,
	/// The bot's home, which every conversation shares.
	pub home: &'a Path,
	pub conversation: &'a ConversationId,
	pub kind: Kind,
	/// The operator's own instructions, added after the bot's.
	pub instructions: Option<&'a str>,
}

pub fn system(facts: &Facts<'_>) -> String {
	let kind = match facts.kind {
		Kind::Room => "room",
		Kind::Direct | Kind::Other => "direct conversation",
	};
	// The conversation id comes from the session, so it is written as a JSON
	// string: a newline or quote in it stays inside the value.
	let conversation = serde_json::Value::from(facts.conversation.as_str()).to_string();
	let mut text = fill(
		SYSTEM,
		&[
			("kind", kind.to_owned()),
			("limit", MAX_LINE_BYTES.to_string()),
			("parts", MAX_PARTS.to_string()),
			("actions", MAX_ACTIONS_PER_TURN.to_string()),
			("files", MAX_MESSAGE_FILES.to_string()),
			("conversation", conversation),
			("glowcap", shell_path(&facts.config.glowcap)),
			(
				"harness",
				serde_json::Value::from(facts.config.harness.as_str()).to_string(),
			),
			("permission", facts.config.permission.as_str().to_owned()),
			(
				"model",
				facts.config.model.as_deref().map_or_else(
					|| "The harness selects the model.".to_owned(),
					|name| format!("Rooms requested model {}.", serde_json::Value::from(name)),
				),
			),
			("home", shell_path(facts.home)),
		],
	);
	if let Some(instructions) = facts.instructions.map(str::trim).filter(|text| !text.is_empty()) {
		text.push_str("\nInstructions from the person who runs this bot\n");
		text.push_str(instructions);
		text.push('\n');
	}
	text
}

/// `template` with each `{name}` replaced by its value, in one pass, so a
/// value that holds a placeholder's form is kept as written.
fn fill(template: &str, values: &[(&str, String)]) -> String {
	let mut out = String::with_capacity(template.len());
	let mut rest = template;
	while let Some((before, after)) = rest.split_once('{') {
		out.push_str(before);
		let named = after.split_once('}').and_then(|(name, tail)| {
			values
				.iter()
				.find(|(known, _)| *known == name)
				.map(|(_, value)| (tail, value))
		});
		match named {
			Some((tail, value)) => {
				out.push_str(value);
				rest = tail;
			}
			None => {
				out.push('{');
				rest = after;
			}
		}
	}
	out.push_str(rest);
	out
}

/// One Bash word, also used to display a path in prose. Common absolute paths
/// read as written. Quoting keeps the other paths on one line and preserves
/// every byte that the shell will pass as the executable name.
fn shell_path(path: &Path) -> String {
	let bytes = path.as_os_str().as_bytes();
	if let Some(text) = path.to_str()
		&& !text
			.chars()
			.any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}'))
	{
		if !bytes.is_empty() && bytes.iter().all(|b| b.is_ascii_alphanumeric() || b"/._-".contains(b)) {
			return text.to_owned();
		}
		return format!("'{}'", text.replace('\'', "'\\''"));
	}
	let mut quoted = String::from("$'");
	for &byte in bytes {
		match byte {
			b'\'' | b'\\' => {
				quoted.push('\\');
				quoted.push(char::from(byte));
			}
			b' '..=b'~' => quoted.push(char::from(byte)),
			_ => write!(quoted, "\\{byte:03o}").expect("writing a string"),
		}
	}
	quoted.push('\'');
	quoted
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::{ffi::OsStr, process::Command};

	#[test]
	fn command_paths_stay_one_argument_and_one_prompt_line() {
		for bytes in [
			b"/opt/my bin/it's $(printf split)".as_slice(),
			b"/bin/a\n{home}\r\t",
			b"/srv/\xff\\\n",
		] {
			let word = shell_path(Path::new(OsStr::from_bytes(bytes)));
			assert!(!word.chars().any(char::is_control), "{word:?}");
			let out = Command::new("bash")
				.args(["-c", &format!("set -- {word}; [ \"$#\" = 1 ] && printf %s \"$1\"")])
				.output()
				.unwrap();
			assert!(out.status.success());
			assert_eq!(out.stdout, bytes);
		}
	}
}
