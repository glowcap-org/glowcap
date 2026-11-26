use super::*;
use crate::bot::harness::lines::{replay, words};
use std::path::Path;

const FIRST: &str = include_str!("../../../../../tests/bot_harness/codex/first.jsonl");
const RESUME: &str = include_str!("../../../../../tests/bot_harness/codex/resume.jsonl");
const DENIED: &str = include_str!("../../../../../tests/bot_harness/codex/denied.jsonl");
const FULL: &str = include_str!("../../../../../tests/bot_harness/codex/full.jsonl");
const FAIL_MODEL: &str = include_str!("../../../../../tests/bot_harness/codex/fail-model.jsonl");
const NEW_THREAD: &str = include_str!("../../../../../tests/bot_harness/codex/new-thread.jsonl");
const KILLED: &str = include_str!("../../../../../tests/bot_harness/codex/killed.jsonl");

const THREAD: &str = "01a1fcd3-8dff-72f3-987e-070caf3d1096";
const WORKDIR: &str = "/w/bot/work/c1";

fn codex() -> Codex {
	Codex::new(Some("/home/op/.codex/auth.json".into()))
}

fn turn(session: Option<&'static str>, model: Option<&'static str>, permission: Permission) -> Invocation {
	codex().invocation(&Turn {
		prompt: "hello",
		system: "be \"brief\"\nplease",
		session,
		workdir: Path::new(WORKDIR),
		home: Path::new("/w/bot/home"),
		state: Path::new("/w/bot/harness/codex/c1"),
		model,
		permission,
	})
}

const INSTRUCTIONS: &str = r#"developer_instructions="be \"brief\"\nplease""#;

fn strings(words: &[&str]) -> Vec<String> {
	words.iter().map(ToString::to_string).collect()
}

#[test]
fn full_bypasses_the_sandbox_first_and_on_resume() {
	let first = words(&turn(None, None, Permission::Full));
	assert!(first.contains(&"--dangerously-bypass-approvals-and-sandbox".to_owned()));
	assert!(!first.contains(&"-s".to_owned()));
	let resumed = words(&turn(Some(THREAD), None, Permission::Full));
	assert_eq!(
		resumed,
		strings(&[
			"exec",
			"resume",
			"--json",
			"--skip-git-repo-check",
			"--strict-config",
			"--dangerously-bypass-approvals-and-sandbox",
			"-c",
			INSTRUCTIONS,
			THREAD,
		])
	);
}

#[test]
fn every_run_gets_a_private_home_holding_only_the_sign_in() {
	let invocation = turn(None, None, Permission::Full);
	let home = PathBuf::from("/w/bot/harness/codex/c1");
	assert_eq!(invocation.env, vec![("CODEX_HOME".into(), home.clone().into())]);
	assert_eq!(
		invocation.prepare,
		vec![
			Prepare::Dir(home.clone()),
			Prepare::Link {
				target: "/home/op/.codex/auth.json".into(),
				at: home.join("auth.json")
			}
		]
	);
	assert_eq!(invocation.stdin.as_deref(), Some("hello"));
}

#[test]
fn a_session_that_is_not_a_uuid_never_reaches_the_command_line() {
	let invocation = turn(Some("garbage"), None, Permission::Full);
	assert!(!words(&invocation).contains(&"resume".to_owned()));
	assert_eq!(invocation.resume, None);
}

#[test]
fn a_missing_sign_in_is_refused_before_any_turn() {
	assert!(codex().supports(Permission::Full, Path::new("/w/bot/home")).is_ok());
	let lost = Codex::new(None);
	assert!(lost.supports(Permission::Full, Path::new("/w/bot/home")).is_err());
}

#[test]
fn a_safe_run_is_refused_because_reads_are_not_confined() {
	assert!(codex().supports(Permission::Safe, Path::new("/w/bot/home")).is_err());
}

#[test]
fn instructions_become_one_valid_toml_string() {
	assert_eq!(toml_string("a\\b\u{7f}\t"), "\"a\\\\b\\u007f\\t\"");
}

#[test]
fn messages_are_text_and_the_thread_is_the_session() {
	assert_eq!(
		replay(&codex(), FIRST),
		vec![Signal::Session(THREAD.into()), Signal::Text("pong".into())]
	);
	assert_eq!(
		replay(&codex(), RESUME),
		vec![Signal::Session(THREAD.into()), Signal::Text("tangerine".into())]
	);
}

