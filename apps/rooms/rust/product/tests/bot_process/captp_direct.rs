//! `say --dm` against a real session: a member who addressed the bot in a
//! room is answered privately, in one direct conversation that later turns
//! reuse, reopen once it is closed, and open at most once, and that the
//! member's own new opening arrives as a new one beside the closed one.
use super::captp::{ROOM, World, action};
use super::rig::eventually;
use super::session_rig::{call, call_when_paced, host, run_within};
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

/// A turn of one action the bot carries out, or a failure that shows what the
/// action printed and what the bot logged.
fn answered(world: &World, actions: &[Value]) {
	assert_eq!(turn(world, actions), "exit=0", "{}", world.rig.evidence());
}

fn replies(world: &World) -> Vec<String> {
	world
		.seen()
		.into_iter()
		.filter(|line| line.kind == "room" && line.text.starts_with("exit="))
		.map(|line| line.text)
		.collect()
}

fn say(peer: &str, text: &str) -> Value {
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
	answered(&world, &[say(FRIEND, "answered privately")]);
	let first = world.rig.act_output(0);
	assert_eq!(first["ok"], true, "{first}");
	assert!(first["opened"]["operation"].is_string(), "{first}");
	world.await_line("direct", "answered privately");
	// The member's answer reaches the bot through the same access.
	world.dm_again("reply:heard privately");
	world.await_line("direct", "heard privately");
	answered(&world, &[say("Bot-Friend", "again privately")]);
	let second = world.rig.act_output(0);
	assert_eq!(second["opened"], Value::Null, "{second}");
	assert_eq!(second["conversation"], first["conversation"], "{second}");
	world.await_line("direct", "again privately");
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
	world.await_line("direct", "heard after reopening");
	answered(&world, &[say(FRIEND, "still one conversation")]);
	let third = world.rig.act_output(0);
	assert_eq!(third["opened"], Value::Null, "{third}");
	assert_ne!(third["conversation"], first["conversation"], "{third}");
	world.await_line("direct", "still one conversation");
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
		!log.contains("showing typing") && !log.contains("show typing"),
		"a typing notice failed: {log}"
	);
	world.stopped(bot);
	assert_eq!(world.count("direct", "answered privately"), 1);
	assert_eq!(world.count("direct", "again privately"), 1);
	assert_eq!(world.count("direct", "heard privately"), 1);
	assert_eq!(world.count("direct", "heard after reopening"), 1);
	world.fixture.finish();
}

/// The member can answer in a direct conversation the bot opened. Once the
/// bot closes it, it is opened again under the same id, and a nickname nobody
/// in the room wrote under is refused before anything is sent.
#[test]
fn a_closed_direct_conversation_is_reopened_and_an_unknown_member_is_refused() {
	let world = World::new("bot-live-dm-reopen");
	let bot = world.serve();
	answered(&world, &[say(FRIEND, "before closing")]);
	let first = world.rig.act_output(0);
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
	let reopened = world.rig.act_output(1);
	assert_eq!(reopened["conversation"], conversation.as_str(), "{reopened}");
	assert!(reopened["opened"]["operation"].is_string(), "{reopened}");
	let refused = world.rig.act_output(2);
	assert_eq!(
		(&refused["ok"], &refused["error"]["opening"]),
		(&json!(false), &json!(true)),
		"{refused}"
	);
	let message = refused["error"]["message"].as_str().unwrap();
	assert!(message.contains("nobody-here has not written in it"), "{refused}");
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
	let unopened = world.rig.act_output(0);
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
	answered(&world, &[say(FRIEND, "posted after")]);
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
