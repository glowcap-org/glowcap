//! `say --dm` against a real session: a member who addressed the bot in a
//! room is answered privately, in one direct conversation that later turns
//! reuse, reopen once it is closed, and open at most once, and that the
//! member's own new opening arrives as a new one beside the closed one. In
//! that direct conversation `--dm` to the same member posts in place, in the
//! conversation the turn is in, so a nickname another member took since does
//! not redirect it.
use super::captp::{FRIEND, World, action};
use super::captp_crashes::answered;
use super::rig::eventually;
use super::session_rig::{call, run_within};
use super::words;
use rooms_application::content::session::custody::MAX_EFFECTS;
use serde_json::{Value, json};
use std::time::Duration;

/// The other member addresses the bot in the room with one turn of actions,
/// and the bot's reply there, one exit per action, once it arrives.
pub(super) fn turn(world: &World, actions: &[Value]) -> String {
	let before = replies(world).len();
	clear_outputs(world);
	world.room(&format!("@bot-host act:{}", Value::Array(actions.to_vec())));
	eventually("the turn's reply in the room", || replies(world).get(before).cloned())
}

pub(super) fn replies(world: &World) -> Vec<String> {
	world
		.seen()
		.into_iter()
		.filter(|line| line.kind == "room" && line.text.starts_with("exit="))
		.map(|line| line.text)
		.collect()
}

/// What the action at `at` of the latest turn printed, in whichever
/// conversation's working directory it ran.
pub(super) fn output(world: &World, at: usize) -> Value {
	let path = eventually("the turn's output", || {
		let work = std::fs::read_dir(world.rig.dir.join("work")).unwrap().flatten();
		work.map(|conversation| conversation.path().join(format!("act-{at}.out")))
			.find(|path| path.exists())
	});
	serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// Remove the outputs earlier turns left, so the next turn's are the only ones.
fn clear_outputs(world: &World) {
	let work = match std::fs::read_dir(world.rig.dir.join("work")) {
		Ok(work) => work,
		// No turn has run yet, so nothing is left over.
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
		Err(error) => panic!("listing the working directories: {error}"),
	};
	for conversation in work.flatten() {
		for file in std::fs::read_dir(conversation.path()).unwrap().flatten() {
			let name = file.file_name();
			let name = name.to_string_lossy();
			if name.starts_with("act-") && (name.ends_with(".out") || name.ends_with(".err")) {
				std::fs::remove_file(file.path()).unwrap();
			}
		}
	}
}

pub(super) fn say(peer: &str, text: &str) -> Value {
	action("say", json!({"dm": [peer], "text": [text]}), &[])
}

fn opens(world: &World) -> usize {
	let opened = format!("opened a direct conversation with {FRIEND} under");
	world.rig.log().matches(&opened).count()
}

/// The bot serves through a collaborator link its owner issued, so it is not
/// the access that joined the room. It shows typing there while the agent
/// runs, opens one direct conversation for its first private answer, answers
/// the member's reply there once, and reuses the conversation for its next
/// private answer, whatever case the nickname is written in. When the member
/// closes their side, the bot's side closes too, and when they write again
/// their new opening is a new conversation the bot answers and reuses. The
/// closed one stays closed beside it.
#[test]
fn a_member_answered_privately_from_a_room_gets_one_direct_conversation() {
	let world = World::new("bot-live-dm");
	let link = run_within(Duration::from_secs(30), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
		issued.link
	});
	let bot = world.rig.serve_linked(&link, json!({}));
	assert_eq!(
		turn(&world, &[say(FRIEND, "answered privately")]),
		"exit=0",
		"{}",
		world.rig.evidence()
	);
	let first = output(&world, 0);
	assert_eq!(first["ok"], true, "{first}");
	assert!(first["opened"]["operation"].is_string(), "{first}");
	answered(&world, "answered privately");
	// The member's answer reaches the bot through the same access.
	world.dm_again("reply:heard privately");
	answered(&world, "heard privately");
	// A direct turn reaches its own other person through its own conversation.
	clear_outputs(&world);
	world.dm_again(&format!("act:{}", Value::Array(vec![say("BOT-friend", "in place")])));
	answered(&world, "in place");
	let in_place = output(&world, 0);
	assert_eq!(in_place["conversation"], first["conversation"], "{in_place}");
	assert_eq!(in_place["opened"], Value::Null, "{in_place}");
	assert_eq!(
		turn(&world, &[say("Bot-Friend", "again privately")]),
		"exit=0",
		"{}",
		world.rig.evidence()
	);
	let second = output(&world, 0);
	assert_eq!(second["opened"], Value::Null, "{second}");
	assert_eq!(second["conversation"], first["conversation"], "{second}");
	answered(&world, "again privately");
	let left = call(world.friend(), "leave", json!({"conversation": [world.direct()]}));
	assert_eq!(left["status"], "committed", "{left}");
	let directs = || -> Vec<(Value, Value)> {
		let session = call(&world.fixture.peers[0].state, "status", json!({}));
		session["workspace"]["conversations"]
			.as_array()
			.unwrap()
			.iter()
			.filter(|row| row["kind"] == "direct")
			.map(|row| (row["id"].clone(), row["closed"].clone()))
			.collect()
	};
	eventually("the bot's side of the closed conversation to close", || {
		(directs() == [(first["conversation"].clone(), json!(true))]).then_some(())
	});
	world.dm_again("reply:heard after reopening");
	answered(&world, "heard after reopening");
	assert_eq!(
		turn(&world, &[say(FRIEND, "still one conversation")]),
		"exit=0",
		"{}",
		world.rig.evidence()
	);
	let third = output(&world, 0);
	assert_eq!(third["opened"], Value::Null, "{third}");
	assert_ne!(third["conversation"], first["conversation"], "{third}");
	answered(&world, "still one conversation");
	assert_eq!(
		directs(),
		[
			(first["conversation"].clone(), json!(true)),
			(third["conversation"].clone(), json!(false))
		]
	);
	let log = world.rig.log();
	assert_eq!(opens(&world), 1, "{log}");
	assert!(
		!log.contains(words::COULD_NOT_SHOW_TYPING) && !log.contains(words::COULD_NOT_STOP_TYPING),
		"a typing notice failed: {log}"
	);
	world.stopped(bot);
	assert_eq!(world.count("direct", "answered privately"), 1);
	assert_eq!(world.count("direct", "again privately"), 1);
	assert_eq!(world.count("direct", "heard privately"), 1);
	assert_eq!(world.count("direct", "heard after reopening"), 1);
	world.finish();
}

