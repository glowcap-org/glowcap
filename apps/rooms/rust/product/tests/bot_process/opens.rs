//! The direct-message opens a serving bot settles on its own timer: a
//! pending open is looked at again with no turn to prompt it until it
//! settles, and a note that cannot be read is left unsettled and counted while
//! the bot goes on serving.
use super::rig::{Rig, eventually};
use super::words;
use serde_json::json;

#[test]
fn a_pending_open_settles_without_a_turn_and_an_unreadable_note_is_left_unsettled() {
	let rig = Rig::new("bot-opens");
	// Notes are an earlier start's, so the bot has served before.
	assert!(rig.serve(json!({}), None).stop().success());
	let opens = rig.dir.join("opens");
	std::fs::create_dir_all(&opens).unwrap();
	let note = json!({
		"base": 3,
		"introduction": {"directory": "d", "peer": "ann", "registration": "r"},
		"conversation": "c",
		"turn": 9999,
	});
	std::fs::write(opens.join(format!("{:032x}.json", 1)), note.to_string()).unwrap();
	std::fs::write(opens.join(format!("{:032x}.json", 2)), "{").unwrap();
	std::fs::write(rig.rooms.join("open-answers"), "pending\npending\nopened\n").unwrap();
	let bot = rig.serve(json!({}), None);
	eventually("the pending open to settle", || {
		rig.log().contains(words::KEPT_ROUTE).then_some(())
	});
	let status = rig.status();
	assert_eq!(status["status"]["unsettled_opens"], 1, "{status}");
	let log = rig.log();
	assert_eq!(log.matches(words::STILL_SETTLING).count(), 1, "{log}");
	assert!(log.contains(words::COULD_NOT_BE_READ), "{log}");
	let left: Vec<_> = std::fs::read_dir(&opens)
		.unwrap()
		.map(|entry| entry.unwrap().file_name().into_string().unwrap())
		.collect();
	assert_eq!(left, [format!("{:032x}.json.unsettled", 2)]);
	assert!(bot.stop().success());
}

/// The agent's actions an earlier serve left, which the session lists as
/// keeping a place. A start removes every claim, and the list decides each
/// action alike, whether or not a claim named it: a pending one is asked
/// about again until the session keeps it, and an unknown one is given up.
/// When the session will not take its receipt back it is counted while the
/// session lists it, across a restart too.
#[test]
fn a_listed_action_is_settled_whether_or_not_it_was_claimed() {
	let rig = Rig::new("bot-actions");
	assert!(rig.serve(json!({}), None).stop().success());
	let held = rig.dir.join("turn-actions");
	std::fs::create_dir_all(&held).unwrap();
	let operation = |index: u32| format!("{index:032x}");
	for index in 1..=2 {
		let claim = json!({"turn": 9999, "what": {"say": {"to": "here"}}, "outcome": null}).to_string();
		std::fs::write(held.join(format!("{}.json", operation(index))), claim).unwrap();
	}
	let listed: String = (1..=3).map(|index| format!("{}\n", operation(index))).collect();
	std::fs::write(rig.rooms.join("held-actions"), listed).unwrap();
	std::fs::write(
		rig.rooms.join("action-answers"),
		"pending\nunknown\nkept\nkept\nunknown\n",
	)
	.unwrap();
	// The session refuses the receipt back at this start and the next.
	std::fs::write(rig.rooms.join("release-answers"), "refused\nrefused\n").unwrap();
	let bot = rig.serve(json!({}), None);
	let kept = |index: u32| {
		format!(
			"{} committed, and what it returned is kept",
			words::action(&operation(index))
		)
	};
	eventually("the pending action to be kept", || {
		rig.log().contains(&kept(1)).then_some(())
	});
	assert!(rig.log().contains(&kept(3)), "an action no claim named is kept too");
	assert_eq!(
		std::fs::read_dir(&held).unwrap().count(),
		0,
		"the start removed every claim"
	);
	let status = rig.status();
	assert_eq!(status["status"]["unsettled_actions"], 1, "{status}");
	assert!(bot.stop().success());
	let calls = std::fs::read_to_string(rig.rooms.join("calls.jsonl")).unwrap();
	assert_eq!(calls.matches("\"release-action\"").count(), 1, "{calls}");
	assert_eq!(
		std::fs::read_to_string(rig.rooms.join("held-actions")).unwrap(),
		format!("{}\n", operation(2))
	);
	let bot = rig.serve(json!({}), None);
	eventually("the restart to count the unsettled action", || {
		(rig.status()["status"]["unsettled_actions"] == 1).then_some(())
	});
	assert!(bot.stop().success());
}

