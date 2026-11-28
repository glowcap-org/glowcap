use super::*;
use crate::bot::harness::lines::{replay, words};

const FIRST: &str = include_str!("../../../../../tests/bot_harness/claude/first.jsonl");
const RESUME: &str = include_str!("../../../../../tests/bot_harness/claude/resume.jsonl");
const DENIED: &str = include_str!("../../../../../tests/bot_harness/claude/denied.jsonl");
const FAIL_AUTH: &str = include_str!("../../../../../tests/bot_harness/claude/fail-auth.jsonl");
const FAIL_MODEL: &str = include_str!("../../../../../tests/bot_harness/claude/fail-model.jsonl");
const FAIL_RESUME: &str = include_str!("../../../../../tests/bot_harness/claude/fail-resume.jsonl");
const DENIED_SETTINGS: &str = include_str!("../../../../../tests/bot_harness/claude/denied-settings.jsonl");
const HOME: &str = include_str!("../../../../../tests/bot_harness/claude/home.jsonl");
const HOME_DOTDOT: &str = include_str!("../../../../../tests/bot_harness/claude/home-dotdot.jsonl");

const SESSION: &str = "d5acc2aa-8342-47d9-877a-0b647149bcd4";

fn claude() -> Claude {
	Claude::new(Path::new("/opt/glowcap/bin/glowcap"))
}

fn turn(session: Option<&'static str>, model: Option<&'static str>, permission: Permission) -> Invocation {
	claude().invocation(&Turn {
		prompt: "hello",
		system: "be brief",
		session,
		workdir: Path::new("/w/bot/work/c1"),
		home: Path::new("/w/bot/home"),
		state: Path::new("/w/bot/harness/claude/c1"),
		model,
		permission,
	})
}

const BASE: [&str; 11] = [
	"-p",
	"--output-format",
	"stream-json",
	"--verbose",
	"--safe-mode",
	"--setting-sources",
	"user",
	"--system-prompt-snapshot",
	"off",
	"--append-system-prompt-file",
	"/w/bot/harness/claude/c1/system.md",
];

fn expected(extra: &[&str]) -> Vec<String> {
	BASE.iter().chain(extra).map(ToString::to_string).collect()
}

#[test]
fn a_first_safe_turn_scopes_every_tool_to_the_working_directory() {
	let invocation = turn(None, None, Permission::Safe);
	assert_eq!(
		words(&invocation),
		expected(&[
			"--permission-mode",
			"dontAsk",
			"--tools",
			"Read,Write,Edit,Bash",
			"--disallowedTools",
			"Write(./.claude/**)",
			"Edit(./.claude/**)",
			"--allowedTools",
			"Read(./**)",
			"Write(./**)",
			"Edit(./**)",
			"Read(//w/bot/home/**)",
			"Write(//w/bot/home/**)",
			"Edit(//w/bot/home/**)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot say)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot say *)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot send)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot send *)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot workspace)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot workspace *)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot command)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot command *)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot actions)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot actions *)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot join)",
			"Bash(/opt/glowcap/bin/glowcap apps rooms bot join *)",
		])
	);
	assert_eq!(invocation.stdin.as_deref(), Some("hello"));
	assert_eq!(invocation.resume, None);
	assert_eq!(
		invocation.env,
		vec![(
			"BASH_DEFAULT_TIMEOUT_MS".into(),
			crate::bot::act::CLAUDE_BASH_DEFAULT_MS.to_string().into()
		)]
	);
	// The instructions travel in a file beside the conversation's state,
	// outside the working directory, and never on the command line.
	assert_eq!(
		invocation.prepare,
		vec![
			Prepare::Dir("/w/bot/harness/claude/c1".into()),
			Prepare::File {
				at: "/w/bot/harness/claude/c1/system.md".into(),
				contents: "be brief".into()
			}
		]
	);
	assert!(!words(&invocation).iter().any(|word| word.contains("be brief")));
}

#[test]
fn a_full_turn_skips_permission_checks() {
	assert_eq!(
		words(&turn(None, None, Permission::Full)),
		expected(&["--dangerously-skip-permissions"])
	);
}

#[test]
fn a_resumed_turn_repeats_the_isolation_and_permission_flags() {
	let invocation = turn(Some(SESSION), Some("sonnet"), Permission::Full);
	assert_eq!(
		words(&invocation),
		expected(&[
			"--model",
			"sonnet",
			"--resume",
			SESSION,
			"--dangerously-skip-permissions"
		])
	);
	assert_eq!(invocation.resume.as_deref(), Some(SESSION));
}

#[test]
fn a_stored_session_that_is_not_a_uuid_never_reaches_the_command_line() {
	let invocation = turn(Some("--dangerously-skip-permissions"), None, Permission::Safe);
	assert!(!words(&invocation).contains(&"--resume".to_owned()));
	assert_eq!(invocation.resume, None);
}

