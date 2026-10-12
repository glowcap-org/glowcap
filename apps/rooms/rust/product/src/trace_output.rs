//! Human presentation belongs to the executable. Remote labels are escaped
//! before reaching the terminal. JSON retains every field, including unknowns.
use rooms_services::trace_view::Output;
use std::io::Write;

pub fn write(output: Output) -> Result<(), String> {
	let text = match output {
		Output::Capability(link) => link,
		Output::Record { value, json } => {
			if json {
				value.to_string()
			} else {
				line(&value)
			}
		}
	};
	writeln!(std::io::stdout().lock(), "{text}").map_err(|e| format!("writing trace failed: {e}"))
}
fn line(record: &serde_json::Value) -> String {
	let field = |name, fallback| {
		record
			.get(name)
			.and_then(serde_json::Value::as_str)
			.unwrap_or(fallback)
			.chars()
			.flat_map(char::escape_debug)
			.collect::<String>()
	};
	let session = field("session", "-");
	match record["kind"].as_str() {
		Some("trace.replay-end") => "---- replay complete, live from here".into(),
		Some("ocapn.session-opened") => format!(
			"open  {session}  {} -> {}  {}",
			field("a", "?"),
			field("b", "?"),
			field("transport", "?")
		),
		Some("ocapn.message-decoded") => format!(
			"msg   {session}  {} {}  {}B",
			if record["outbound"] == true { "->" } else { "<-" },
			field("op", "?"),
			record["len"]
		),
		Some("ocapn.session-closed") => format!("close {session}  {}", field("reason", "closed")),
		_ => record.to_string(),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn remote_labels_cannot_control_the_terminal_and_unknown_events_stay_visible() {
		let record = serde_json::json!({"kind":"ocapn.session-opened","session":"p1/s1","a":"\u{1b}[2J\nnext","b":"β","transport":"tcp"});
		let printed = line(&record);
		assert!(!printed.contains(['\n', '\u{1b}']));
		assert!(printed.contains("β"));
		let unknown = serde_json::json!({"kind":"new-event","extra":"retained"});
		assert_eq!(
			serde_json::from_str::<serde_json::Value>(&line(&unknown)).unwrap(),
			unknown
		);
	}
}
