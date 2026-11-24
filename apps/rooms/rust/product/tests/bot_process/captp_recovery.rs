//! Sends the bot recovers after the session moved on without it: other
//! commands in between, many crashed sends in a row, and a session restart.
use super::captp::{DWELL, ROOM, World};
use super::captp_crashes::{answered, killed_at, once_and_still_open, still_open};
use super::session_rig::call_when_paced;
use super::words;
use rooms_application::content::session::custody::MAX_EFFECTS;
use serde_json::json;

/// One round more than the session holds receipts for.
const ROUNDS: usize = MAX_EFFECTS + 1;

#[test]
fn many_sends_recovered_from_a_crash_never_bring_the_session_to_refuse() {
	let world = World::new("bot-live-crash-loop");
	for round in 0..ROUNDS {
		let text = format!("round {round}");
		killed_at(&world, "after-send", &text);
		let bot = world.serve();
		answered(&world, &text);
		assert!(bot.stop().success(), "round {round}: the bot exited with a failure");
	}
	std::thread::sleep(DWELL);
	let texts: Vec<String> = (0..ROUNDS).map(|round| format!("round {round}")).collect();
	once_and_still_open(&world, &texts.iter().map(String::as_str).collect::<Vec<_>>());
	assert!(
		!world
			.rig
			.log()
			.contains(rooms_application::failure::FailureCode::ReceiptsFull.wire()),
		"{}",
		world.rig.log()
	);
	world.finish();
}

#[test]
fn a_send_that_never_left_is_reissued_once_after_other_commands_move_the_workspace() {
	let world = World::new("bot-live-fenced");
	killed_at(&world, "before-send", "fenced out");
	for n in 0..3 {
		let sent = call_when_paced(
			&world.fixture.peers[0].state,
			"reply",
			json!({"room": [ROOM], "text": [format!("moving the workspace {n}")]}),
		);
		assert_eq!(sent["status"], "committed", "{sent}");
	}
	let bot = world.serve();
	answered(&world, "fenced out");
	world.stopped(bot);
	once_and_still_open(&world, &["fenced out"]);
	let log = world.rig.log();
	assert!(log.contains(words::NO_RECEIPT), "{log}");
	assert!(
		log.contains(words::SENDING_UNDER_NEW),
		"the fence never refused the resend: {log}"
	);
	world.finish();
}

#[test]
fn a_session_restarted_under_a_sent_line_settles_it_from_the_durable_receipt() {
	let mut world = World::new("bot-live-session-restart");
	killed_at(&world, "after-send", "across the restart");
	world.fixture.peers[0].restart();
	let bot = world.serve();
	answered(&world, "across the restart");
	world.dm_again("reply:after the session restarted");
	answered(&world, "after the session restarted");
	world.stopped(bot);
	still_open(&world);
	assert_eq!(world.count("direct", "after the session restarted"), 1);
	// The receipt outlived the restart and settled the send. The line's
	// authority did not, so the receipt is released instead of kept.
	assert_eq!(world.count("direct", "across the restart"), 1, "{:?}", world.seen());
	let log = world.rig.log();
	assert!(
		!log.contains(words::NO_RECEIPT),
		"the restarted session lost a committed receipt: {log}"
	);
	assert!(log.contains(words::NOT_KEPT), "{log}");
	assert!(
		!log.contains(words::RECEIPT_LEFT),
		"the receipt was not released: {log}"
	);
	world.finish();
}
