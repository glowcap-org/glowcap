//! The direct-message opens a serving bot settles on its own timer: a
//! pending open is looked at again with no turn to prompt it until it
//! settles, and a note that cannot be read is set aside and counted while
//! the bot goes on serving.
use super::rig::{Rig, eventually};
use serde_json::json;

#[test]
fn a_pending_open_settles_without_a_turn_and_an_unreadable_note_is_set_aside() {
	let rig = Rig::new("bot-opens");
	let opens = rig.dir.join("opens");
	std::fs::create_dir_all(&opens).unwrap();
	let note = json!({
		"base": 3,
		"introduction": {"directory": "d", "peer": "ann", "registration": "r"},
		"conversation": "c",
	});
	std::fs::write(opens.join(format!("{:032x}.json", 1)), note.to_string()).unwrap();
	std::fs::write(opens.join(format!("{:032x}.json", 2)), "{").unwrap();
	std::fs::write(rig.rooms.join("open-answers"), "pending\npending\nopened\n").unwrap();
	let bot = rig.serve(json!({}), None);
	eventually("the pending open to settle", || {
		rig.log().contains("kept its route").then_some(())
	});
	let status = rig.status();
	assert_eq!(status["status"]["unsettled_opens"], 1, "{status}");
	let log = rig.log();
	assert_eq!(log.matches("has not settled").count(), 1, "{log}");
	assert!(log.contains("could not be read"), "{log}");
	let left: Vec<_> = std::fs::read_dir(&opens)
		.unwrap()
		.map(|entry| entry.unwrap().file_name().into_string().unwrap())
		.collect();
	assert_eq!(left, [format!("{:032x}.json.unsettled", 2)]);
	assert!(bot.stop().success());
}