/// An open is an effect, so a `--dm` that cannot write its first log line is
/// refused before any note is written for the serving loop to send.
#[test]
fn a_direct_open_is_refused_when_its_log_line_cannot_be_written() {
	let world = World::new("bot-live-dm-unlogged");
	let bot = world.serve();
	let log = world.rig.dir.join("bot.log");
	std::fs::remove_file(&log).unwrap();
	// A directory where the log goes makes every append fail.
	std::fs::create_dir(&log).unwrap();
	assert_eq!(turn(&world, &[say(FRIEND, "never opened")]), "exit=1");
	let refused = output(&world, 0);
	let message = refused["error"]["message"].as_str().unwrap();
	assert!(message.contains(words::OPENING_LOG_FAILED), "{refused}");
	let notes = std::fs::read_dir(world.rig.dir.join("opens")).map_or(0, |notes| notes.count());
	assert_eq!(notes, 0, "a note was left for the serving loop to send");
	std::fs::remove_dir(&log).unwrap();
	world.stopped(bot);
	assert_eq!(world.count("direct", "never opened"), 0);
	world.finish();
}

/// A `--dm` open that provably sent nothing forgets its note and tells the
/// agent it failed, so the serving loop never sends it afterward. Each verb
/// is its own process, so the fault is armed for this one open.
#[test]
fn an_open_that_sent_nothing_forgets_its_note_and_the_loop_never_sends_it() {
	let world = World::new("bot-live-dm-unsent");
	let bot = world.serve_at(Some("view:introduce-unsent"));
	assert_eq!(turn(&world, &[say(FRIEND, "not yet")]), "exit=1");
	let refused = output(&world, 0);
	assert!(refused["error"]["operation"].is_null(), "{refused}");
	let notes = std::fs::read_dir(world.rig.dir.join("opens")).map_or(0, |notes| notes.count());
	assert_eq!(notes, 0, "a note outlived an open that sent nothing");
	assert_eq!(world.rig.status()["status"]["unsettled_opens"], 0);
	// With no note left, no settle pass has an open to send.
	assert_eq!(opens(&world), 0, "{}", world.rig.log());
	world.stopped(bot);
	assert_eq!(world.count("direct", "not yet"), 0);
	world.finish();
}

