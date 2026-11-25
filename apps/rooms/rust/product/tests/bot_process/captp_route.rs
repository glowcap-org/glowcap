//! `say --dm` against a real session when the introduction's route cannot be
//! kept: the receipt is given back, nothing posts, and the next open
//! introduces again and posts once.
use super::captp::{FRIEND, ROOM, World, action};
use super::captp_direct::{output, say, turn};
use super::rig::eventually;
use super::session_rig::call_when_paced;
use super::words;
use serde_json::json;

/// An introduction whose route the bot cannot keep gives its receipt back
/// and posts nothing, and the next open introduces again and posts once.
#[test]
fn an_open_that_cannot_keep_its_route_releases_its_receipt_and_the_next_one_opens() {
	let world = World::new("bot-live-dm-unopened");
	let bot = world.serve_at(Some("view:adopt-direct"));
	assert_ne!(turn(&world, &[say(FRIEND, "not posted")]), "exit=0");
	let unopened = output(&world, 0);
	assert_eq!(
		(&unopened["error"]["class"], &unopened["error"]["opening"]),
		(&json!("unopened"), &json!(true)),
		"{unopened}"
	);
	world.stopped(bot);
	let bot = world.serve();
	assert_eq!(turn(&world, &[say(FRIEND, "posted after")]), "exit=0");
	world.await_line("direct", "posted after");
	world.stopped(bot);
	assert_eq!(world.count("direct", "not posted"), 0);
	assert_eq!(world.count("direct", "posted after"), 1);
	let owner = call_when_paced(
		&world.fixture.peers[0].state,
		"reply",
		json!({"room": [ROOM], "text": ["the owner still commands"]}),
	);
	assert_eq!(owner["status"], "committed", "{owner}");
	world.finish();
}

/// An open lost before it was sent leaves a note and no receipt in the real
/// session. The next start asks the session whose receipt it is, hears that
/// no access holds one, and drops the note, so nothing counts as unsettled and
/// the next `--dm` opens and posts once. `captp_notes.rs` holds the notes of
/// an open the session does hold a receipt for.
#[test]
fn an_open_lost_before_it_was_sent_is_dropped_at_the_next_start_and_the_next_one_opens() {
	let world = World::new("bot-live-dm-release");
	let bot = world.serve_at(Some("view:open-lost,settle-pending@*"));
	assert_ne!(turn(&world, &[say(FRIEND, "lost before sending")]), "exit=0");
	assert!(output(&world, 0)["error"]["operation"].is_string());
	world.stopped(bot);
	let notes = || std::fs::read_dir(world.rig.dir.join("opens")).unwrap().count();
	assert_eq!(notes(), 1, "the lost open left no note");
	let bot = world.serve_at(None);
	eventually("the note the session holds nothing for to go", || {
		(notes() == 0).then_some(())
	});
	let status = world.rig.status();
	assert_eq!(status["status"]["unsettled_opens"], 0, "{status}");
	let log = world.rig.log();
	assert!(log.contains(words::HOLDS_NOTHING), "{log}");
	assert_eq!(turn(&world, &[say(FRIEND, "posted after the drop")]), "exit=0");
	world.await_line("direct", "posted after the drop");
	world.stopped(bot);
	assert_eq!(world.count("direct", "lost before sending"), 0);
	assert_eq!(world.count("direct", "posted after the drop"), 1);
	world.finish();
}

/// The only note on disk, read back.
fn the_note(world: &World) -> (std::path::PathBuf, serde_json::Value) {
	let mut notes = std::fs::read_dir(world.rig.dir.join("opens"))
		.unwrap()
		.map(|entry| entry.unwrap().path());
	let path = notes.next().expect("no note");
	assert!(notes.next().is_none(), "more than one note");
	let note = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
	(path, note)
}

/// A note belongs to the turn that wrote it. A later turn naming its operation
/// is told the bot is settling it, and the note, the log, and the session are
/// untouched. The bot's own settling then decides it (`captp_direct`).
#[test]
fn a_look_again_by_another_turn_is_refused_and_leaves_the_note() {
	let world = World::new("bot-live-dm-look-unsent");
	let bot = world.serve_at(Some("view:open-lost,settle-pending@*"));
	assert_ne!(turn(&world, &[say(FRIEND, "maybe")]), "exit=0");
	let (path, note) = the_note(&world);
	let operation = path.file_stem().unwrap().to_str().unwrap().to_owned();
	let again = action(
		"say",
		json!({"dm": [FRIEND], "text": ["maybe"], "operation": [operation], "base": [note["base"].to_string()]}),
		&[],
	);
	assert_eq!(turn(&world, &[again]), "exit=1");
	let refused = output(&world, 0);
	assert!(
		refused["error"]["message"]
			.as_str()
			.unwrap()
			.contains(&words::settling(FRIEND)),
		"{refused}"
	);
	let (kept, after) = the_note(&world);
	assert_eq!(kept, path, "the look dropped the note");
	assert_eq!(after, note, "the look changed the note");
	let log = world.rig.log();
	assert_eq!(log.matches(words::OPENING).count(), 1, "{log}");
	world.stopped(bot);
	assert_eq!(world.count("direct", "maybe"), 0);
	world.finish();
}

/// A look again names an operation of the serving access's own. A note
/// another access sent is named `.replaced`, so the verb finds no open of the
/// serving access to look at and sends nothing.
#[test]
fn a_look_again_at_an_open_of_a_replaced_link_is_refused_and_sends_nothing() {
	let world = World::new("bot-live-dm-look-replaced");
	let bot = world.serve_at(Some("view:open-lost,settle-pending@*"));
	assert_ne!(turn(&world, &[say(FRIEND, "maybe")]), "exit=0");
	let (path, note) = the_note(&world);
	let operation = path.file_stem().unwrap().to_str().unwrap().to_owned();
	// The same note, as a replacement that reached another access left it.
	let renamed = path.with_extension("json.replaced");
	std::fs::rename(&path, &renamed).unwrap();
	let path = renamed;
	let replaced = std::fs::read(&path).unwrap();
	let again = action(
		"say",
		json!({"dm": [FRIEND], "text": ["maybe"], "operation": [operation], "base": [note["base"].to_string()]}),
		&[],
	);
	assert_eq!(turn(&world, &[again]), "exit=1");
	let refused = output(&world, 0);
	assert!(
		refused["error"]["message"]
			.as_str()
			.unwrap()
			.contains(words::NO_UNCERTAIN_OPEN),
		"{refused}"
	);
	assert_eq!(std::fs::read(&path).unwrap(), replaced);
	let log = world.rig.log();
	assert_eq!(
		log.matches(words::OPENING).count(),
		1,
		"the refused look began an open: {log}"
	);
	world.stopped(bot);
	assert_eq!(world.count("direct", "maybe"), 0);
	world.finish();
}
