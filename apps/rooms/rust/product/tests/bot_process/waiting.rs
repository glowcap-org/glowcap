//! A reply waits for the access to be active instead of sending into a state
//! of it: one send discovers the state, and none follow until reads succeed.
use super::rig::{Rig, eventually, gone};
use serde_json::json;

/// Wait until the session has refused two more reads. Its waits double from one
/// second, so that spans at least one of the bot's access polls, and a
/// delivery that did not wait would have sent again by then.
fn hold_while_reads_are_refused(rig: &Rig) {
	let at = rig.failed_reads();
	eventually("two more failed reads", || (rig.failed_reads() >= at + 2).then_some(()));
}

/// A send answered as a state of the access is not a verdict on the line. The
/// session sees that one send and no other while the access is not active,
/// and once it is, the reply posts once under the same operation.
fn held_while_the_access_is_not_active(label: &str, fault: &str, access: &str) {
	let rig = Rig::new(label);
	rig.send_faults(&[fault]);
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "reply:held then posted");
	eventually("status to show the access", || {
		(rig.status()["status"]["access"] == access).then_some(())
	});
	hold_while_reads_are_refused(&rig);
	assert_eq!(rig.operations("send").len(), 1, "{}", rig.log());
	assert!(rig.sent().is_empty(), "a line posted while the access was {access}");
	rig.events_fault(None);
	rig.wait_for_cursor(1);
	eventually("status to show the access active", || {
		(rig.status()["status"]["access"] == "active").then_some(())
	});
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["held then posted"], "{}", rig.log());
	let sends = rig.operations("send");
	assert_eq!(sends.len(), 2, "{sends:?}");
	assert_eq!(sends[0], sends[1], "the line was sent under a new operation");
	assert!(
		rig.log().contains(&format!("the stand-in injected {fault}")),
		"{}",
		rig.log()
	);
}

#[test]
fn a_send_answered_as_a_paused_access_waits_for_it_and_the_reply_posts_once() {
	held_while_the_access_is_not_active("bot-paused-send", "paused", "paused");
}

/// A send answered as a denied access ends serving as a revoked one does: the
/// session no longer holds the access, so no later answer changes it. The
/// reply stays pending and posts once under the next link's serve.
#[test]
fn a_send_answered_as_a_denied_access_ends_serving_and_the_reply_posts_once_after_a_restart() {
	let rig = Rig::new("bot-denied-send");
	rig.send_faults(&["denied"]);
	let mut bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "reply:ended then posted");
	assert!(!bot.process.wait().success(), "a denied send left the bot serving");
	let said = rig.output();
	assert!(said.contains("--replace-link"), "{said}");
	assert_eq!(rig.status()["status"]["access"], "revoked");
	assert!(rig.sent().is_empty(), "a line posted under a denied access");
	// The stand-in holds the denial until the access is issued again.
	rig.events_fault(None);
	let bot = rig.serve(json!({}), None);
	rig.wait_for_replies(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["ended then posted"], "{}", rig.log());
}

/// A reply resumed at startup waits for a read that finds the access active,
/// so the session sees no send while reads fail as paused.
#[test]
fn a_reply_resumed_while_the_access_is_paused_is_not_sent_until_it_resumes() {
	let rig = Rig::new("bot-resumed-paused");
	let mut bot = rig.serve(json!({}), Some("before-send"));
	rig.direct(1, "c1", "reply:resumed once");
	assert!(!bot.process.wait().success(), "the bot was not killed before its send");
	rig.events_fault(Some("paused"));
	let mut bot = rig.serve_unreached();
	hold_while_reads_are_refused(&rig);
	assert!(rig.operations("send").is_empty(), "{:?}", rig.operations("send"));
	rig.events_fault(None);
	rig.wait_for_cursor(1);
	bot.signal("-TERM");
	assert!(bot.wait().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["resumed once"], "{}", rig.log());
}

/// A pause the first send finds while the ledger is full and the queue holds
/// as many lines as the bot reads ahead is seen again once the access resumes:
/// the read that stopped for the full queue keeps probing while the access is
/// not active.
#[test]
fn a_pause_found_with_a_full_queue_ends_when_the_access_resumes() {
	let rig = Rig::new("bot-full-queue-pause");
	let bot = rig.serve(json!({"conversation-limit": ["1000"]}), None);
	for at in 1..=16_u64 {
		rig.direct(at, &format!("busy-{at}"), "wait-file:answered late");
	}
	for at in 17..=400_u64 {
		rig.direct(at, "queued", "reply:queued");
	}
	eventually("the ledger to be full and the queue past the read-ahead bound", || {
		let status = rig.status();
		(status["status"]["open_turns"] == 16 && status["status"]["queued"].as_u64() > Some(256)).then_some(())
	});
	let first = rig.workdir("busy-1").join("harness.pid");
	eventually("a turn to be running", || first.exists().then_some(()));
	rig.send_faults(&["paused"]);
	std::fs::write(rig.workdir("busy-1").join("release"), "").unwrap();
	eventually("status to show the pause", || {
		(rig.status()["status"]["access"] == "paused").then_some(())
	});
	rig.events_fault(None);
	eventually("status to show the access active again", || {
		(rig.status()["status"]["access"] == "active").then_some(())
	});
	// Every harness that recorded its pid is running, parked on its release file.
	let running: Vec<i32> = (1..=16_u64)
		.filter_map(|at| {
			let pid = rig.workdir(&format!("busy-{at}")).join("harness.pid");
			std::fs::read_to_string(pid).ok()?.trim().parse().ok()
		})
		.collect();
	assert!(!running.is_empty(), "no harness was running");
	bot.terminate();
	// A stop ends every harness the bot started, so none waits out its own
	// deadline in a deleted directory.
	for pid in running {
		assert!(gone(pid), "harness {pid} outlived the bot's stop");
	}
}
