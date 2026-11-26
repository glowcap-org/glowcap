//! An agent's verb that claimed its operation and then stopped running while
//! its turn still runs. The harness's own tool timeout ends such a verb, and
//! a crash does the same: nobody writes its outcome. The claim names the
//! verb's process, so the serving loop reads the claim as cut once that
//! process is gone and settles the action from the session's list. A verb
//! that still runs keeps its claim. The bot fault `hold-note` holds a verb
//! after its claim until `note-go` exists, so the test acts on the verb while
//! the claim stands, and nothing here waits on a clock.
use super::captp::{World, action};
use super::captp_budget::printed;
use super::rig::eventually;
use serde_json::{Value, json};
use std::{path::PathBuf, process::Command};

fn say() -> Value {
	action("say", json!({"text": ["held after its claim"]}), &[])
}

/// Run a turn that says [`say`], waits for `seen`, and lists its actions. It
/// answers the turn's working directory and the one claim once the verb
/// holds, and releases the agent.
fn held_after_claim(world: &World) -> (PathBuf, PathBuf) {
	let steps = json!([say(), {"after": "seen"}, action("actions", json!({}), &[])]);
	world.room(&format!("@bot-host act-once:{steps}"));
	let work = eventually("the agent to start", || {
		std::fs::read_dir(world.rig.dir.join("work"))
			.ok()?
			.flatten()
			.map(|conversation| conversation.path())
			.find(|path| {
				std::fs::read_to_string(path.join("prompt.txt")).is_ok_and(|prompt| prompt.contains("act-once:"))
			})
	});
	std::fs::write(work.join("go"), "").unwrap();
	eventually("the verb to hold its claim", || {
		world.rig.dir.join("note-held").exists().then_some(())
	});
	let claim = eventually("the verb's claim", || {
		std::fs::read_dir(world.rig.dir.join("turn-actions"))
			.ok()?
			.flatten()
			.map(|entry| entry.path())
			.find(|path| path.extension().is_some_and(|extension| extension == "json"))
	});
	(work, claim)
}

fn read(claim: &std::path::Path) -> Value {
	serde_json::from_slice(&std::fs::read(claim).unwrap()).unwrap()
}

/// The verb the harness's tool timeout kills, between its claim and its send,
/// while the turn runs. The loop settles the claim: the session never saw the
/// request, so the bot can say only that it does not know, and the agent's
/// own `actions` says so, not that the action is still settling.
#[test]
fn a_verb_the_harness_killed_at_its_tool_timeout_is_settled_unknown_while_its_turn_runs() {
	let world = World::new("bot-dead-verb");
	let bot = world.serve_at(Some("hold-note"));
	let (work, claim) = held_after_claim(&world);
	let pid = read(&claim)["verb"]["pid"].as_u64().expect("the claim names its verb");
	assert!(read(&claim)["outcome"].is_null());
	let killed = Command::new("kill").args(["-9", &pid.to_string()]).status().unwrap();
	assert!(killed.success());
	eventually("the loop to settle the dead verb's claim", || {
		(read(&claim)["outcome"] == "unknown").then_some(())
	});
	std::fs::write(work.join("seen"), "").unwrap();
	let listed = printed(&work, 2);
	let first = &listed["actions"][0];
	assert_eq!(first["outcome"], "unknown", "{listed}");
	assert_eq!(first.get("settling"), None, "{listed}");
	world.stopped(bot);
	assert_eq!(
		world.count("room", "held after its claim"),
		0,
		"the killed verb never sent"
	);
	world.finish();
}

/// A verb held alive between its claim and its send keeps its claim: the loop
/// passes over it, and the line posts once when the verb goes on.
#[test]
fn a_verb_that_still_runs_keeps_its_claim() {
	let world = World::new("bot-live-verb");
	let bot = world.serve_at(Some("hold-note"));
	let (work, claim) = held_after_claim(&world);
	assert!(read(&claim)["outcome"].is_null(), "a running verb's claim is its own");
	std::fs::write(world.rig.dir.join("note-go"), "").unwrap();
	world.await_line("room", "held after its claim");
	std::fs::write(work.join("seen"), "").unwrap();
	let listed = printed(&work, 2);
	assert_eq!(listed["actions"][0]["outcome"], "posted", "{listed}");
	world.stopped(bot);
	assert_eq!(world.count("room", "held after its claim"), 1);
	world.finish();
}
