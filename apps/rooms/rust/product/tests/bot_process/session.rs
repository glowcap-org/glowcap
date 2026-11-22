//! A session that is unreachable, pauses or revokes the bot's access, or
//! reports events it lost or could not present.
use super::rig::{Rig, WAIT, eventually};
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
	assert!(WAIT.as_secs() <= 30);
	bot.terminate();
}

#[test]
fn paused_revoked_and_refused_access_show_in_status_and_the_bot_recovers() {
	let rig = Rig::new("bot-access");
	let bot = rig.serve(json!({}), None);
	for access in ["paused", "revoked", "refused"] {
		rig.events_fault(Some(access));
		eventually(&format!("status to show {access} access"), || {
			(status_field(&rig, "access") == access).then_some(())
		});
		assert_eq!(rig.status()["running"], true, "{access} access stopped the bot");
		rig.events_fault(None);
		eventually(&format!("access to reopen after {access}"), || {
			(status_field(&rig, "access") == "active").then_some(())
		});
	}
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
	rig.events_fault(Some("revoked"));
	eventually("the bot to find the access revoked again", || {
		(rig.refused_reads() >= 2).then_some(())
	});
	assert!(bot.stop().success(), "the bot exited with a failure");
	let log = rig.log();
	let named = log
		.lines()
		.filter(|line| line.contains("receiving:") && line.contains("injected revoked"))
		.count();
	assert_eq!(named, 1, "revoked access was logged {named} times: {log}");
}

#[test]
fn a_paused_send_waits_and_posts_the_same_line_once_access_resumes() {
	let rig = Rig::new("bot-paused-send");
	rig.send_faults(&["paused"]);
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "reply:after the pause");
	rig.wait_for_cursor(1);
	assert!(rig.log().contains("the stand-in injected paused"), "{}", rig.log());
	let sends = rig.operations("send");
	assert_eq!(sends.len(), 2);
	assert_eq!(sends[0], sends[1]);
	assert_eq!(status_field(&rig, "access"), "active");
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
}