#[test]
fn safe_refuses_a_glowcap_path_or_home_a_rule_cannot_hold() {
	let home = Path::new("/w/bot/home");
	assert!(claude().supports(Permission::Safe, home).is_ok());
	assert!(claude().supports(Permission::Full, home).is_ok());
	let odd = Claude::new(Path::new("/opt/(x)/glowcap"));
	assert!(odd.supports(Permission::Safe, home).is_err());
	assert!(odd.supports(Permission::Full, home).is_ok());
	let reason = claude().supports(Permission::Safe, Path::new("/w/*/home")).unwrap_err();
	assert!(reason.contains("bot directory"), "{reason}");
	assert!(claude().supports(Permission::Full, Path::new("/w/*/home")).is_ok());
	for widening in [
		"/w/b?t/home",
		"/w/[ab]/home",
		"/w/{a,b}/home",
		"/w/a\\b/home",
		"/w/!b/home",
		"/w/#b/home",
	] {
		let path = Path::new(widening);
		assert!(claude().supports(Permission::Safe, path).is_err(), "{widening}");
		assert!(claude().supports(Permission::Full, path).is_ok(), "{widening}");
	}
}

/// The home rules of a safe run, which both recordings below were made under.
/// A change to them makes a recording stale, so it is recorded again.
fn assert_recorded_rules() {
	let words = words(&turn(None, None, Permission::Safe));
	for rule in [
		"Read(//w/bot/home/**)",
		"Write(//w/bot/home/**)",
		"Edit(//w/bot/home/**)",
	] {
		assert!(words.iter().any(|word| word == rule), "{rule}");
	}
}

/// Recorded with the safe flags this adapter writes, asking the agent to
/// read `<HOME>/../session.link`, the bot's access link one step out of the
/// home, and then `<HOME>/memory/../note.md`, a file in the home reached the
/// same way. Claude Code resolves `..` before it matches a rule, so the
/// first read was denied under its resolved path and the second ran.
#[test]
fn a_safe_run_resolves_a_dotted_path_before_its_home_rule_matches() {
	assert_recorded_rules();
	let lines: Vec<serde_json::Value> = HOME_DOTDOT
		.lines()
		.map(|line| serde_json::from_str(line).unwrap())
		.collect();
	let results: Vec<_> = lines
		.iter()
		.filter_map(|line| line.pointer("/message/content")?.as_array())
		.flatten()
		.filter(|block| block["type"] == "tool_result")
		.map(|block| block["content"].as_str().unwrap())
		.collect();
	assert!(
		results[0].starts_with("Permission to use Read has been denied"),
		"{results:?}"
	);
	assert!(results[1].contains("note inside home"), "{results:?}");
	let denials = &lines.last().unwrap()["permission_denials"];
	assert_eq!(denials.as_array().map(Vec::len), Some(1), "{denials}");
	assert_eq!(denials[0]["tool_input"]["file_path"], "<BOT>/session.link");
	assert!(!HOME_DOTDOT.contains("SECRET-LINK-LINE"), "the link's line was read");
}

/// Recorded with the safe flags this adapter writes for a home outside the
/// working directory, asking the agent to write a memory in the home, then a
/// file in a third directory, then to read the memory back. The first write
/// and the read ran, and the second write was the run's only denial.
#[test]
fn a_safe_run_writes_its_home_and_nothing_outside_it_or_its_working_directory() {
	assert_recorded_rules();
	let lines: Vec<serde_json::Value> = HOME.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
	let blocks = |kind: &'static str| {
		lines
			.iter()
			.filter_map(|line| line.pointer("/message/content")?.as_array())
			.flatten()
			.filter(move |block| block["type"] == kind)
	};
	let result = |path: &str| {
		let id = blocks("tool_use")
			.find(|block| block["input"]["file_path"] == path)
			.map(|block| block["id"].clone())
			.unwrap();
		let result = blocks("tool_result").find(|block| block["tool_use_id"] == id).unwrap();
		result["content"].as_str().unwrap().to_owned()
	};
	assert!(result("<HOME>/memory/probe.md").starts_with("File created successfully"));
	assert!(result("<OUTSIDE>/x.txt").starts_with("Permission to use Write has been denied"));
	let denials = &lines.last().unwrap()["permission_denials"];
	assert_eq!(denials.as_array().map(Vec::len), Some(1), "{denials}");
	assert_eq!(denials[0]["tool_input"]["file_path"], "<OUTSIDE>/x.txt");
	let signals = replay(&claude(), HOME);
	assert!(signals.contains(&Signal::Activity), "{signals:?}");
	assert!(matches!(signals.last(), Some(Signal::Final(_))));
}

