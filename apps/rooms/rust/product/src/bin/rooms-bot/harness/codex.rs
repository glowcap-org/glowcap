//! Codex, driven as `codex exec --json`. Each conversation gets its own
//! `CODEX_HOME` holding only a link to the operator's sign-in, which drops
//! the operator's configuration, instruction files, hooks, and MCP servers.
//! The prompt travels on stdin.
use super::{
	FailureKind, Harness, Invocation, Permission, Prepare, Signal, Turn,
	lines::{self, exit_detail, resumable, session, str_at},
};
use std::{ffi::OsString, path::PathBuf};

/// What Codex says when the account cannot use the requested model.
const MODEL_REFUSAL: &str = "is not supported when using Codex with a ChatGPT account";

/// The Codex adapter.
pub struct Codex {
	/// The operator's sign-in file, when its directory could be found.
	auth: Option<PathBuf>,
}

impl Codex {
	pub fn new(auth: Option<PathBuf>) -> Self {
		Self { auth }
	}

	/// Find the sign-in the way Codex does: `CODEX_HOME`, else `~/.codex`.
	/// This reads the environment once when `serve` builds the adapter.
	pub fn from_environment() -> Self {
		let home = std::env::var_os("CODEX_HOME")
			.map(PathBuf::from)
			.or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")));
		Self::new(home.map(|home| home.join("auth.json")))
	}
}

/// A string as a TOML basic string, the form a `-c` override takes.
fn toml_string(text: &str) -> String {
	// JSON escapes everything TOML requires except DEL.
	serde_json::Value::from(text).to_string().replace('\u{7f}', "\\u007f")
}

/// What a Codex failure message means. Codex gives only text, so the kind
/// comes from the model refusal's recorded wording, from an HTTP status the
/// text names first as `status <number>` or `status: <number>`, which
/// `status_kind` maps, or from Codex's usage-limit wording. Anything else is
/// a crash, and the room and `status` read only fixed words for it. A
/// signed-out Codex ends its turn with `turn.failed` and the message
/// `unexpected status 401 Unauthorized: ...`, which the status names.
fn kind(message: &str) -> FailureKind {
	if message.contains(MODEL_REFUSAL) {
		return FailureKind::Declined;
	}
	if message.contains("usage limit") || message.contains("usage_limit_reached") {
		return FailureKind::UsageLimit;
	}
	// Codex leads with the status it reports, and a body after it may say
	// "status" in other ways, so the first one that names a number decides.
	message
		.split("status")
		.skip(1)
		.find_map(|rest| {
			let rest = rest.trim_start_matches(':').trim_start();
			let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
			digits.parse::<u64>().ok()
		})
		.and_then(super::lines::status_kind)
		.unwrap_or(FailureKind::Crash)
}

impl Harness for Codex {
	fn name(&self) -> &'static str {
		"codex"
	}

	fn program(&self) -> OsString {
		"codex".into()
	}

	fn supports(&self, permission: Permission, _home: &std::path::Path) -> Result<(), String> {
		if self.auth.is_none() {
			return Err("the Codex sign-in cannot be found. Set HOME or CODEX_HOME".into());
		}
		match permission {
			Permission::Full => Ok(()),
			// The workspace-write sandbox confines writes but not reads, so a
			// safe run could still read the bot's session link, and its network
			// lock stops the glowcap actions from reaching the session.
			Permission::Safe => Err(
				"Codex cannot be held to its working directory, because its sandbox confines writes but not reads. \
				 Use --permission full, in a container or as a separate user if the machine matters"
					.into(),
			),
		}
	}

	/// The same arguments serve both permissions because `supports` refuses a
	/// safe run before any turn starts.
	fn invocation(&self, turn: &Turn<'_>) -> Invocation {
		let home = turn.state.to_path_buf();
		let resume = resumable(turn.session);
		let mut args: Vec<OsString> = vec!["exec".into()];
		if resume.is_some() {
			args.push("resume".into());
		}
		args.extend(["--json", "--skip-git-repo-check", "--strict-config"].map(OsString::from));
		if resume.is_none() {
			args.push("--ignore-rules".into());
		}
		if let Some(model) = turn.model {
			args.extend(["-m".into(), model.into()]);
		}
		args.push("--dangerously-bypass-approvals-and-sandbox".into());
		args.extend([
			"-c".into(),
			format!("developer_instructions={}", toml_string(turn.system)).into(),
		]);
		match &resume {
			Some(session) => args.push(session.into()),
			None => args.extend(["-C".into(), turn.workdir.into()]),
		}
		let mut prepare = vec![Prepare::Dir(home.clone())];
		if let Some(auth) = &self.auth {
			prepare.push(Prepare::Link {
				target: auth.clone(),
				at: home.join("auth.json"),
			});
		}
		Invocation {
			program: self.program(),
			args,
			env: vec![("CODEX_HOME".into(), home.into())],
			stdin: Some(turn.prompt.to_owned()),
			prepare,
			resume,
		}
	}

	/// Messages arrive whole and nothing marks the last one as final, so each
	/// is `Text` that replaces the one before. A clean exit promotes the last to
	/// the answer. A failure line outranks any text. Resuming an unknown but
	/// well-formed id starts a new thread, so the thread id is always reported
	/// for the runner to compare with the requested one.
	fn read(&self, line: &str) -> Vec<Signal> {
		let Some(line) = lines::parse(line) else {
			return Vec::new();
		};
		match str_at(&line, "/type") {
			Some("thread.started") => session(str_at(&line, "/thread_id")).into_iter().collect(),
			Some("item.started") if str_at(&line, "/item/type") == Some("command_execution") => {
				vec![Signal::Activity]
			}
			Some("item.completed") if str_at(&line, "/item/type") == Some("agent_message") => {
				str_at(&line, "/item/text")
					.map(|text| Signal::Text(text.to_owned()))
					.into_iter()
					.collect()
			}
			Some("turn.failed") => {
				let message = str_at(&line, "/error/message").unwrap_or("the turn failed");
				vec![Signal::Failure(kind(message), message.to_owned())]
			}
			_ => Vec::new(),
		}
	}

	/// Resuming a thread that has no stored rollout exits 1 with the reason on
	/// stderr and no stream. That is a crash like every other failed exit.
	fn exit(&self, code: Option<i32>, stderr_tail: &str) -> Option<(FailureKind, String)> {
		(code != Some(0)).then(|| (kind(stderr_tail), exit_detail(code, stderr_tail)))
	}
}

#[cfg(test)]
mod tests;
