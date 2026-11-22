use super::*;
use crate::bot::harness::lines::{replay, words};
use std::path::Path;

const FIRST: &str = include_str!("../../../../../tests/bot_harness/pi/first.jsonl");
const RESUME: &str = include_str!("../../../../../tests/bot_harness/pi/resume.jsonl");
const DENIED: &str = include_str!("../../../../../tests/bot_harness/pi/denied.jsonl");
const FAIL_OAUTH: &str = include_str!("../../../../../tests/bot_harness/pi/fail-oauth.jsonl");
const FAIL_ENDPOINT: &str = include_str!("../../../../../tests/bot_harness/pi/fail-endpoint.jsonl");
const FAIL_CREDENTIAL: &str = include_str!("../../../../../tests/bot_harness/pi/fail-credential.jsonl");

const SESSION: &str = "01a1fcd4-8519-7681-b1e9-f3bdca4296f6";

fn turn(session: Option<&'static str>, model: Option<&'static str>) -> Invocation {
	Pi.invocation(&Turn {
		prompt: "hello",
		system: "be brief",
		session,
		workdir: Path::new("/w/bot/work/c1"),
		home: Path::new("/w/bot/home"),
		state: Path::new("/w/bot/harness/pi/c1"),
		model,
		permission: Permission::Full,
	})
}

fn strings(words: &[&str]) -> Vec<String> {
	words.iter().map(ToString::to_string).collect()
}

const ISOLATION: [&str; 5] = [
	"--no-extensions",
	"--no-skills",
	"--no-prompt-templates",
	"--no-context-files",
	"--no-mcp",
];

#[test]
fn a_first_turn_lets_pi_choose_the_session() {
	let mut expected = strings(&[
		"--mode",
		"json",
		"-p",
		"--session-dir",
		"/w/bot/harness/pi/c1",
		"--append-system-prompt",
		"be brief",
	]);
	expected.extend(strings(&ISOLATION));
	let invocation = turn(None, None);
	assert_eq!(words(&invocation), expected);
	assert_eq!(invocation.stdin.as_deref(), Some("hello"));
	assert_eq!(invocation.prepare, vec![Prepare::Dir("/w/bot/harness/pi/c1".into())]);
	assert!(invocation.env.is_empty());
}

#[test]
fn a_resumed_turn_names_the_session_and_the_model() {
	let invocation = turn(Some(SESSION), Some("example/example-model"));
	let mut expected = strings(&[
		"--mode",
		"json",
		"-p",
		"--session-dir",
		"/w/bot/harness/pi/c1",
		"--session",
		SESSION,
		"--model",
		"example/example-model",
		"--append-system-prompt",
		"be brief",
	]);
	expected.extend(strings(&ISOLATION));
	assert_eq!(words(&invocation), expected);
	assert_eq!(invocation.resume.as_deref(), Some(SESSION));
}

#[test]
fn a_session_that_is_not_a_uuid_never_reaches_the_command_line() {
	let invocation = turn(Some("--tools=bash"), None);
	assert!(!words(&invocation).contains(&"--session".to_owned()));
	assert_eq!(invocation.resume, None);
}

#[test]
fn a_safe_run_is_refused_by_name_and_a_full_run_is_allowed() {
	assert!(Pi.supports(Permission::Full, Path::new("/w/bot/home")).is_ok());
	let reason = Pi.supports(Permission::Safe, Path::new("/w/bot/home")).unwrap_err();
	assert!(reason.contains("Pi") && reason.contains("--permission full"));
}

#[test]
fn text_deltas_stream_and_the_stopped_message_is_the_answer() {
	assert!(Pi.text_is_delta());
	assert_eq!(
		replay(&Pi, FIRST),
		vec![
			Signal::Session(SESSION.into()),
			Signal::Text("\n\npong".into()),
			Signal::Final("pong".into())
		]
	);
	let resumed = replay(&Pi, RESUME);
	assert_eq!(resumed[0], Signal::Session(SESSION.into()));
	assert!(matches!(resumed.last(), Some(Signal::Final(text)) if !text.is_empty() && text == text.trim()));
}

