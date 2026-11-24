//! A session that is unreachable, pauses, refuses or revokes the bot's
//! access, or reports events it lost or could not present.
use super::rig::{Rig, eventually, gone, recorded_pid};
use super::words;
use serde_json::{Value, json};

fn status_field(rig: &Rig, field: &str) -> Value {
	rig.status()["status"][field].clone()
}

#[test]
fn a_session_that_cannot_be_read_is_waited_out_and_gaps_are_counted() {
	let rig = Rig::new("bot-lost");
	let bot = rig.serve(json!({}), None);
	let inbox = rig.rooms.join("inbox.jsonl");
	std::fs::write(&inbox, "not an event\n").unwrap();
	eventually("the bot to report the unreadable session", || {
		rig.log().contains("receiving:").then_some(())
	});
	assert_eq!(rig.status()["running"], true, "the bot gave up on a lost session");
	assert_eq!(status_field(&rig, "last_error")["during"], "receiving");

	std::fs::write(&inbox, "").unwrap();
	rig.push(json!({"at": 4, "gap": true}));
	rig.push(json!({"at": 5, "unavailable": true}));
	rig.direct(6, "c1", "reply:back again");
	let sent = rig.wait_for_replies(1);
	assert_eq!(sent[0]["text"], "back again");
	rig.wait_for_cursor(6);
	assert_eq!(status_field(&rig, "gaps"), 1);
	assert_eq!(status_field(&rig, "unavailable"), 1);
	assert!(
		status_field(&rig, "last_error").is_null(),
		"a good read left the error standing"
	);
	bot.terminate();
}

#[test]
fn paused_access_shows_in_status_and_the_bot_recovers() {
	let rig = Rig::new("bot-access");
	let bot = rig.serve(json!({}), None);
	rig.events_fault(Some("paused"));
	eventually("status to show paused access", || {
		(status_field(&rig, "access") == "paused").then_some(())
	});
	assert_eq!(rig.status()["running"], true, "paused access stopped the bot");
	rig.events_fault(None);
	eventually("access to reopen after the pause", || {
		(status_field(&rig, "access") == "active").then_some(())
	});
	rig.direct(1, "c1", "reply:still here");
	assert_eq!(rig.wait_for_replies(1)[0]["text"], "still here");
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
}

/// A state that holds is named in the log once, however many reads find it.
#[test]
fn an_access_state_that_holds_is_logged_once() {
	let rig = Rig::new("bot-access-once");
	let bot = rig.serve(json!({}), None);
	rig.events_fault(Some("paused"));
	eventually("the bot to find the access paused again", || {
		(rig.failed_reads() >= 2).then_some(())
	});
	assert!(bot.stop().success(), "the bot exited with a failure");
	let log = rig.log();
	let named = log
		.lines()
		.filter(|line| line.contains("receiving:") && line.contains("injected paused"))
		.count();
	assert_eq!(named, 1, "a paused access was logged {named} times: {log}");
}

/// A revoked access ends the bot with a failure that names the next step, and
/// the status it leaves says why.
#[test]
fn a_revoked_access_ends_the_bot_naming_the_new_link_to_give_it() {
	let rig = Rig::new("bot-revoked");
	let mut bot = rig.serve(json!({}), None);
	rig.events_fault(Some("revoked"));
	assert!(!bot.process.wait().success(), "a revoked access left the bot serving");
	let log = rig.log();
	assert!(log.contains("receiving:") && log.contains("injected revoked"), "{log}");
	assert_eq!(status_field(&rig, "access"), "revoked");
	let said = eventually("the failure line", || {
		Some(rig.output()).filter(|said| said.contains("--replace-link"))
	});
	assert!(
		said.contains("session access issue"),
		"no command to issue an access: {said}"
	);
	let (_, ok) = rig.run("ready", json!({}));
	assert!(!ok);
}

