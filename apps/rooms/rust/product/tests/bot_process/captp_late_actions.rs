//! An agent's action whose verb died after it claimed its operation, and
//! whose request reached the session only after the serving loop had removed
//! the claim. The bot kill point `after-note` ends the verb at that step, and
//! the test then lands the request itself under the bot's own access and the
//! claimed operation, as a request held in flight would land. The session's
//! list of held receipts names it, so the serving loop keeps its line: while
//! serving once a turn ends, at the next start, and through the old access
//! before a replacement serves. No place stays held, and the line posts once.
//! A start also removes the claim of a turn a killed serve left open.
use super::captp::World;
use super::captp_direct::turn;
use super::rig::{Bot, eventually};
use super::session_rig::{attach, free_places, host, run_within};
use super::words;
use glowcap::PendingWork;
use rooms_application::content::session::custody::MAX_EFFECTS;
use rooms_services::session::attached::EffectStatus;
use serde_json::{Value, json};
use std::time::Duration;

const LATE: &str = "landed late";

fn say() -> Value {
	super::captp::action("say", json!({"text": [LATE]}), &[])
}

/// A turn that only reads, so its end lists the held receipts and its own
/// reply is the only line it posts.
fn read() -> Value {
	super::captp::action("workspace", json!({}), &[])
}

/// Serve on `link` with the verb armed to die after its claim, run a turn
/// that says [`LATE`], and answer the bot and the claimed operation once the
/// serving loop has removed the claim of the ended turn. The removal's log
/// line names the operation and proves the fault fired.
fn claimed_and_died(world: &World, link: &str) -> (Bot, String) {
	let bot = world.rig.serve_linked_at(link, json!({}), Some("after-note"));
	turn(world, &[say()]);
	let operation = eventually("the loop to remove the dead verb's claim", || {
		let log = world.rig.log();
		let line = log
			.lines()
			.find(|line| line.contains("was left by a turn whose agent stopped"))?;
		let operation = line.split("operation ").nth(1)?.split(' ').next()?;
		Some(operation.to_owned())
	});
	(bot, operation)
}

/// Land the request the dead verb would have sent: a `say` of [`LATE`] into
/// the room under `operation`, through the access `link` names.
async fn land(world: &World, link: &str, operation: &str) {
	let lander = host().await;
	let view = attach(&lander, link).await;
	let base = view.revision().await.unwrap();
	let room = world.fixture.room_id(0);
	let status = view.say_at(operation, base, &room, LATE).await.unwrap();
	assert_eq!(status, EffectStatus::Committed, "the late request did not land");
	drop(view);
	lander.close(PendingWork::Cancel).await.unwrap();
}

fn kept(world: &World, operation: &str) {
	let kept = format!("{} committed, and what it returned is kept", words::action(operation));
	eventually("the loop to keep the late request's line", || {
		world.rig.log().contains(&kept).then_some(())
	});
	world.await_line("room", LATE);
}

/// Stop the bot once its own reply lines are kept, so every place a probe
/// finds held is an action's.
fn stopped(world: &World, bot: Bot) {
	eventually("the lane to free", || {
		(world.rig.status()["status"]["sending"] == 0).then_some(())
	});
	world.stopped(bot);
}

async fn settled(world: &World, grants: &rooms_services::session::attached::Grants<rooms_platform::HostPlatform>) {
	assert_eq!(world.count("room", LATE), 1, "the late line posted once");
	let room = world.fixture.room_id(0);
	assert_eq!(
		free_places(grants, &room, "filler", Duration::ZERO).await,
		MAX_EFFECTS,
		"the late request's receipt still holds a place"
	);
}

