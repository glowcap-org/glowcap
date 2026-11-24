//! `send` opens only regular files beneath the turn's working directory,
//! reached without following a link.
use super::*;
use rooms_testing::scratch::Scratch;

#[test]
fn send_opens_only_regular_files_beneath_the_work_directories_without_links() {
	let scratch = Scratch::create("bot-send-confined");
	let work = scratch.join("work");
	std::fs::create_dir_all(work.join("one/inbox")).unwrap();
	std::fs::write(work.join("one/inbox/kept.txt"), "kept").unwrap();
	std::fs::write(scratch.join("session.link"), "secret").unwrap();
	std::os::unix::fs::symlink(scratch.join("session.link"), work.join("one/link.txt")).unwrap();
	std::os::unix::fs::symlink(&*scratch, work.join("one/up")).unwrap();
	assert!(confined(&work, &work.join("one/inbox/kept.txt")).is_ok());
	assert!(confined(&work, &work.join("one/./inbox/kept.txt")).is_ok());
	for refused in [
		scratch.join("session.link"),
		work.join("one/link.txt"),
		work.join("one/up/session.link"),
		work.join("one/../../session.link"),
		work.join("one/inbox"),
		work.clone(),
	] {
		assert!(confined(&work, &refused).is_err(), "{}", refused.display());
	}
}

/// A turn with no more time than the send reserve and the settle tail leaves
/// a verb no room for its first step, so the verb refuses before it takes a
/// place or sends anything, and a turn with room for a step does not.
#[test]
fn a_verb_with_no_room_for_a_step_before_its_tail_refuses_at_the_start() {
	use super::super::{Budget, SEND_RESERVE_MS, SETTLE_TAIL_MS, Turn};
	use std::time::{Duration, SystemTime};
	let turn_ending = |left_ms: u64| Turn {
		bot: "unused".into(),
		conversation: "c".into(),
		id: crate::bot::ledger::TurnId(1),
		budget: Budget::starting(Some(SystemTime::now() + Duration::from_millis(left_ms))),
	};
	for left_ms in [
		0,
		SEND_RESERVE_MS / 2,
		SEND_RESERVE_MS,
		SEND_RESERVE_MS + SETTLE_TAIL_MS - 1_000,
	] {
		let refused = turn_ending(left_ms)
			.begin()
			.expect_err("no room for a step before the tail");
		let text = refused.to_string();
		assert!(
			text.contains("nothing was sent and no place was taken"),
			"{left_ms}: {text}"
		);
	}
	assert!(turn_ending(SEND_RESERVE_MS + SETTLE_TAIL_MS + 5_000).begin().is_ok());
	assert!(
		Turn {
			budget: Budget::starting(None),
			..turn_ending(0)
		}
		.begin()
		.is_ok()
	);
}