/// A directory of opens the bot cannot write fails the look that settles a
/// note, and `status` reports it as the bot's own storage. The list of the
/// agent's actions still runs when a turn ends, and settles an action the
/// session lists.
#[test]
fn a_failing_look_at_the_opens_stops_no_action_list_and_status_reports_it() {
	use std::os::unix::fs::PermissionsExt;
	let rig = Rig::new("bot-opens-failing");
	// The note is an earlier start's, so the bot has served before.
	assert!(rig.serve(json!({}), None).stop().success());
	let opens = rig.dir.join("opens");
	std::fs::create_dir_all(&opens).unwrap();
	let note = json!({
		"base": 3,
		"introduction": {"directory": "d", "peer": "ann", "registration": "r"},
		"conversation": "c",
		"turn": 9999,
	});
	std::fs::write(opens.join(format!("{:032x}.json", 2)), note.to_string()).unwrap();
	std::fs::write(rig.rooms.join("open-answers"), "pending\n").unwrap();
	let bot = rig.serve(json!({}), None);
	eventually("the open to be looked at", || {
		rig.log().contains(words::STILL_SETTLING).then_some(())
	});
	let mode = |mode| std::fs::set_permissions(&opens, std::fs::Permissions::from_mode(mode)).unwrap();
	mode(0o500);
	// Each look finds the open settled and cannot remove its note.
	std::fs::write(rig.rooms.join("open-answers"), "opened\n".repeat(64)).unwrap();
	eventually("status to report the failed look", || {
		(rig.status()["status"]["last_error"]["during"] == "saving").then_some(())
	});
	let operation = format!("{:032x}", 1);
	std::fs::write(rig.rooms.join("held-actions"), format!("{operation}\n")).unwrap();
	std::fs::write(rig.rooms.join("action-answers"), "kept\n").unwrap();
	rig.direct(1, "c1", "please reply:hello there");
	rig.wait_for_replies(1);
	let kept = format!("{} committed, and what it returned is kept", words::action(&operation));
	eventually("the listed action to be kept", || {
		rig.log().contains(&kept).then_some(())
	});
	mode(0o700);
	assert!(bot.stop().success());
}

/// A list of the held receipts that fails leaves the actions it would name
/// holding places, so `status` reports it as a failure of sending until a
/// list answers, and the loop asks again on its backoff.
#[test]
fn a_failing_list_of_held_receipts_reaches_status_and_clears_when_a_list_answers() {
	let rig = Rig::new("bot-held-list-fails");
	assert!(rig.serve(json!({}), None).stop().success());
	std::fs::write(rig.rooms.join("held-answers"), "unreachable\n".repeat(3)).unwrap();
	let bot = rig.serve(json!({}), None);
	eventually("status to report the failed list", || {
		let problem = &rig.status()["status"]["last_error"];
		(problem["during"] == "sending"
			&& problem["message"]
				.as_str()
				.is_some_and(|text| text.contains("unreachable")))
		.then_some(())
	});
	eventually("status to clear once a list answers", || {
		rig.status()["status"]["last_error"].is_null().then_some(())
	});
	assert!(bot.stop().success());
}