#[test]
fn a_blocked_tool_is_activity_and_the_run_still_answers() {
	let signals = replay(&Pi, DENIED);
	assert!(signals.contains(&Signal::Activity));
	assert!(matches!(signals.last(), Some(Signal::Final(text)) if text.ends_with("Done.")));
	assert!(!signals.iter().any(|signal| matches!(signal, Signal::Failure(..))));
}

#[test]
fn an_expired_sign_in_in_a_clean_exit_stream_is_an_auth_failure() {
	let signals = replay(&Pi, FAIL_OAUTH);
	assert_eq!(signals.len(), 2);
	assert!(matches!(&signals[1], Signal::Failure(FailureKind::Auth, text) if text.contains("Invalid refresh token")));
}

#[test]
fn retries_are_not_failures_until_the_last_one_gives_up() {
	let signals = replay(&Pi, FAIL_ENDPOINT);
	let failures: Vec<_> = signals
		.iter()
		.filter(|signal| matches!(signal, Signal::Failure(..)))
		.collect();
	// The final agent_end and the retry that gave up each report it once.
	assert_eq!(failures.len(), 2);
	assert!(
		failures
			.iter()
			.all(|signal| matches!(signal, Signal::Failure(FailureKind::Crash, text) if text.starts_with("500:")))
	);
	let retrying = r#"{"type":"agent_end","messages":[{"role":"assistant","stopReason":"error","errorMessage":"500: x"}],"willRetry":true}"#;
	assert!(Pi.read(retrying).is_empty());
}

#[test]
fn provider_statuses_pick_the_failure_kind() {
	assert_eq!(kind("429: slow down"), FailureKind::RateLimit);
	assert_eq!(kind("401: no"), FailureKind::Auth);
	assert_eq!(kind("403: no"), FailureKind::Auth);
	assert_eq!(kind("500: down"), FailureKind::Crash);
	assert_eq!(kind("something else"), FailureKind::Crash);
}

#[test]
fn an_aborted_run_and_noise_lines() {
	assert!(matches!(
		Pi.read(r#"{"type":"agent_settled","aborted":true}"#)[..],
		[Signal::Failure(FailureKind::Crash, _)]
	));
	for line in [
		"",
		"nope",
		"[]",
		r#"{"type":"agent_settled","aborted":false}"#,
		r#"{"type":"message_start","message":{"role":"system"}}"#,
		r#"{"type":"session","id":"my-bot-turn-1"}"#,
	] {
		assert!(Pi.read(line).is_empty(), "{line}");
	}
}

#[test]
fn the_header_alone_is_all_a_missing_credential_streams() {
	assert_eq!(
		replay(&Pi, FAIL_CREDENTIAL),
		vec![Signal::Session("01a1fcd7-c74f-7392-9365-d189702aa9e3".into())]
	);
}

#[test]
fn an_exit_is_classified_from_its_status_and_stderr() {
	let exit = |code, tail| Pi.exit(code, tail).map(|(kind, _)| kind);
	assert_eq!(exit(Some(0), ""), None);
	assert_eq!(
		exit(Some(1), "No API key found for openai.\n\nUse /login"),
		Some(FailureKind::Auth)
	);
	assert_eq!(
		exit(
			Some(1),
			"Error: Model \"nope-model\" not found. Use --list-models to see available models."
		),
		Some(FailureKind::Refused)
	);
	assert_eq!(
		exit(Some(1), "Error: Unknown provider \"x\"."),
		Some(FailureKind::Refused)
	);
	assert_eq!(
		exit(Some(1), "No session found matching '00000000-dead-beef'"),
		Some(FailureKind::Refused)
	);
	assert_eq!(exit(Some(143), ""), Some(FailureKind::Crash));
	assert_eq!(exit(None, ""), Some(FailureKind::Crash));
}
