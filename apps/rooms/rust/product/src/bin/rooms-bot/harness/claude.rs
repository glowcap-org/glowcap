//! Claude Code, driven as `claude -p --output-format stream-json`. Every run
//! uses `--safe-mode`, which drops the operator's hooks, MCP servers, plugins,
//! and instruction files and keeps the sign-in, and reads settings only from
//! the operator's user settings, never from a `.claude` directory the agent
//! could write in its working directory. The prompt travels on stdin, and the
//! bot's instructions in a file beside the conversation's state.
use super::{
	FailureKind, Harness, Invocation, Permission, Prepare, Signal, Turn,
	lines::{self, exit_detail, resumable, session, status_kind, str_at},
};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// The tools a safe run offers. Each is limited by an allow rule below.
const SAFE_TOOLS: &str = "Read,Write,Edit,Bash";
/// The file in the conversation's state that holds the bot's instructions.
const SYSTEM_FILE: &str = "system.md";
/// What a safe run may never write, even inside its working directory: the
/// project settings a later run would otherwise read.
const SAFE_DENIED: [&str; 2] = ["Write(./.claude/**)", "Edit(./.claude/**)"];

/// The Claude Code adapter. A safe run may run the bot's own actions through
/// the executable at `glowcap`.
pub struct Claude {
	glowcap: PathBuf,
}

impl Claude {
	pub fn new(glowcap: &Path) -> Self {
		Self {
			glowcap: glowcap.to_owned(),
		}
	}

	/// The allow rules of a safe run. File tools take the path-scoped form,
	/// because a bare `Write` rule is not confined to the working directory:
	/// `./**` is the working directory, and `//<path>/**` the absolute home.
	/// The shell may run only the bot's own actions, never another glowcap
	/// command, because those can reach other sessions and other files.
	fn safe_rules(glowcap: &str, home: &str) -> Vec<String> {
		let mut rules = Vec::new();
		for tool in ["Read", "Write", "Edit"] {
			rules.push(format!("{tool}(./**)"));
		}
		for tool in ["Read", "Write", "Edit"] {
			rules.push(format!("{tool}(/{home}/**)"));
		}
		for verb in crate::bot::act::Verb::ALL.map(crate::bot::act::Verb::name) {
			rules.push(format!("Bash({glowcap} apps rooms bot {verb})"));
			rules.push(format!("Bash({glowcap} apps rooms bot {verb} *)"));
		}
		rules
	}
}

/// Characters a permission rule reads as more than a path: parentheses end
/// the rule, and the rest are pattern syntax that widens it, so a home at
/// `/bots/[ab]/home` would also match another bot's home.
const RULE_SYNTAX: [char; 11] = ['(', ')', '*', '?', '[', ']', '{', '}', '\\', '!', '#'];

/// A path a permission rule holds exactly: text with none of [`RULE_SYNTAX`].
fn rule_path(what: &str, path: &Path) -> Result<(), String> {
	match path.to_str() {
		Some(text) if !text.contains(RULE_SYNTAX) => Ok(()),
		_ => Err(format!(
			"the {what} {} cannot be written as a permission rule. Use a path without any of {}",
			path.display(),
			RULE_SYNTAX.iter().collect::<String>()
		)),
	}
}

/// What a failure's error name and status mean. The names and the 404 are what
/// the model and sign-in failures reported. A rate limit is recognized only
/// by its 429 status and a service outage by 5xx. Any other
/// name stays a crash until a recorded run shows its shape.
fn kind(error: Option<&str>, status: Option<u64>) -> FailureKind {
	match (error, status) {
		(Some("authentication_failed"), _) => FailureKind::SignIn,
		(Some("model_not_found"), _) | (_, Some(404)) => FailureKind::Declined,
		(_, Some(status)) => status_kind(status).unwrap_or(FailureKind::Crash),
		_ => FailureKind::Crash,
	}
}

fn text_of(block: &Value) -> Option<&str> {
	str_at(block, "/text").filter(|text| !text.is_empty())
}

fn assistant(line: &Value) -> Vec<Signal> {
	let blocks = line.pointer("/message/content").and_then(Value::as_array);
	let blocks = blocks.map_or(&[][..], Vec::as_slice);
	if let Some(error) = str_at(line, "/error") {
		let status = line.get("api_error_status").and_then(Value::as_u64);
		let detail = blocks.iter().find_map(text_of).unwrap_or(error);
		return vec![Signal::Failure(kind(Some(error), status), detail.to_owned())];
	}
	blocks
		.iter()
		.filter_map(|block| match str_at(block, "/type") {
			Some("tool_use") => Some(Signal::Activity),
			Some("text") => text_of(block).map(|text| Signal::Text(text.to_owned())),
			_ => None,
		})
		.collect()
}

