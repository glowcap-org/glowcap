//! The scripted adapter for process tests. It drives `rooms-bot-fake-harness`,
//! which obeys directives in its prompt. Only a build with the `test-support`
//! feature, or a test build, has it.
use super::{
	FailureKind, Harness, Invocation, Signal, Turn,
	lines::{resumable, session},
};
use serde_json::Value;

/// The scripted adapter.
pub struct Fake;

fn companion() -> std::ffi::OsString {
	std::env::current_exe()
		.ok()
		.and_then(|exe| exe.parent().map(|dir| dir.join("rooms-bot-fake-harness")))
		.map_or_else(|| "rooms-bot-fake-harness".into(), Into::into)
}

impl Harness for Fake {
	fn name(&self) -> &'static str {
		"fake"
	}
	fn program(&self) -> std::ffi::OsString {
		companion()
	}
	fn invocation(&self, turn: &Turn<'_>) -> Invocation {
		let mut args = Vec::new();
		let resume = resumable(turn.session);
		if let Some(session) = &resume {
			args.push("--resume".into());
			args.push(session.into());
		}
		args.push("--system".into());
		args.push(turn.system.into());
		if let Some(model) = turn.model {
			args.push("--model".into());
			args.push(model.into());
		}
		args.push("--permission".into());
		args.push(turn.permission.as_str().into());
		Invocation {
			program: self.program(),
			args,
			env: vec![("GLOWCAP_ROOMS_BOT_WORKDIR".into(), turn.workdir.into())],
			stdin: Some(turn.prompt.to_owned()),
			prepare: Vec::new(),
			resume,
		}
	}
	fn read(&self, line: &str) -> Vec<Signal> {
		let Ok(Value::Object(fields)) = serde_json::from_str::<Value>(line) else {
			return Vec::new();
		};
		let text = |key: &str| fields.get(key).and_then(Value::as_str).map(str::to_owned);
		let mut signals: Vec<_> = session(text("session").as_deref()).into_iter().collect();
		if text("activity").is_some() {
			signals.push(Signal::Activity);
		}
		if let Some(partial) = text("text") {
			signals.push(Signal::Text(partial));
		}
		if let Some(answer) = text("final") {
			signals.push(Signal::Final(answer));
		}
		if let Some(kind) = text("failure") {
			let kind = match kind.as_str() {
				"auth" => FailureKind::SignIn,
				"rate" => FailureKind::UsageLimit,
				"refused" => FailureKind::Declined,
				"outage" => FailureKind::Outage,
				_ => FailureKind::Crash,
			};
			signals.push(Signal::Failure(kind, text("message").unwrap_or_default()));
		}
		signals
	}
	fn exit(&self, code: Option<i32>, stderr_tail: &str) -> Option<(FailureKind, String)> {
		(code != Some(0)).then(|| (FailureKind::Crash, format!("exit {code:?}: {}", stderr_tail.trim())))
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn lines_become_signals_and_unknown_lines_nothing() {
		let fake = Fake;
		assert_eq!(
			fake.read(r#"{"session":"fa4e0000-0000-4000-8000-000000000001","final":"hi"}"#),
			vec![
				Signal::Session("fa4e0000-0000-4000-8000-000000000001".into()),
				Signal::Final("hi".into())
			]
		);
		assert_eq!(
			fake.read(r#"{"session":"s1","final":"hi"}"#),
			vec![Signal::Final("hi".into())],
			"a session that is not a UUID is dropped"
		);
		assert_eq!(
			fake.read(r#"{"failure":"auth","message":"no key"}"#),
			vec![Signal::Failure(FailureKind::SignIn, "no key".into())]
		);
		assert!(fake.read("not json").is_empty());
		assert!(fake.read(r#"{"other":1}"#).is_empty());
	}

	#[test]
	fn a_session_that_is_not_a_uuid_never_reaches_the_command_line() {
		let invocation = Fake.invocation(&Turn {
			prompt: "hello",
			system: "brief",
			session: Some("garbage"),
			workdir: std::path::Path::new("/w/work"),
			home: std::path::Path::new("/w/bot/home"),
			state: std::path::Path::new("/w/bot/harness/fake/c1"),
			model: None,
			permission: super::super::Permission::Full,
		});
		assert!(!invocation.args.iter().any(|arg| arg == "--resume"));
		assert_eq!(invocation.resume, None);
	}

	#[test]
	fn an_exit_without_an_answer_is_a_crash_unless_it_was_clean() {
		assert_eq!(Fake.exit(Some(0), ""), None);
		assert_eq!(
			Fake.exit(Some(3), "boom\n").map(|(kind, _)| kind),
			Some(FailureKind::Crash)
		);
	}
}
