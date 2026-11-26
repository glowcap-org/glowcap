//! A `--dm` open the session still holds a receipt for, against a real
//! session, when the stored link is replaced. The session names the access
//! that sent each open, so a link to the same access, or back to it after
//! another, keeps the note, and another access's note is marked `.replaced`
//! and never looked at. The fault `open-unconfirmed` makes a committed open
//! read as pending, so its receipt is held and its note is kept.
use super::captp::{DWELL, FRIEND, World, another_form};
use super::captp_direct::{output, say, turn};
use super::rig::eventually;
use super::session_rig::{call, free_places, run_within};
use super::words;
use rooms_application::content::session::custody::MAX_EFFECTS;
use serde_json::json;
use std::time::Duration;

/// The names in `opens/`, sorted, with the zeros of the operation trimmed.
fn notes(world: &World) -> Vec<String> {
	let mut names: Vec<String> = std::fs::read_dir(world.rig.dir.join("opens"))
		.map(|entries| {
			entries
				.map(|entry| entry.unwrap().file_name().into_string().unwrap())
				.collect()
		})
		.unwrap_or_default();
	names.sort();
	names
}

/// The first link's bot sends an open the session commits and the bot is told
/// is pending, so its note is kept and the session holds its receipt. Returns
/// the note's file name.
pub(super) fn kept_note(world: &World, link: &str) -> String {
	let bot = world
		.rig
		.serve_linked_at(link, json!({}), Some("view:open-unconfirmed,settle-pending@*"));
	assert_eq!(turn(world, &[say(FRIEND, "kept")]), "exit=1");
	world.stopped(bot);
	let names = notes(world);
	assert_eq!(names.len(), 1, "{names:?}");
	assert!(names[0].ends_with(".json"), "{names:?}");
	names[0].clone()
}

/// The fault the replacement starts with: none. A proof that these tests fail
/// when the session's answer is wrong arms `holder-another@*` here.
const FAULT: Option<&str> = None;