/// While the bot serves, the next turn's end lists the held receipts, and the
/// loop keeps the late request's line.
#[test]
fn a_request_landing_after_its_dead_verb_is_kept_once_a_turn_ends() {
	let world = World::new("bot-late-serving");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let (bot, operation) = claimed_and_died(&world, &issued.link);
		land(&world, &issued.link, &operation).await;
		assert_eq!(turn(&world, &[read()]), "exit=0");
		kept(&world, &operation);
		let status = world.rig.status();
		assert_eq!(status["status"]["unsettled_actions"], 0, "{status}");
		stopped(&world, bot);
		settled(&world, &grants).await;
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A request that lands while the bot is stopped is listed at the next start,
/// which removed every claim, and kept.
#[test]
fn a_request_landing_after_its_dead_verb_is_kept_at_the_next_start() {
	let world = World::new("bot-late-restart");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let (bot, operation) = claimed_and_died(&world, &issued.link);
		stopped(&world, bot);
		land(&world, &issued.link, &operation).await;
		let bot = world.rig.serve_linked_at("", json!({}), None);
		kept(&world, &operation);
		stopped(&world, bot);
		settled(&world, &grants).await;
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A request the old access's verb left is listed by the old access before a
/// replacement serves, and kept, so nothing is left for `status` to count.
#[test]
fn a_request_landing_after_its_dead_verb_is_kept_by_the_old_access_before_a_replacement() {
	let world = World::new("bot-late-replaced");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, operation) = claimed_and_died(&world, &first.link);
		stopped(&world, bot);
		land(&world, &first.link, &operation).await;
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world.rig.serve_replacing(&second.link);
		kept(&world, &operation);
		let status = world.rig.status();
		assert_eq!(status["status"]["replaced_actions"], 0, "{status}");
		stopped(&world, bot);
		settled(&world, &grants).await;
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A first start finds a claim an earlier serve left in a bot directory whose
/// ledger is gone. The start marks it cut off and serves, so it never stops
/// the start, and the serving loop removes the claim of a turn that is not
/// running, so the session's list decides what it named.
#[test]
fn a_first_start_removes_a_claim_and_serves() {
	let world = World::new("bot-late-first");
	let held = world.rig.dir.join("turn-actions");
	std::fs::create_dir_all(&held).unwrap();
	let claim = json!({"turn": 9999, "what": {"say": {"to": "here"}}, "outcome": null}).to_string();
	std::fs::write(held.join(format!("{:032x}.json", 1)), claim).unwrap();
	let bot = world.serve_at(None);
	assert_eq!(turn(&world, &[read()]), "exit=0");
	eventually("the loop to remove the claim of a turn that is not running", || {
		(std::fs::read_dir(&held).unwrap().count() == 0).then_some(())
	});
	stopped(&world, bot);
	let log = world.rig.log();
	assert!(
		log.contains("was left by a turn whose agent stopped"),
		"the loop never met the claim: {log}"
	);
	world.finish();
}

/// A serve killed before its reply's send leaves the turn open in the
/// ledger, and beside it a claim of that turn's action, as a verb running
/// then leaves it. The harness and its verbs end with the serve, so the next
/// start marks the claim cut off and the serving loop never counts the open
/// turn as its owner. The session's list decides the request that landed
/// under the claimed operation, and the open turn sends its reply once.
#[test]
fn a_restart_removes_the_claim_of_a_turn_left_open_and_keeps_its_request() {
	let world = World::new("bot-late-open-turn");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let mut bot = world.rig.serve_linked_at(&issued.link, json!({}), Some("before-send"));
		world.dm("reply:left open");
		assert!(!bot.process.wait().success(), "the bot was not killed before its send");
		let ledger = world.rig.ledger();
		let open = ledger["turns"][0]["id"].clone();
		assert!(open.is_u64(), "no turn was left open: {ledger}");
		let held = world.rig.dir.join("turn-actions");
		std::fs::create_dir_all(&held).unwrap();
		let operation = format!("{:032x}", 0x1a7e);
		std::fs::write(
			held.join(format!("{operation}.json")),
			json!({"turn": open, "what": {"say": {"to": "here"}}, "outcome": null}).to_string(),
		)
		.unwrap();
		land(&world, &issued.link, &operation).await;
		let bot = world.rig.serve_linked_at("", json!({}), None);
		kept(&world, &operation);
		world.await_line("direct", "left open");
		stopped(&world, bot);
		// The claim is the turn's record or gone, and holds no place either way.
		for entry in std::fs::read_dir(&held).unwrap().flatten() {
			let claim: serde_json::Value = serde_json::from_slice(&std::fs::read(entry.path()).unwrap()).unwrap();
			assert!(
				!claim["outcome"].is_null() && claim["outcome"] != "cut",
				"a claim still holds a place: {claim}"
			);
		}
		assert_eq!(world.count("direct", "left open"), 1);
		settled(&world, &grants).await;
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
