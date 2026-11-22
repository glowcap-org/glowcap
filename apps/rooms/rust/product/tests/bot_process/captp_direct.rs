//! `say --dm` against a real session: a member who addressed the bot in a
//! room is answered privately, in one direct conversation that later turns
//! reuse, reopen once it is closed, and open at most once.
use super::captp::{ROOM, World, action};
use super::rig::eventually;
use super::session_rig::{call_when_paced, host, run_within};
use rooms_application::content::session::{Preset, Terms};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::Grants;
use serde_json::{Value, json};
use std::time::Duration;

const FRIEND: &str = "bot-friend";

/// The other member addresses the bot in the room with one turn of actions,
/// and the bot's reply there, one exit per action, once it arrives.
fn turn(world: &World, actions: &[Value]) -> String {
	let before = replies(world).len();
	world.room(&format!("@bot-host act:{}", Value::Array(actions.to_vec())));
	eventually("the turn's reply in the room", || replies(world).get(before).cloned())
}

fn replies(world: &World) -> Vec<String> {
	world
		.seen()
		.into_iter()
		.filter(|line| line.kind == "room" && line.text.starts_with("exit="))
		.map(|line| line.text)
		.collect()
}

/// What the action at `at` of the latest room turn printed.
fn output(world: &World, at: usize) -> Value {
	let work = std::fs::read_dir(world.rig.dir.join("work")).unwrap().flatten();
	let path = work
		.map(|conversation| conversation.path().join(format!("act-{at}.out")))
		.find(|path| path.exists())
		.unwrap();
	serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn say(peer: &str, text: &str) -> Value {
	action("say", json!({"dm": [peer], "text": [text]}), &[])
}

fn opens(world: &World) -> usize {
	let opened = format!("opened a direct conversation with {FRIEND} under");
	world.rig.log().matches(&opened).count()
}

/// The bot serves through a link its owner issued, so it is not the access
/// that joined the room. It shows typing there while the agent runs, opens one
/// direct conversation for its first private answer, and reuses it for the
/// next, whatever case the nickname is written in.
#[test]
fn a_member_answered_privately_from_a_room_gets_one_direct_conversation() {
	let world = World::new("bot-live-dm");
	let management = std::fs::read_to_string(world.fixture.peers[0].state.join("management.sturdyref")).unwrap();
	let link = run_within(Duration::from_secs(30), async {
		let issuer = host().await;
		let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
		let terms = Terms::new(Preset::Collaborator.values()).unwrap();
		let issued = grants.issue("the bot", &terms).await.unwrap();
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
		issued.link
	});
	let bot = world.rig.serve_linked(&link, json!({}));
	assert_eq!(turn(&world, &[say(FRIEND, "answered privately")]), "exit=0");
	let first = output(&world, 0);
	assert_eq!(first["ok"], true, "{first}");
	assert!(first["opened"]["operation"].is_string(), "{first}");
	world.await_line("direct", "answered privately");
	assert_eq!(turn(&world, &[say("Bot-Friend", "again privately")]), "exit=0");
	let second = output(&world, 0);
	assert_eq!(second["opened"], Value::Null, "{second}");
	assert_eq!(second["conversation"], first["conversation"], "{second}");
	world.await_line("direct", "again privately");
	let log = world.rig.log();
	assert_eq!(opens(&world), 1, "{log}");
	assert!(
		!log.contains("showing typing") && !log.contains("show typing"),
		"a typing notice failed: {log}"
	);
	world.stopped(bot);
	assert_eq!(world.count("direct", "answered privately"), 1);
	assert_eq!(world.count("direct", "again privately"), 1);
	world.fixture.finish();
}

/// The member can answer in a direct conversation the bot opened. Once the
/// bot closes it, it is opened again under the same id, and a nickname no
/// member holds is refused before anything is sent.
#[test]
fn a_closed_direct_conversation_is_reopened_and_an_unknown_member_is_refused() {
	let world = World::new("bot-live-dm-reopen");
	let bot = world.serve();
	assert_eq!(turn(&world, &[say(FRIEND, "before closing")]), "exit=0");
	let first = output(&world, 0);
	let conversation = first["conversation"].as_str().unwrap().to_owned();
	world.await_line("direct", "before closing");
	// The member answers there once the session has installed the route back.
	world.dm_again("reply:heard privately");
	world.await_line("direct", "heard privately");
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
	assert!(
		refused["error"]["message"].as_str().unwrap().contains("nobody-here"),
		"{refused}"
	);
	world.await_line("direct", "after reopening");
	assert_eq!(opens(&world), 2, "{}", world.rig.log());
	world.stopped(bot);
	assert_eq!(world.count("direct", "after reopening"), 1);
	assert_eq!(world.count("direct", "never posted"), 0);
	world.fixture.finish();
}

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
	assert!(
		!unopened["error"]["message"].as_str().unwrap().contains("still held"),
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
	world.fixture.finish();
}
