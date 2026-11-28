//! Pi, driven as `pi --mode json -p`. Every run turns off extensions, skills,
//! prompt templates, context files, and MCP, and keeps the sign-in. The prompt
//! travels on stdin. Pi has no sandbox, so a safe run is refused.
use super::{
	FailureKind, Harness, Invocation, Permission, Prepare, Signal, Turn,
	lines::{self, exit_detail, resumable, session, status_kind, str_at},
};
use serde_json::Value;
use std::ffi::OsString;

/// The Pi adapter.
pub struct Pi;

/// What a provider error message means. Pi reports `<status>: <body>` for
/// provider errors, and the expired sign-in text is recorded. A usage limit
/// has not been recorded, so it is recognized only by a 429 status.
fn kind(message: &str) -> FailureKind {
	let status = message
		.split_once(':')
		.and_then(|(status, _)| status.trim().parse::<u64>().ok());
	if let Some(kind) = status.and_then(status_kind) {
		return kind;
	}
	if message.contains("OAuth refresh failed") {
		return FailureKind::SignIn;
	}
	FailureKind::Crash
}

fn failure(message: &str) -> Signal {
	Signal::Failure(kind(message), message.to_owned())
}

/// The text blocks of one assistant message, joined.
fn answer(message: &Value) -> String {
	let blocks = message.get("content").and_then(Value::as_array);
	let texts = blocks
		.into_iter()
		.flatten()
		.filter(|block| str_at(block, "/type") == Some("text"))
		.filter_map(|block| str_at(block, "/text"));
	texts.collect::<String>().trim().to_owned()
}

/// A run ends at `agent_end` only when `willRetry` is false. The last
/// assistant message then says whether the model call failed.
fn ended(line: &Value) -> Vec<Signal> {
	if line.get("willRetry").and_then(Value::as_bool) == Some(true) {
		return Vec::new();
	}
	let last = line
		.get("messages")
		.and_then(Value::as_array)
		.and_then(|messages| messages.iter().rev().find(|m| str_at(m, "/role") == Some("assistant")));
	match last {
		Some(message) if str_at(message, "/stopReason") == Some("error") => {
			let reason = str_at(message, "/errorMessage").unwrap_or("the model call failed");
			vec![failure(reason)]
		}
		_ => Vec::new(),
	}
}

impl super::ScheduledHarness for Pi {
	fn scheduled_invocation(&self, turn: &Turn<'_>) -> Invocation {
		let mut args: Vec<OsString> = [
			"--mode",
			"json",
			"-p",
			"--no-session",
			"--no-tools",
			"--exclude-tools",
			"*",
			"--no-extensions",
			"--no-mcp",
			"--no-skills",
			"--no-prompt-templates",
			"--no-context-files",
			"--no-themes",
			"--no-approve",
			"--system-prompt",
			turn.system,
		]
		.map(OsString::from)
		.into();
		if let Some(model) = turn.model {
			args.extend(["--model".into(), model.into()]);
		}
		Invocation {
			program: self.program(),
			args,
			env: vec![],
			stdin: Some(turn.prompt.into()),
			prepare: vec![],
			resume: None,
		}
	}
}

impl Harness for Pi {
	fn scheduled(&self) -> Option<&dyn super::ScheduledHarness> {
		Some(self)
	}
	fn name(&self) -> &'static str {
		"pi"
	}

	fn program(&self) -> OsString {
		"pi".into()
	}

	fn supports(&self, permission: Permission, _home: &std::path::Path) -> Result<(), String> {
		match permission {
			Permission::Full => Ok(()),
			Permission::Safe => Err(
				"Pi has no sandbox or approval mode, so it cannot be held to its working directory. \
				 Use --permission full, in a container or as a separate user if the machine matters"
					.into(),
			),
		}
	}

	/// The same arguments serve both permissions because `supports` refuses a
	/// safe run before any turn starts. The session directory is private to the
	/// conversation, and the first turn lets Pi choose the session id.
	fn invocation(&self, turn: &Turn<'_>) -> Invocation {
		let sessions = turn.state.to_path_buf();
		let resume = resumable(turn.session);
		let mut args: Vec<OsString> = ["--mode", "json", "-p", "--session-dir"].map(OsString::from).into();
		args.push(sessions.clone().into());
		if let Some(session) = &resume {
			args.extend(["--session".into(), session.into()]);
		}
		if let Some(model) = turn.model {
			args.extend(["--model".into(), model.into()]);
		}
		args.extend(["--append-system-prompt".into(), turn.system.into()]);
		args.extend(
			[
				"--no-extensions",
				"--no-skills",
				"--no-prompt-templates",
				"--no-context-files",
				"--no-mcp",
			]
			.map(OsString::from),
		);
		Invocation {
			program: self.program(),
			args,
			env: Vec::new(),
			stdin: Some(turn.prompt.to_owned()),
			prepare: vec![Prepare::Dir(sessions)],
			resume,
		}
	}

	fn text_is_delta(&self) -> bool {
		true
	}

	/// Text is read as deltas, and the answer is the text of the assistant
	/// message that stopped normally. The exit status is 0 even when the model
	/// call failed, so failures come from the stream: the last `agent_end`, or
	/// a retry that gave up. A run is over at `agent_settled`, and the lines
	/// between a failed `agent_end` and its retry are not failures.
	fn read(&self, line: &str) -> Vec<Signal> {
		let Some(line) = lines::parse(line) else {
			return Vec::new();
		};
		match str_at(&line, "/type") {
			Some("session") => session(str_at(&line, "/id")).into_iter().collect(),
			Some("message_update") if str_at(&line, "/assistantMessageEvent/type") == Some("text_delta") => {
				str_at(&line, "/assistantMessageEvent/delta")
					.map(|delta| Signal::Text(delta.to_owned()))
					.into_iter()
					.collect()
			}
			Some("tool_execution_start") => vec![Signal::Activity],
			Some("message_end")
				if str_at(&line, "/message/role") == Some("assistant")
					&& str_at(&line, "/message/stopReason") == Some("stop") =>
			{
				line.get("message")
					.map(|message| Signal::Final(answer(message)))
					.into_iter()
					.collect()
			}
			Some("agent_end") => ended(&line),
			Some("auto_retry_end") if line.get("success").and_then(Value::as_bool) == Some(false) => {
				vec![failure(str_at(&line, "/finalError").unwrap_or("the model call failed"))]
			}
			Some("agent_settled") if line.get("aborted").and_then(Value::as_bool) == Some(true) => {
				vec![Signal::Failure(FailureKind::Crash, "the run was aborted".into())]
			}
			_ => Vec::new(),
		}
	}

	/// A missing key and an unknown model or provider exit 1 with the reason on
	/// stderr. An unknown session is a crash, so a run that never reached its
	/// session starts a fresh one, as the other harnesses' lost sessions do. A
	/// signal or any other status is a crash.
	fn exit(&self, code: Option<i32>, stderr_tail: &str) -> Option<(FailureKind, String)> {
		if code == Some(0) {
			return None;
		}
		let refused = ["Model \"", "Unknown provider"]
			.iter()
			.any(|text| stderr_tail.contains(text));
		let kind = if stderr_tail.contains("No API key found") {
			FailureKind::SignIn
		} else if refused {
			FailureKind::Declined
		} else {
			FailureKind::Crash
		};
		Some((kind, exit_detail(code, stderr_tail)))
	}
}

#[cfg(test)]
mod tests;