/// A replacement link to the same access, in another form, keeps the note
/// under its own name, so the serving loop looks at it, the session answers
/// from the open's first receipt, and the note goes.
#[test]
fn a_replacement_link_to_the_same_access_keeps_its_note_and_settles_it() {
	let world = World::new("bot-live-notes-same");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		kept_note(&world, &first.link);
		let again = another_form(&first.link);
		let bot = world.rig.serve_replacing_unreported(&again, FAULT);
		eventually("the access's own note to settle and go", || {
			notes(&world).is_empty().then_some(())
		});
		let status = world.rig.status();
		assert_eq!(
			(
				&status["status"]["unsettled_opens"],
				&status["status"]["replaced_opens"]
			),
			(&json!(0), &json!(0)),
			"{status}"
		);
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// Another access's note is marked `.replaced` under the second link and is
/// never looked at or released, and the first link serving again gets it back
/// under its own name and settles it.
#[test]
fn a_note_another_access_sent_is_marked_replaced_never_released_and_returns_to_the_first_link() {
	let world = World::new("bot-live-notes-back");
	run_within(Duration::from_secs(180), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let note = kept_note(&world, &first.link);
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_at(&second.link, "settle-pending@*");
		eventually("the first access's note to be marked replaced", || {
			(notes(&world) == [format!("{note}.replaced")]).then_some(())
		});
		eventually("status to count the note as replaced", || {
			(world.rig.status()["status"]["replaced_opens"] == 1).then_some(())
		});
		assert_eq!(world.rig.status()["status"]["unsettled_opens"], 0);
		// Every look answers pending and logs that once for the open it looks
		// at, so a look at this note would show in the log. No event says a look
		// is not coming, so the dwell is the evidence of an absence.
		std::thread::sleep(DWELL);
		assert_eq!(
			notes(&world),
			[format!("{note}.replaced")],
			"a replaced note was touched"
		);
		let operation = note.trim_end_matches(".json");
		let log = world.rig.log();
		assert!(
			!log.contains(&words::looked(operation, FRIEND)),
			"a replaced note was looked at: {log}"
		);
		world.stopped(bot);
		let bot = world.rig.serve_replacing_unreported(&first.link, FAULT);
		eventually("the first access to take its note back and settle it", || {
			notes(&world).is_empty().then_some(())
		});
		assert!(
			world.rig.log().contains(&words::looked(operation, FRIEND)),
			"a look at the note it settles is not visible in the log"
		);
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A plain `--dm` to a peer a live note names is refused, with nothing sent,
/// until the serving bot settles that open.
#[test]
fn a_plain_dm_to_a_peer_a_live_note_names_is_refused_and_opens_nothing() {
	let world = World::new("bot-live-notes-refuse");
	let bot = world.serve_at(Some("view:open-unconfirmed,settle-pending@*"));
	assert_eq!(turn(&world, &[say(FRIEND, "kept")]), "exit=1");
	let note = notes(&world);
	assert_eq!(note.len(), 1, "{note:?}");
	assert_ne!(turn(&world, &[say(FRIEND, "again")]), "exit=0");
	let refused = output(&world, 0);
	let message = refused["error"]["message"].as_str().unwrap();
	assert!(message.starts_with(&words::settling(FRIEND)), "{refused}");
	assert_eq!(refused["error"]["class"], json!("invalid"), "{refused}");
	assert_eq!(notes(&world), note, "the refused verb touched the note");
	world.stopped(bot);
	world.finish();
}

/// How many direct conversations the session at `state` holds open.
fn open_directs(state: &std::path::Path) -> usize {
	let status = call(state, "status", json!({}));
	status["workspace"]["conversations"]
		.as_array()
		.unwrap()
		.iter()
		.filter(|row| row["kind"] == "direct" && row["closed"] != json!(true))
		.count()
}

/// The session holds one open conversation per registration, whichever access
/// opened it. The first access's committed open left a `.replaced` note and
/// no route yet, so the second link's plain `--dm` introduces. When the first
/// link serves again, its open keeps its route against the open conversation
/// the second one made, so both sessions end with one.
#[test]
fn opens_from_two_links_to_one_peer_end_in_one_conversation() {
	let world = World::new("bot-live-notes-one-conversation");
	run_within(Duration::from_secs(180), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let note = kept_note(&world, &first.link);
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_at(&second.link, "settle-pending@*");
		eventually("the first access's note to be marked replaced", || {
			(notes(&world) == [format!("{note}.replaced")]).then_some(())
		});
		assert_eq!(turn(&world, &[say(FRIEND, "second link")]), "exit=0");
		let sent = output(&world, 0);
		assert_eq!(sent["ok"], true, "{sent}");
		world.await_line("direct", "second link");
		world.stopped(bot);
		let bot = world.rig.serve_replacing_unreported(&first.link, FAULT);
		eventually("the first access to settle its note", || {
			notes(&world).is_empty().then_some(())
		});
		std::thread::sleep(DWELL);
		let mine = &world.fixture.peers[0].state;
		assert_eq!(
			(open_directs(mine), open_directs(world.friend())),
			(1, 1),
			"{}",
			world.rig.log()
		);
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A note whose open the session already adopted holds a receipt that
/// reached its result and awaits nothing. The session keeps answering for it
/// after its access is revoked, so the next link marks the note replaced and
/// counts it apart from this access's opens. Once newer receipts push it out,
/// the next start finds that nobody holds the operation and drops the note
/// with a log line, with nothing for the operator to do.
#[test]
fn a_revoked_accesss_adopted_note_is_replaced_until_newer_receipts_push_it_out() {
	let world = World::new("bot-live-notes-adopted");
	run_within(Duration::from_secs(180), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let note = kept_note(&world, &first.link);
		let opens = world.rig.dir.join("opens");
		let kept = std::fs::read(opens.join(&note)).unwrap();
		let settling = world.rig.serve_replacing_unreported(&first.link, FAULT);
		eventually("the first access to settle and adopt its open", || {
			notes(&world).is_empty().then_some(())
		});
		world.stopped(settling);
		std::fs::create_dir_all(&opens).unwrap();
		std::fs::write(opens.join(format!("{note}.unsettled")), kept).unwrap();
		grants.revoke(&first.name).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_unreported(&second.link, FAULT);
		eventually("the note to be marked replaced", || {
			(world.rig.status()["status"]["replaced_opens"] == 1).then_some(())
		});
		let status = world.rig.status();
		assert_eq!(status["status"]["unsettled_opens"], 0, "{status}");
		assert!(bot.stop().success());
		let room = world.fixture.room_id(0);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::ZERO).await,
			MAX_EFFECTS,
			"filling every place pushes the adopted receipt out"
		);
		let bot = world.rig.serve_replacing_unreported(&second.link, FAULT);
		eventually("the session to say it holds nothing for the note", || {
			notes(&world).is_empty().then_some(())
		});
		assert!(world.rig.log().contains(words::HOLDS_NOTHING), "{}", world.rig.log());
		let status = world.rig.status();
		assert_eq!(
			(
				&status["status"]["unsettled_opens"],
				&status["status"]["replaced_opens"]
			),
			(&json!(0), &json!(0)),
			"{status}"
		);
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
