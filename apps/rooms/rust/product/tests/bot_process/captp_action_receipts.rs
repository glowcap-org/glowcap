//! An agent's action whose receipt the real session still holds when the
//! verb returns. The bot serves on a collaborator access an operator issues.
//! The view fault `post-unconfirmed` makes a `say` that committed read as
//! pending, so the verb leaves it to the serving loop. The session fault
//! `expire-first-line-observation` pauses the first line's executor after the
//! session restarts, so the `say` reads unknown and the verb gives its receipt
//! back. Either way no receipt keeps a place, and a restart finds nothing.
//! The view fault `post-lost` loses a committed `say`'s answer, and the
//! verb's look reports it committed.
//! A pending action the old access could not settle before a new link
//! replaced it keeps its place, and `status` counts it. A replacement whose
//! old access cannot list its actions stores nothing, unless that access is
//! paused, and then `status` says it went unlisted once the new link is
//! stored.
use super::captp::{World, action, stored};
use super::captp_direct::{output, turn};
use super::captp_paused::paused;
use super::rig::{Bot, eventually};
use super::session_rig::{free_places, run_within};
use super::words;
use glowcap::PendingWork;
use rooms_application::content::session::custody::MAX_EFFECTS;
use serde_json::{Value, json};
use std::time::Duration;

/// The names in `turn-actions/` whose claims may still hold a place: those
/// with no outcome, or one the loop is still settling. A claim with an
/// outcome stays as the record of its turn, which a rerun of the turn is told.
fn notes(world: &World) -> Vec<String> {
	std::fs::read_dir(world.rig.dir.join("turn-actions")).map_or_else(
		|_| Vec::new(),
		|entries| {
			entries
				.map(|entry| entry.unwrap())
				.filter(|entry| {
					let claim: Value = serde_json::from_slice(&std::fs::read(entry.path()).unwrap()).unwrap();
					claim["outcome"].is_null() || claim["outcome"] == "cut"
				})
				.map(|entry| entry.file_name().into_string().unwrap())
				.collect()
		},
	)
}

/// Stop the bot once its own reply lines are kept, so every place a probe
/// finds held is an action's.
fn stopped(world: &World, bot: Bot) {
	eventually("the lane to free", || {
		(world.rig.status()["status"]["sending"] == 0).then_some(())
	});
	world.stopped(bot);
}

fn say(text: &str) -> Value {
	action("say", json!({"text": [text]}), &[])
}

/// Serve the stored link again and check that it finds no action unsettled
/// and no note. Status is read after two lists the restart ran, the first
/// finished and published before the second began.
fn restarted_clean(world: &World) {
	let bot = world.rig.serve_linked_at("", json!({}), None);
	super::captp_owners::listed_once_more(world, &format!("{:032x}", 0xc1ea1));
	super::captp_owners::listed_once_more(world, &format!("{:032x}", 0xc1ea2));
	let status = world.rig.status();
	assert_eq!(status["status"]["unsettled_actions"], 0, "{status}");
	assert_eq!(notes(world), Vec::<String>::new());
	stopped(world, bot);
}

/// Serve on `link` with a `say` of `text` that commits but reads as pending,
/// and the serving loop's look held at pending. Answers the running bot and
/// what the verb printed, which leaves the action to the serving loop.
fn pending_say(world: &World, link: &str, text: &str) -> (Bot, Value) {
	let bot = world
		.rig
		.serve_linked_at(link, json!({}), Some("view:post-unconfirmed,settle-pending@*"));
	assert_eq!(turn(world, &[say(text)]), "exit=0");
	let said = output(world, 0);
	assert_eq!(
		(said["status"].as_str(), said["settling"].as_str()),
		(Some("pending"), Some("bot")),
		"{said}"
	);
	(bot, said)
}