#[test]
fn a_turn_names_its_session_then_its_text_then_the_answer() {
	let said = "pong. I'll remember the word: heliotrope.".to_owned();
	assert_eq!(
		replay(&claude(), FIRST),
		vec![
			Signal::Session(SESSION.into()),
			Signal::Text(said.clone()),
			Signal::Final(said)
		]
	);
	assert_eq!(
		replay(&claude(), RESUME),
		vec![
			Signal::Session(SESSION.into()),
			Signal::Text("heliotrope".into()),
			Signal::Final("heliotrope".into())
		]
	);
}

#[test]
fn a_denied_tool_is_activity_and_the_turn_still_answers() {
	let signals = replay(&claude(), DENIED);
	assert_eq!(signals[1], Signal::Activity);
	assert!(matches!(signals.last(), Some(Signal::Final(text)) if text.starts_with("I couldn't run")));
	assert!(!signals.iter().any(|signal| matches!(signal, Signal::Failure(..))));
}

/// Recorded with the safe flags this adapter writes, in a fresh directory,
/// asking the agent to write `.claude/settings.json`. Claude refused the write
/// and the directory held no `.claude` afterwards.
#[test]
fn a_safe_run_cannot_write_the_project_settings_a_later_run_would_read() {
	let args = turn(None, None, Permission::Safe).args;
	let denied = args.iter().position(|arg| arg == "--disallowedTools").unwrap();
	assert_eq!(args[denied + 1..denied + 3], SAFE_DENIED.map(std::ffi::OsString::from));
	let at = |flag: &str| args.iter().position(|arg| arg == flag).unwrap();
	assert_eq!(args[at("--setting-sources") + 1], "user");
	let signals = replay(&claude(), DENIED_SETTINGS);
	assert!(signals.contains(&Signal::Activity), "{signals:?}");
	assert!(matches!(signals.last(), Some(Signal::Final(text)) if text.starts_with("It didn't work")));
}

#[test]
fn a_success_subtype_with_is_error_is_a_failure() {
	let kinds = |fixture| {
		replay(&claude(), fixture)
			.into_iter()
			.filter_map(|signal| match signal {
				Signal::Failure(kind, _) => Some(kind),
				Signal::Final(_) => panic!("a failed run produced an answer"),
				_ => None,
			})
			.collect::<Vec<_>>()
	};
	assert_eq!(kinds(FAIL_AUTH), vec![FailureKind::SignIn, FailureKind::SignIn]);
	assert_eq!(kinds(FAIL_MODEL), vec![FailureKind::Declined, FailureKind::Declined]);
}

#[test]
fn a_resume_of_an_unknown_session_is_a_crash_with_the_reason() {
	assert_eq!(
		replay(&claude(), FAIL_RESUME),
		vec![Signal::Failure(
			FailureKind::Crash,
			"No conversation found with session ID: 11111111-2222-4333-8444-555555555555".into()
		)]
	);
}

#[test]
fn a_result_alone_decides_when_the_error_line_is_missing() {
	let line = r#"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"limit"}"#;
	assert_eq!(
		claude().read(line),
		vec![Signal::Failure(FailureKind::UsageLimit, "limit".into())]
	);
	let line = r#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#;
	assert!(matches!(
		claude().read(line)[..],
		[Signal::Failure(FailureKind::SignIn, _)]
	));
}

#[test]
fn unknown_and_malformed_lines_yield_nothing() {
	for line in [
		"",
		"not json",
		"[]",
		r#"{"type":"stream_event"}"#,
		r#"{"type":"assistant"}"#,
		r#"{"type":"result"}"#,
		r#"{"type":"system","subtype":"init","session_id":"; rm -rf"}"#,
		r#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}"#,
	] {
		assert!(claude().read(line).is_empty(), "{line}");
	}
}

#[test]
fn an_exit_is_classified_from_its_status_and_stderr() {
	let exit = |code, tail| claude().exit(code, tail).map(|(kind, _)| kind);
	assert_eq!(exit(Some(0), ""), None);
	assert_eq!(
		exit(Some(1), r#"[claude-code:unrecognized_model] {"model":"x"}"#),
		Some(FailureKind::Declined)
	);
	assert_eq!(
		exit(Some(1), "Error: Session ID x is already in use."),
		Some(FailureKind::Crash)
	);
	assert_eq!(exit(None, ""), Some(FailureKind::Crash));
}

#[test]
fn a_failure_with_no_recorded_shape_is_a_crash() {
	assert_eq!(kind(Some("some_new_error"), None), FailureKind::Crash);
	assert_eq!(kind(None, None), FailureKind::Crash);
	assert_eq!(kind(None, Some(401)), FailureKind::SignIn);
}