/// The `result` line ends a run. Its subtype says `success` even for a failed
/// model call, so only `is_error` tells the two apart.
fn result(line: &Value) -> Vec<Signal> {
	let text = str_at(line, "/result");
	match line.get("is_error").and_then(Value::as_bool) {
		Some(false) => text.map(|text| Signal::Final(text.to_owned())).into_iter().collect(),
		Some(true) => {
			let status = line.get("api_error_status").and_then(Value::as_u64);
			let detail = str_at(line, "/errors/0")
				.or(text)
				.unwrap_or("the harness reported an error");
			let sign_in = text.is_some_and(|text| text.contains("Please run /login"));
			let kind = if sign_in {
				FailureKind::SignIn
			} else {
				kind(None, status)
			};
			vec![Signal::Failure(kind, detail.to_owned())]
		}
		None => Vec::new(),
	}
}

impl super::ScheduledHarness for Claude {
	fn scheduled_invocation(&self, turn: &Turn<'_>) -> Invocation {
		let mut args: Vec<std::ffi::OsString> = [
			"-p",
			"--output-format",
			"stream-json",
			"--verbose",
			"--safe-mode",
			"--restricted",
			"--strict-mcp-config",
			"--settings",
			r#"{"disableAllHooks":true}"#,
			"--disable-slash-commands",
			"--no-chrome",
			"--no-session-persistence",
			"--permission-mode",
			"dontAsk",
			"--permission-prompts",
			"none",
			"--tools",
			"",
			"--system-prompt",
			turn.system,
		]
		.map(Into::into)
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

impl Harness for Claude {
	fn scheduled(&self) -> Option<&dyn super::ScheduledHarness> {
		Some(self)
	}
	fn name(&self) -> &'static str {
		"claude"
	}

	fn program(&self) -> std::ffi::OsString {
		"claude".into()
	}

	fn supports(&self, permission: Permission, home: &Path) -> Result<(), String> {
		if permission == Permission::Full {
			return Ok(());
		}
		rule_path("glowcap path", &self.glowcap)?;
		rule_path("bot directory", home)?;
		Ok(())
	}

	fn invocation(&self, turn: &Turn<'_>) -> Invocation {
		let system = turn.state.join(SYSTEM_FILE);
		let mut args: Vec<std::ffi::OsString> = [
			"-p",
			"--output-format",
			"stream-json",
			"--verbose",
			"--safe-mode",
			"--setting-sources",
			"user",
			"--system-prompt-snapshot",
			"off",
		]
		.map(Into::into)
		.into();
		args.extend(["--append-system-prompt-file".into(), system.clone().into()]);
		if let Some(model) = turn.model {
			args.extend(["--model".into(), model.into()]);
		}
		let resume = resumable(turn.session);
		if let Some(session) = &resume {
			args.extend(["--resume".into(), session.into()]);
		}
		match turn.permission {
			Permission::Full => args.push("--dangerously-skip-permissions".into()),
			Permission::Safe => {
				args.extend(["--permission-mode".into(), "dontAsk".into()]);
				args.extend(["--tools".into(), SAFE_TOOLS.into()]);
				// Variadic, so each list ends where the next flag starts.
				args.push("--disallowedTools".into());
				args.extend(SAFE_DENIED.map(Into::into));
				args.push("--allowedTools".into());
				args.extend(
					Self::safe_rules(&self.glowcap.to_string_lossy(), &turn.home.to_string_lossy())
						.into_iter()
						.map(Into::into),
				);
			}
		}
		Invocation {
			program: self.program(),
			args,
			env: vec![(
				"BASH_DEFAULT_TIMEOUT_MS".into(),
				crate::bot::act::CLAUDE_BASH_DEFAULT_MS.to_string().into(),
			)],
			stdin: Some(turn.prompt.to_owned()),
			prepare: vec![
				Prepare::Dir(turn.state.to_path_buf()),
				Prepare::File {
					at: system,
					contents: turn.system.to_owned(),
				},
			],
			resume,
		}
	}

	/// Text arrives as whole blocks because partial messages are not requested,
	/// so each block replaces the one before it and the result line carries the
	/// answer. Rate limit events are informational and never end a turn: a
	/// non-allowed status has not been recorded, so it is not read as a failure.
	fn read(&self, line: &str) -> Vec<Signal> {
		let Some(line) = lines::parse(line) else {
			return Vec::new();
		};
		match str_at(&line, "/type") {
			Some("system") if str_at(&line, "/subtype") == Some("init") => {
				session(str_at(&line, "/session_id")).into_iter().collect()
			}
			Some("assistant") => assistant(&line),
			Some("result") => result(&line),
			_ => Vec::new(),
		}
	}

	/// A model the account cannot use names itself on stderr. Other exits stay
	/// crashes until a recorded run shows an expired login or a usage limit
	/// reaching stderr.
	fn exit(&self, code: Option<i32>, stderr_tail: &str) -> Option<(FailureKind, String)> {
		if code == Some(0) {
			return None;
		}
		let kind = if stderr_tail.contains("[claude-code:unrecognized_model]") {
			FailureKind::Declined
		} else {
			FailureKind::Crash
		};
		Some((kind, exit_detail(code, stderr_tail)))
	}
}

#[cfg(test)]
mod tests;