/// An open that sent nothing whose note cannot be removed still prints its own
/// failure, marked as settled by the bot, because the serving loop looks at
/// the note that stayed and may send it. The removal failing is not the
/// agent's failure (fault `drop-note`, which only the verb reaches).
#[test]
fn an_open_whose_note_cannot_be_dropped_prints_its_outcome_and_the_loop_settles_the_note() {
	let world = World::new("bot-live-dm-note-stays");
	let bot = world.serve_at(Some("view:introduce-unsent,drop-note"));
	assert_eq!(turn(&world, &[say(FRIEND, "note stays")]), "exit=1");
	let refused = output(&world, 0);
	assert_eq!(refused["error"]["settling"], "bot", "{refused}");
	assert_eq!(refused["ok"], false, "{refused}");
	assert!(
		world.rig.log().contains("could not drop the note of the open"),
		"{}",
		world.rig.log()
	);
	let notes = || std::fs::read_dir(world.rig.dir.join("opens")).map_or(0, |notes| notes.count());
	eventually("the loop to settle the note", || (notes() == 0).then_some(()));
	world.stopped(bot);
	world.finish();
}

/// An open whose outcome the call could not prove unsent keeps its note and
/// names its operation, and the serving loop looks at it again.
#[test]
fn an_open_that_may_have_been_sent_keeps_its_note_for_the_loop_to_settle() {
	let world = World::new("bot-live-dm-lost");
	let bot = world.serve_at(Some("view:open-lost"));
	assert_eq!(turn(&world, &[say(FRIEND, "maybe")]), "exit=1");
	let lost = output(&world, 0);
	assert!(lost["error"]["operation"].is_string(), "{lost}");
	let notes = || std::fs::read_dir(world.rig.dir.join("opens")).unwrap().count();
	eventually("the loop to settle the kept note", || (notes() == 0).then_some(()));
	eventually("the lane to free", || {
		(world.rig.status()["status"]["sending"] == 0).then_some(())
	});
	world.stopped(bot);
	// The open failed before its line, so the line never posts, and the
	// open's receipt was settled and holds no place.
	assert_eq!(world.count("direct", "maybe"), 0);
	assert_eq!(
		world.free_places(),
		MAX_EFFECTS,
		"the open's receipt still holds a place"
	);
	let log = world.rig.log();
	assert_eq!(
		log.matches(&format!("{} a direct conversation", words::MAY_HAVE_OPENED))
			.count(),
		1,
		"{log}"
	);
	// Only a kept note is looked at again by the loop.
	assert!(log.contains("the direct-message open under operation"), "{log}");
	world.finish();
}

/// The member can answer in a direct conversation the bot opened. Once the
/// bot closes it, it is opened again under the same id, and a nickname nobody
/// holds in the directory is refused before anything is sent.
#[test]
fn a_closed_direct_conversation_is_reopened_and_an_unknown_member_is_refused() {
	let world = World::new("bot-live-dm-reopen");
	let bot = world.serve();
	assert_eq!(
		turn(&world, &[say(FRIEND, "before closing")]),
		"exit=0",
		"{}",
		world.rig.evidence()
	);
	let first = output(&world, 0);
	let conversation = first["conversation"].as_str().unwrap().to_owned();
	answered(&world, "before closing");
	// The member answers there once the session has installed the route back.
	world.dm_again("reply:heard privately");
	answered(&world, "heard privately");
	let actions = [
		action("command", json!({}), &["closeDirect", conversation.as_str()]),
		say(FRIEND, "after reopening"),
		say("nobody-here", "never posted"),
	];
	let reply = turn(&world, &actions);
	assert!(
		reply.starts_with("exit=0 exit=0 exit=") && reply != "exit=0 exit=0 exit=0",
		"{reply}"
	);
	let reopened = output(&world, 1);
	assert_eq!(reopened["conversation"], conversation.as_str(), "{reopened}");
	assert!(reopened["opened"]["operation"].is_string(), "{reopened}");
	let refused = output(&world, 2);
	assert_eq!(
		(&refused["ok"], &refused["error"]["opening"]),
		(&json!(false), &json!(true)),
		"{refused}"
	);
	let message = refused["error"]["message"].as_str().unwrap();
	assert!(
		message.contains(&words::not_reached("nobody-here")) && message.contains(words::RUN_WORKSPACE),
		"{refused}"
	);
	answered(&world, "after reopening");
	assert_eq!(opens(&world), 2, "{}", world.rig.log());
	world.stopped(bot);
	assert_eq!(world.count("direct", "after reopening"), 1);
	assert_eq!(world.count("direct", "never posted"), 0);
	world.finish();
}
