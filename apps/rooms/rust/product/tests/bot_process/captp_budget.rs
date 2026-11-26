//! A verb runs on one budget (`act.rs`), and what it prints when the budget
//! ends is true of every phase. Each step's budget is armed as spent by a bot
//! fault, so no test waits on a clock: `spent-attach` ends it as the verb
//! dials, `spent-open` as a `--dm` open starts, `spent-call` as the call to
//! the session starts, and `spent-look` before the one look. The `actions`
//! verb lists what the turn did from the bot's own record, so it answers after
//! a verb the harness killed, and after one that ran out of budget.
use super::captp::{FRIEND, World, action};
use super::captp_direct::{output, replies, say, turn};
use super::rig::eventually;
use super::session_rig::run_within;
use glowcap::PendingWork;
use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};

fn actions() -> Value {
	action("actions", json!({}), &[])
}

/// A turn that sends `files.bin` once and then lists its actions, waits for
/// `seen` to exist, and lists them again. It answers the turn's working
/// directory once the agent runs, with the file placed and the agent released.
fn sending_then_listing_twice(world: &World) -> PathBuf {
	let send = action("send", json!({"text": ["budget files"], "file": ["files.bin"]}), &[]);
	let steps = json!([send, actions(), {"after": "seen"}, actions()]);
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
	std::fs::write(work.join("files.bin"), vec![7u8; 4096]).unwrap();
	std::fs::write(work.join("go"), "").unwrap();
	work
}