/// Eight `say`s the session committed and the verbs read as pending hold every
/// receipt place when the turn's agent stops. The turn's reply needs a ninth,
/// so it posts only because the serving loop settles the actions while the
/// reply is still going out, and the claims drain.
#[test]
fn a_turn_whose_actions_hold_every_place_still_posts_its_reply() {
	let world = World::new("bot-live-action-places");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world
			.rig
			.serve_linked_at(&issued.link, json!({}), Some("view:post-unconfirmed"));
		let says: Vec<Value> = (0..MAX_EFFECTS).map(|at| say(&format!("said {at}"))).collect();
		assert_eq!(turn(&world, &says), ["exit=0"; MAX_EFFECTS].join(" "));
		eventually("the claims to drain", || {
			let status = world.rig.status();
			(status["status"]["unsettled_actions"] == 0 && notes(&world).is_empty()).then_some(())
		});
		stopped(&world, bot);
		for at in 0..MAX_EFFECTS {
			assert_eq!(world.count("room", &format!("said {at}")), 1);
		}
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A pending `say` is left to the serving loop. The next start lists it, the
/// session reads the original request back, and the loop keeps the line, so
/// the receipt's place is free and the line posted once.
#[test]
fn a_pending_action_is_kept_by_the_serving_loop_after_a_restart() {
	let world = World::new("bot-live-action-pending");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &issued.link, "said late");
		let operation = said["operation"].as_str().unwrap().to_owned();
		stopped(&world, bot);

		let bot = world.rig.serve_linked_at("", json!({}), None);
		let kept = format!("{} committed, and what it returned is kept", words::action(&operation));
		eventually("the loop to keep the line", || {
			world.rig.log().contains(&kept).then_some(())
		});
		world.await_line("room", "said late");
		let status = world.rig.status();
		assert_eq!(status["status"]["unsettled_actions"], 0, "{status}");
		stopped(&world, bot);
		restarted_clean(&world);
		assert_eq!(world.count("room", "said late"), 1);
		let room = world.fixture.room_id(0);
		assert_eq!(free_places(&grants, &room, "filler", Duration::ZERO).await, MAX_EFFECTS);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A `say` whose executor the session pauses reads unknown. The verb gives
/// its receipt back and says so, records the outcome in its claim, and a restart finds nothing held.
#[test]
fn an_unknown_action_is_given_back_by_its_verb() {
	let mut world = World::new("bot-live-action-unknown");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, bot) = paused(&mut world, "expire-first-line-observation", None).await;
		assert_eq!(turn(&world, &[say("said unknown")]), "exit=0");
		let said = output(&world, 0);
		assert_eq!(said["status"], "unknown", "the fault never fired: {said}");
		assert_eq!(
			(said["receipt"].as_str(), said["outcome"].as_str()),
			(Some("released"), Some("unknown")),
			"{said}"
		);
		assert_eq!(notes(&world), Vec::<String>::new());
		let status = world.rig.status();
		assert_eq!(status["status"]["unsettled_actions"], 0, "{status}");
		stopped(&world, bot);
		restarted_clean(&world);
		let room = world.fixture.room_id(0);
		assert_eq!(free_places(&grants, &room, "filler", Duration::ZERO).await, MAX_EFFECTS);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A `say` that committed but whose answer was lost reads uncertain, and the
/// verb's one look finds it committed and keeps its line. The agent is told
/// it committed, not that it may still apply, and nothing is left to settle.
#[test]
fn an_uncertain_action_a_look_finds_committed_is_reported_committed() {
	let world = World::new("bot-live-action-lost");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world
			.rig
			.serve_linked_at(&issued.link, json!({}), Some("view:post-lost"));
		assert_eq!(turn(&world, &[say("said lost")]), "exit=0");
		let said = output(&world, 0);
		assert_eq!(said["looked"], true, "the fault never fired: {said}");
		assert_eq!(
			(said["ok"].as_bool(), said["status"].as_str(), said.get("settling")),
			(Some(true), Some("committed"), None),
			"{said}"
		);
		assert_eq!(notes(&world), Vec::<String>::new());
		world.await_line("room", "said lost");
		stopped(&world, bot);
		restarted_clean(&world);
		assert_eq!(world.count("room", "said lost"), 1);
		let room = world.fixture.room_id(0);
		assert_eq!(free_places(&grants, &room, "filler", Duration::ZERO).await, MAX_EFFECTS);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A `send` that committed but whose answer was lost is found committed by
/// the verb's look, which reports how its files stand as a `send` that printed
/// its own answer does, and the files arrive.
#[test]
fn a_send_a_look_finds_committed_reports_how_its_files_stand() {
	let world = World::new("bot-live-send-lost");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world
			.rig
			.serve_linked_at(&issued.link, json!({}), Some("view:post-lost"));
		// A turn that posts nothing makes the directory its agent works in.
		assert_eq!(turn(&world, &[action("workspace", json!({}), &[])]), "exit=0");
		let work = std::fs::read_dir(world.rig.dir.join("work"))
			.unwrap()
			.flatten()
			.map(|conversation| conversation.path())
			.find(|path| path.join("act-0.out").exists())
			.unwrap();
		std::fs::write(work.join("small.txt"), b"the files of a lost answer").unwrap();
		let args = action("send", json!({"text": ["sent lost"], "file": ["small.txt"]}), &[]);
		assert_eq!(turn(&world, &[args]), "exit=0");
		let sent = output(&world, 0);
		assert_eq!(sent["looked"], true, "the fault never fired: {sent}");
		assert_eq!(
			(sent["status"].as_str(), sent["files"].as_str(), sent.get("settling")),
			(Some("committed"), Some("complete"), None),
			"{sent}"
		);
		world.await_line("room", "sent lost");
		stopped(&world, bot);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// As above, but keeping what the look found committed fails and the session
/// is unreachable (view fault `post-lost-unkept`), which clears with time. The
/// agent is told the line committed, that nothing keeps it yet, and that the
/// bot holds its receipt, never the lost answer's failure.
#[test]
fn a_committed_action_a_look_cannot_keep_yet_is_reported_committed_and_held() {
	let world = World::new("bot-live-action-unkept");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world
			.rig
			.serve_linked_at(&issued.link, json!({}), Some("view:post-lost-unkept"));
		assert_eq!(turn(&world, &[say("said unkept")]), "exit=0");
		let said = output(&world, 0);
		assert_eq!(said["looked"], true, "the fault never fired: {said}");
		assert_eq!(
			(said["ok"].as_bool(), said["status"].as_str(), said["settling"].as_str()),
			(Some(true), Some("committed"), Some("bot")),
			"{said}"
		);
		assert_eq!(
			(said["kept"].as_bool(), said["receipt"].as_str()),
			(Some(false), Some("held")),
			"{said}"
		);
		// The claim stays while the bot holds the receipt, and the sweep keeps
		// the line and clears it.
		world.await_line("room", "said unkept");
		eventually("the sweep to keep the line", || notes(&world).is_empty().then_some(()));
		stopped(&world, bot);
		restarted_clean(&world);
		assert_eq!(world.count("room", "said unkept"), 1);
		let room = world.fixture.room_id(0);
		assert_eq!(free_places(&grants, &room, "filler", Duration::ZERO).await, MAX_EFFECTS);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A `send` whose answer was lost, whose look reads the files complete and
/// then cannot keep the line (view fault `post-lost-unkept`), is reported
/// committed with its files complete, never unknown, and the bot holds its
/// receipt.
#[test]
fn a_send_a_look_cannot_keep_yet_still_reports_how_its_files_stand() {
	let world = World::new("bot-live-send-unkept");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world
			.rig
			.serve_linked_at(&issued.link, json!({}), Some("view:post-lost-unkept"));
		assert_eq!(turn(&world, &[action("workspace", json!({}), &[])]), "exit=0");
		let work = std::fs::read_dir(world.rig.dir.join("work"))
			.unwrap()
			.flatten()
			.map(|conversation| conversation.path())
			.find(|path| path.join("act-0.out").exists())
			.unwrap();
		std::fs::write(work.join("small.txt"), b"the files of an unkept send").unwrap();
		let args = action("send", json!({"text": ["sent unkept"], "file": ["small.txt"]}), &[]);
		assert_eq!(turn(&world, &[args]), "exit=0");
		let sent = output(&world, 0);
		assert_eq!(sent["looked"], true, "the fault never fired: {sent}");
		assert_eq!(
			(
				sent["status"].as_str(),
				sent["files"].as_str(),
				sent["receipt"].as_str()
			),
			(Some("committed"), Some("complete"), Some("held")),
			"{sent}"
		);
		world.await_line("room", "sent unkept");
		stopped(&world, bot);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A pending `say` checked by a later turn's `command --operation --base`
/// only reads, because no claim of that turn names it, so its place stays held
/// until the serving loop keeps it at the next start.
#[test]
fn a_later_turns_look_at_an_action_only_reads_and_the_loop_keeps_it() {
	let world = World::new("bot-live-action-checked");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &issued.link, "said and checked");
		let room = world.fixture.room_id(0);
		let named = json!({"operation": [said["operation"]], "base": [said["base"].to_string()]});
		let look = action("command", named, &["say", room.as_str(), "said and checked"]);
		assert_eq!(turn(&world, &[look]), "exit=0");
		let checked = output(&world, 0);
		assert_eq!(checked["status"], "committed", "{checked}");
		assert_eq!(checked.get("settling"), None, "{checked}");
		let kept = format!(
			"{} committed, and what it returned is kept",
			words::action(said["operation"].as_str().unwrap())
		);
		assert!(!world.rig.log().contains(&kept), "the look kept the line");
		stopped(&world, bot);
		let bot = world.rig.serve_linked_at("", json!({}), None);
		eventually("the loop to keep the line", || {
			world.rig.log().contains(&kept).then_some(())
		});
		world.await_line("room", "said and checked");
		stopped(&world, bot);
		assert_eq!(world.count("room", "said and checked"), 1);
		assert_eq!(free_places(&grants, &room, "filler", Duration::ZERO).await, MAX_EFFECTS);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A pending `say` the first access sent, which its last list before a
/// second access serves cannot settle, is recorded in the ledger. `status`
/// counts it, across a restart too, and its receipt still holds one of the
/// session's places, which only the first access, or its revocation, gives
/// back.
#[test]
fn an_action_the_old_access_could_not_settle_is_counted_as_replaced_while_its_receipt_holds_a_place() {
	let world = World::new("bot-live-action-replaced");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &first.link, "said before the replacement");
		assert_eq!(said["status"], "pending", "{said}");
		stopped(&world, bot);
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_at(&second.link, "settle-pending@*");
		eventually("status to count the action as replaced", || {
			(world.rig.status()["status"]["replaced_actions"] == 1).then_some(())
		});
		let status = world.rig.status();
		assert_eq!(status["status"]["unsettled_actions"], 0, "{status}");
		eventually("the loop to record that it cannot say what the action did", || {
			notes(&world).is_empty().then_some(())
		});
		stopped(&world, bot);
		let bot = world.rig.serve_linked_at("", json!({}), None);
		eventually("the restart to count the action as replaced", || {
			(world.rig.status()["status"]["replaced_actions"] == 1).then_some(())
		});
		stopped(&world, bot);
		let room = world.fixture.room_id(0);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::ZERO).await,
			MAX_EFFECTS - 1,
			"the replaced action's receipt holds no place"
		);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// The old access's list is the only record of its agent's actions, so it is
/// part of the replacement. The fault `held-list` makes that list fail as an
/// unreachable session does: the replacement exits with the list's failure
/// and the old link stays stored. Running the same replacement again lists
/// the pending action and records it.
#[test]
fn a_replacement_whose_old_access_cannot_list_its_actions_stores_nothing_and_the_repeat_records_them() {
	let world = World::new("bot-live-action-unlisted");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &first.link, "said before a refused replacement");
		assert_eq!(said["status"], "pending", "{said}");
		stopped(&world, bot);
		let before = stored(&world);
		let second = grants.issue("the second", &terms).await.unwrap();
		let mut refused = world.rig.serve_replacing_ended_at(&second.link, "held-list@1");
		assert!(!refused.wait().success(), "the replacement went on without the list");
		assert!(stored(&world) == before, "the refused replacement stored its link");
		let output = world.rig.output();
		assert!(output.contains(words::OLD_UNLISTED), "{output}");
		let bot = world.rig.serve_replacing_at(&second.link, "settle-pending@*");
		eventually("status to count the action as replaced", || {
			(world.rig.status()["status"]["replaced_actions"] == 1).then_some(())
		});
		assert!(
			stored(&world) == format!("{}\n", second.link),
			"the repeated replacement did not store its link"
		);
		stopped(&world, bot);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A paused first access cannot list the pending `say` it holds, and the bot
/// leaves a pause to its operator, so the replacement goes on. `status` says
/// the old access went unlisted, across a restart too, while the receipt
/// still holds one of the session's places.
#[test]
fn a_replacement_of_a_paused_access_goes_on_and_status_says_its_actions_went_unlisted() {
	let world = World::new("bot-live-action-paused");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &first.link, "said before a pause");
		assert_eq!(said["status"], "pending", "{said}");
		stopped(&world, bot);
		grants.pause(&first.name).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_at(&second.link, "settle-pending@*");
		let status = world.rig.status();
		assert_eq!(status["status"]["replaced_unlisted"], "paused", "{status}");
		assert_eq!(status["status"]["replaced_actions"], 0, "{status}");
		assert!(
			stored(&world) == format!("{}\n", second.link),
			"the replacement did not store its link"
		);
		stopped(&world, bot);
		let bot = world.rig.serve_linked_at("", json!({}), None);
		let status = world.rig.status();
		assert_eq!(status["status"]["replaced_unlisted"], "paused", "{status}");
		stopped(&world, bot);
		let room = world.fixture.room_id(0);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::ZERO).await,
			MAX_EFFECTS - 1,
			"the unlisted action's receipt holds no place"
		);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A replacement of a paused access whose new link the session refuses
/// stores neither the link nor why the old access went unlisted, so once the
/// operator resumes that access it serves with no such record.
#[test]
fn a_refused_replacement_of_a_paused_access_leaves_no_unlisted_record() {
	let world = World::new("bot-live-action-paused-refused");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &first.link, "said before a pause");
		assert_eq!(said["status"], "pending", "{said}");
		stopped(&world, bot);
		grants.pause(&first.name).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		grants.revoke(&second.name).await.unwrap();
		let before = stored(&world);
		let mut refused = world.rig.serve_refused(&second.link, true);
		assert!(!refused.wait().success(), "the session served a revoked link");
		assert!(stored(&world) == before, "the refused replacement stored its link");
		let log = world.rig.log();
		assert!(log.contains("the old access is paused"), "{log}");
		grants.resume(&first.name).await.unwrap();
		let bot = world.rig.serve_linked_at("", json!({}), None);
		let status = world.rig.status();
		assert_eq!(status["status"]["replaced_unlisted"], Value::Null, "{status}");
		stopped(&world, bot);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