#[test]
fn commands_are_activity() {
	let signals = replay(&codex(), FULL);
	assert_eq!(
		signals[1],
		Signal::Text("I’ll run that command in the workspace.".into())
	);
	assert_eq!(signals[2], Signal::Activity);
	assert_eq!(signals.last(), Some(&Signal::Text("done".into())));
}

#[test]
fn a_sandbox_that_blocked_every_command_still_ends_with_text() {
	let signals = replay(&codex(), DENIED);
	assert!(matches!(signals.last(), Some(Signal::Text(text)) if text.contains("bwrap")));
	assert!(!signals.iter().any(|signal| matches!(signal, Signal::Failure(..))));
}

#[test]
fn an_unsupported_model_is_refused_and_warning_items_are_not_failures() {
	assert_eq!(
		replay(&codex(), FAIL_MODEL),
		vec![
			Signal::Session("01a1fcd5-67bd-7892-85cb-88492108706b".into()),
			Signal::Failure(
				FailureKind::Declined,
				"The 'nonexistent-model-xyz' model is not supported when using Codex with a ChatGPT account.".into()
			)
		]
	);
}

#[test]
fn a_new_thread_after_a_resume_reports_a_session_the_runner_can_compare() {
	let signals = replay(&codex(), NEW_THREAD);
	let requested = "01a1fcd5-0000-7000-8000-000000000000";
	assert_ne!(signals[0], Signal::Session(requested.into()));
	assert!(matches!(&signals[0], Signal::Session(id) if id == "01a1fcd5-8699-7223-b665-00ac3e20ff3b"));
}

#[test]
fn a_stream_cut_short_has_no_answer_and_unknown_lines_yield_nothing() {
	let signals = replay(&codex(), KILLED);
	assert_eq!(signals.len(), 2);
	assert!(matches!(signals[0], Signal::Session(_)) && matches!(signals[1], Signal::Activity));
	for line in [
		"",
		"garbage",
		"[]",
		r#"{"type":"turn.completed"}"#,
		r#"{"type":"thread.started","thread_id":"x y"}"#,
	] {
		assert!(codex().read(line).is_empty(), "{line}");
	}
}

#[test]
fn an_exit_is_a_crash_unless_it_was_clean() {
	let exit = |code, tail| codex().exit(code, tail);
	assert_eq!(exit(Some(0), ""), None);
	let (kind, detail) = exit(
		Some(1),
		"Error: thread/resume: no rollout found for thread id x (code -32600)\n",
	)
	.unwrap();
	assert_eq!(kind, FailureKind::Crash);
	assert!(detail.contains("no rollout found"));
	assert_eq!(exit(None, "").map(|(kind, _)| kind), Some(FailureKind::Crash));
}

#[test]
fn a_status_the_message_names_decides_the_kind_and_an_unrecognised_failure_is_a_crash() {
	let kind_of = |message: &str| {
		let line = serde_json::json!({"type": "turn.failed", "error": {"message": message}}).to_string();
		match codex().read(&line).as_slice() {
			[Signal::Failure(kind, _)] => *kind,
			other => panic!("{other:?}"),
		}
	};
	assert_eq!(
		kind_of("unexpected status 401 Unauthorized: token expired"),
		FailureKind::SignIn
	);
	// The message a signed-out Codex 0.162.1 ends its turn with.
	assert_eq!(
		kind_of(
			"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses, cf-ray: 0, request id: req_0"
		),
		FailureKind::SignIn
	);
	assert_eq!(kind_of("unexpected status 403 Forbidden"), FailureKind::SignIn);
	assert_eq!(
		kind_of("unexpected status 429 Too Many Requests"),
		FailureKind::UsageLimit
	);
	assert_eq!(
		kind_of("unexpected status 503 Service Unavailable"),
		FailureKind::Outage
	);
	assert_eq!(kind_of("unexpected status: 429"), FailureKind::UsageLimit);
	assert_eq!(
		kind_of("You've reached your usage limit. Increase your limits to continue using codex."),
		FailureKind::UsageLimit
	);
	assert_eq!(kind_of("usage_limit_reached"), FailureKind::UsageLimit);
	assert_eq!(kind_of("your key sk-123 is wrong"), FailureKind::Crash);
	assert_eq!(kind_of("the status page is down"), FailureKind::Crash);
	// The status Codex reports leads, whatever the body says after it, and a
	// word before it that names no number is skipped.
	assert_eq!(
		kind_of("status page: upstream returned unexpected status 503 Service Unavailable"),
		FailureKind::Outage
	);
	assert_eq!(
		kind_of("unexpected status 401 Unauthorized: the body mentions status 503"),
		FailureKind::SignIn
	);
}
