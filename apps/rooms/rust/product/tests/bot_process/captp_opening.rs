//! A delayed native reciprocal never blocks the bot's other conversations.
use super::captp::{World, action};
use super::captp_direct::turn;
use super::rig::eventually;
use super::session_rig::call;
use serde_json::json;

fn waiting(world: &World, text: &str) -> String {
	eventually("a durable, unstarted private turn", || {
		let saved: serde_json::Value =
			serde_json::from_slice(&std::fs::read(world.rig.dir.join("turns.json")).ok()?).ok()?;
		let row = saved["turns"].as_array()?.iter().find(|row| {
			let trigger = &row["asked"]["triggers"][0];
			trigger["text"] == text && trigger["opening_until"].is_number()
		})?;
		assert_eq!(row["spent"], 0);
		assert_eq!(row["progress"], "ready");
		Some(row["asked"]["conversation"].as_str()?.to_owned())
	})
}

fn hold(world: &mut World) -> std::path::PathBuf {
	let latch = world.fixture.peers[0].state.join("hold-route");
	std::fs::write(&latch, "").unwrap();
	world.restart_in_room("hold-reciprocal-route");
	latch
}

/// Holding a real first reciprocal capability stops only its private lane.
#[test]
fn a_pending_private_route_leaves_room_turns_free_and_recovers_after_restart() {
	let mut world = World::new("bot-pending-private-and-room");
	let latch = hold(&mut world);
	let serve = || {
		world
			.rig
			.serve_linked(&world.fixture.peers[0].link, json!({"conversation-limit":["1"]}))
	};
	let bot = serve();
	world.dm("reply:private after recovery");
	let conversation = waiting(&world, "reply:private after recovery");
	world.dm_again("reply:above the limit");
	eventually("the fixed notice to await its original return route", || {
		(world.rig.status()["availability"][&conversation]["notice"] == "pending").then_some(())
	});
	world.room("@bot-host reply:room while waiting");
	world.await_line("room", "room while waiting");
	assert!(
		!world
			.rig
			.log()
			.contains(&format!("{} {conversation}", super::words::TURN_STARTED))
	);
	let work = world.rig.dir.join("work");
	assert!(std::fs::read_dir(work).unwrap().flatten().all(|entry| {
		!std::fs::read_to_string(entry.path().join("prompt.txt"))
			.unwrap_or_default()
			.contains("private after recovery")
	}));
	assert_eq!(world.count("direct", "private after recovery"), 0);
	world.stopped(bot);
	std::fs::remove_file(latch).unwrap();
	let bot = serve();
	world.await_line("direct", "private after recovery");
	eventually("the private hourly refusal", || {
		(world.count_starting("direct", "I skipped your request because") == 1).then_some(())
	});
	assert_eq!(world.count("direct", "above the limit"), 0);
	world.stopped(bot);
	assert_eq!(world.count("direct", "private after recovery"), 1);
	world.finish();
}

/// A reciprocal callback already in flight cannot revive the closed inbox
/// or carry its old request into a later conversation with the same nickname.
#[test]
fn closing_a_pending_inbox_ends_its_unstarted_turn() {
	let mut world = World::new("bot-retire-pending-inbox");
	let latch = hold(&mut world);
	let bot = world.serve();
	world.dm("reply:old pending question");
	let original = waiting(&world, "reply:old pending question");
	assert_eq!(
		turn(&world, &[action("command", json!({}), &["closeDirect", &original])]),
		"exit=0"
	);
	eventually("the old opening to be refused", || {
		world
			.rig
			.log()
			.contains("original direct return route was unavailable")
			.then_some(())
	});
	std::fs::remove_file(latch).unwrap();
	call(
		&world.fixture.peers[0].state,
		"reply",
		json!({"dm":[super::captp::FRIEND],"text":["fresh contact"]}),
	);
	world.await_line("direct", "fresh contact");
	world.dm_again("reply:only the new conversation");
	world.await_line("direct", "only the new conversation");
	world.stopped(bot);
	assert_eq!(world.count("direct", "old pending question"), 0);
	world.finish();
}