pub(super) fn printed(work: &std::path::Path, at: usize) -> Value {
	let path = work.join(format!("act-{at}.out"));
	eventually("the action's output", || path.exists().then_some(()));
	serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// A verb whose budget ended as it dialed sent nothing, and a turn's listing
/// holds no action for it.
#[test]
fn a_verb_that_ran_out_of_budget_dialing_sent_nothing() {
	let world = World::new("bot-budget-attach");
	let bot = world.serve_at(Some("spent-attach"));
	assert_eq!(turn(&world, &[say(FRIEND, "unsent")]), "exit=1");
	let failed = output(&world, 0);
	assert_eq!(failed["error"]["class"], "unreachable", "{failed}");
	assert!(
		failed["error"]["message"]
			.as_str()
			.unwrap()
			.contains("nothing was sent"),
		"{failed}"
	);
	assert_eq!(turn(&world, &[actions()]), "exit=0");
	assert_eq!(output(&world, 0)["actions"], json!([]));
	world.stopped(bot);
	assert_eq!(world.count("direct", "unsent"), 0);
	world.finish();
}

/// A `--dm` open whose budget ended is the open's failure, says no line was
/// requested when the budget ended before it wrote an open.
#[test]
fn a_direct_open_that_ran_out_of_budget_says_no_line_was_sent() {
	let world = World::new("bot-budget-open");
	let bot = world.serve_at(Some("spent-open"));
	assert_eq!(turn(&world, &[say(FRIEND, "unopened")]), "exit=1");
	let failed = output(&world, 0);
	assert_eq!(failed["error"]["opening"], true, "{failed}");
	assert_eq!(failed["error"]["class"], "unreachable", "{failed}");
	let message = failed["error"]["message"].as_str().unwrap();
	assert!(message.contains("nothing was sent"), "{message}");
	world.stopped(bot);
	assert_eq!(world.count("direct", "unopened"), 0);
	world.finish();
}

/// A `send` whose budget ended before the call is told no status, because
/// the session said none, with its files unfinished, and is listed as still
/// settling. The serving loop settles it while the turn runs: the session
/// never saw the send, so the bot can say only that it does not know, and the
/// listing then says unknown.
#[test]
fn a_send_cut_before_its_call_is_listed_settling_then_unknown() {
	let world = World::new("bot-budget-send");
	let bot = world.serve_at(Some("spent-call"));
	let work = sending_then_listing_twice(&world);
	let cut = printed(&work, 0);
	assert_eq!(
		(cut["status"].as_str(), cut["files"].as_str(), cut["settling"].as_str()),
		(None, Some("unfinished"), Some("bot")),
		"{cut}"
	);
	assert!(cut["reason"].as_str().unwrap().contains("may or may not"), "{cut}");
	let first = printed(&work, 1);
	let listed = &first["actions"][0];
	assert_eq!(
		(listed["verb"].as_str(), listed["files"].as_u64()),
		(Some("send"), Some(1))
	);
	assert!(
		matches!(listed["outcome"].as_str(), Some("settling" | "unknown")),
		"{listed}"
	);
	eventually("the loop to settle the cut send", || {
		world
			.rig
			.log()
			.contains("was cut off and the session no longer lists it")
			.then_some(())
	});
	std::fs::write(work.join("seen"), "").unwrap();
	let last = printed(&work, 3);
	let listed = &last["actions"][0];
	assert_eq!(listed["outcome"], "unknown", "{listed}");
	assert!(
		listed["says"]
			.as_str()
			.unwrap()
			.starts_with("it may or may not have posted"),
		"{listed}"
	);
	eventually("the turn's reply", || replies(&world).first().cloned());
	world.stopped(bot);
	assert_eq!(world.count("room", "budget files"), 0);
	world.finish();
}

/// A `send` the session committed but read as pending is handed to the
/// serving loop, which keeps its line while the turn runs, and the listing
/// shows what became of it.
#[test]
fn a_send_left_to_the_bot_is_listed_posted_once_the_loop_keeps_it() {
	let world = World::new("bot-budget-posted");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world
			.rig
			.serve_linked_at(&issued.link, json!({}), Some("view:post-unconfirmed"));
		let work = sending_then_listing_twice(&world);
		let left = printed(&work, 0);
		assert_eq!(
			(left["status"].as_str(), left["settling"].as_str()),
			(Some("pending"), Some("bot")),
			"{left}"
		);
		eventually("the loop to keep the line", || {
			world.rig.log().contains(super::words::ACTION_KEPT).then_some(())
		});
		std::fs::write(work.join("seen"), "").unwrap();
		let listed = printed(&work, 3)["actions"][0].clone();
		assert_eq!(listed["outcome"], "posted", "{listed}");
		assert!(listed["says"].as_str().unwrap().contains("posted"), "{listed}");
		eventually("the turn's reply", || replies(&world).first().cloned());
		world.await_line("room", "budget files");
		eventually("the lane to free", || {
			(world.rig.status()["status"]["sending"] == 0).then_some(())
		});
		world.stopped(bot);
		assert_eq!(world.count("room", "budget files"), 1);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A look the budget has no time for leaves the action to the bot: the verb
/// prints its call's own answer marked as the bot's to settle, and the claim
/// is handed over, not removed.
#[test]
fn a_look_that_ran_out_of_budget_leaves_the_action_to_the_bot() {
	let world = World::new("bot-budget-look");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world
			.rig
			.serve_linked_at(&issued.link, json!({}), Some("view:post-lost,spent-look"));
		assert_eq!(
			turn(
				&world,
				&[super::captp::action("say", json!({"text": ["lost look"]}), &[])]
			),
			"exit=1"
		);
		let left = output(&world, 0);
		assert_eq!(left["error"]["settling"], "bot", "{left}");
		assert_eq!(left["error"]["class"], "uncertain", "{left}");
		world.await_line("room", "lost look");
		eventually("the lane to free", || {
			(world.rig.status()["status"]["sending"] == 0).then_some(())
		});
		world.stopped(bot);
		assert_eq!(world.count("room", "lost look"), 1);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A verb the harness killed printed nothing, and the listing the agent runs
/// next shows its action as still settling, so the agent does not repeat it.
#[test]
fn a_killed_verb_is_listed_as_settling() {
	let world = World::new("bot-budget-killed");
	let bot = world.serve_at(Some("after-note"));
	assert_eq!(
		turn(
			&world,
			&[super::captp::action("say", json!({"text": ["killed"]}), &[]), actions()]
		),
		"exit=-1 exit=0"
	);
	let listed = output(&world, 1)["actions"][0].clone();
	assert_eq!(
		(listed["verb"].as_str(), listed["outcome"].as_str()),
		(Some("say"), Some("settling")),
		"{listed}"
	);
	assert!(
		listed["says"].as_str().unwrap().contains("Do not repeat it"),
		"{listed}"
	);
	world.stopped(bot);
	world.finish();
}