/// A denied access, which the session no longer holds and never will, ends a
/// serving bot as a revoked one does, with the command that replaces its link.
#[test]
fn a_denied_access_ends_the_bot_naming_the_replace_link_command() {
	let rig = Rig::new("bot-denied");
	let mut bot = rig.serve(json!({}), None);
	rig.events_fault(Some("denied"));
	assert!(!bot.process.wait().success(), "a denied access left the bot serving");
	assert_eq!(status_field(&rig, "access"), "revoked");
	let said = rig.output();
	assert!(
		said.contains("--replace-link") && !said.contains(words::LINK_NOT_ACCEPTED),
		"{said}"
	);
}

/// A revoked access ends the harness a turn is running, and the turn runs
/// again once the bot is served with an access that works.
#[test]
fn a_revoked_access_ends_a_running_harness_and_the_turn_reruns_after_a_restart() {
	let rig = Rig::new("bot-revoked-running");
	let mut bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "slow-once:done after the revoke");
	let workdir = rig.workdir("c1");
	eventually("the harness to start its slow turn", || {
		workdir.join("slow.marker").exists().then_some(())
	});
	let harness = recorded_pid(&workdir, "harness.pid");
	rig.events_fault(Some("revoked"));
	assert!(!bot.process.wait().success(), "a revoked access left the bot serving");
	assert!(gone(harness), "the harness outlived the revoked access");
	assert!(rig.sent().is_empty());
	rig.events_fault(None);
	let bot = rig.serve(json!({}), None);
	assert_eq!(rig.wait_for_replies(1)[0]["text"], "done after the revoke");
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
}

/// A ledger that holds a reply still to send is never started over, even when
/// the settings beside it are gone.
#[test]
fn a_missing_config_never_discards_a_ledger_with_a_reply_still_to_send() {
	let rig = Rig::new("bot-config-gone");
	let mut bot = rig.serve(json!({}), Some("before-send"));
	rig.direct(1, "c1", "reply:still owed");
	assert!(!bot.process.wait().success(), "the bot was not killed before its send");
	std::fs::remove_file(rig.dir.join("config.json")).unwrap();
	let ledger = std::fs::read(rig.dir.join("turns.json")).unwrap();
	let named = json!({"rooms-dir": [rig.rooms], "harness": ["fake"], "glowcap": [rig.glowcap()]});
	let (said, ok) = rig.run("serve", named);
	assert!(!ok, "a bot with no settings and a reply owed started over");
	assert!(said.to_string().contains("config.json"), "{said}");
	assert_eq!(std::fs::read(rig.dir.join("turns.json")).unwrap(), ledger);
}

/// While a first start is still trying to reach the session, `status` says a
/// serve runs and nothing is configured.
#[test]
fn a_first_start_that_has_not_reached_its_session_shows_as_running() {
	let rig = Rig::new("bot-first-start");
	rig.events_fault(Some("unreachable"));
	let mut waiting = rig.serve_unreached();
	eventually("status to show a serve that has not reached its session", || {
		let (status, ok) = rig.run("status", json!({}));
		(ok && status["running"] == true && status["configured"] == false).then_some(())
	});
	waiting.signal("-TERM");
	assert!(waiting.wait().success(), "a stopped first start exited with a failure");
	assert!(
		!rig.dir.join("config.json").exists(),
		"an unreached first start stored its settings"
	);
}

/// A first start whose first read is denied stores nothing and says the link
/// was not accepted, with the command to start again. The real session only
/// answers this for a revoked access, so the stand-in is the proof that a
/// denied answer, like a revoked one, ends a first start.
#[test]
fn a_first_start_the_session_refuses_names_the_link_and_stores_nothing() {
	let rig = Rig::new("bot-first-refused");
	rig.events_fault(Some("denied"));
	let mut first = rig.serve_unreached();
	assert!(!first.wait().success(), "a refused first start exited cleanly");
	let said = rig.output();
	assert!(said.contains(words::LINK_NOT_ACCEPTED), "{said}");
	assert!(said.contains("--harness"), "no command to start again: {said}");
	assert!(
		!rig.dir.join("config.json").exists(),
		"a refused first start stored its settings"
	);
}
