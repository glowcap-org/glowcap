//! The bot against real Rooms processes: a server, the bot's own session, and
//! another member's session, all over loopback CapTP. Each test proves one
//! thing a person at the other member's side can see.
use super::rig::{Bot, Rig, WAIT, eventually};
use super::session_rig::{Fixture, attach, call, free_port, host, run_within, try_call};
use rooms_services::session::attached::{EffectStatus, Outgoing};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
	path::Path,
	time::{Duration, Instant},
};

pub(super) const ROOM: &str = "bot-room";
/// How long a stopped bot's last lines may take to reach the other member's
/// session, before a count of what it answered is final.
pub(super) const DWELL: Duration = Duration::from_secs(1);
pub(super) const BOT: &str = "bot-host";
const FRIEND: &str = "bot-friend";

pub(super) struct World {
	pub(super) fixture: Fixture,
	pub(super) rig: Rig,
}

/// One line the other member's session has seen.
#[derive(Debug)]
pub(super) struct Seen {
	pub(super) kind: String,
	pub(super) text: String,
	pub(super) files: usize,
	/// The line number and what happened to it.
	pub(super) line: Option<(u64, String)>,
}

impl World {
	pub(super) fn new(label: &str) -> Self {
		let fixture = Fixture::start_on(label, &[BOT, FRIEND], ROOM, &[free_port(), 0]);
		Self {
			fixture,
			rig: Rig::new(label),
		}
	}

	pub(super) fn friend(&self) -> &Path {
		&self.fixture.peers[1].state
	}

	pub(super) fn serve(&self) -> Bot {
		self.serve_at(None)
	}

	/// Start the bot armed to end itself at `fault`.
	pub(super) fn serve_at(&self, fault: Option<&str>) -> Bot {
		self.rig.serve_linked_at(&self.fixture.peers[0].link, json!({}), fault)
	}

	/// The other member writes to the bot in a private conversation.
	pub(super) fn dm(&self, text: &str) {
		let sent = call(self.friend(), "reply", json!({"dm": [BOT], "text": [text]}));
		assert_eq!(sent["status"], "committed", "{sent}");
	}

	/// The id of the private conversation with the bot, as the other member knows it.
	pub(super) fn direct(&self) -> String {
		let status = call(self.friend(), "status", json!({}));
		status["workspace"]["conversations"]
			.as_array()
			.and_then(|rows| rows.iter().find(|row| row["kind"] == "direct"))
			.and_then(|row| row["id"].as_str())
			.map(str::to_owned)
			.unwrap_or_else(|| panic!("no direct conversation: {status}"))
	}

	/// The other member writes to the bot, trying again until the restarted
	/// session is registered with the server and accepts it.
	pub(super) fn dm_again(&self, text: &str) {
		eventually("the session to accept a private message", || {
			try_call(self.friend(), "reply", json!({"dm": [BOT], "text": [text]})).ok()
		});
	}

	/// The other member writes in the room.
	pub(super) fn room(&self, text: &str) {
		let sent = call(self.friend(), "reply", json!({"room": [ROOM], "text": [text]}));
		assert_eq!(sent["status"], "committed", "{sent}");
	}

	pub(super) fn seen(&self) -> Vec<Seen> {
		let batch = call(self.friend(), "tick", json!({"wait": ["0"]}));
		batch["pending"]
			.as_array()
			.unwrap()
			.iter()
			.map(|event| Seen {
				kind: event["event"]["target"]["kind"].as_str().unwrap_or_default().into(),
				text: event["event"]["notice"]["text"].as_str().unwrap_or_default().into(),
				files: event["files"].as_array().map_or(0, Vec::len),
				line: event["event"]["notice"]["marker"]["id"]
					.as_u64()
					.zip(event["event"]["notice"]["marker"]["change"].as_str())
					.map(|(id, change)| (id, change.to_owned())),
			})
			.collect()
	}

	pub(super) fn count(&self, kind: &str, text: &str) -> usize {
		self.seen()
			.iter()
			.filter(|line| line.kind == kind && line.text == text)
			.count()
	}

	/// Wait until the other member has seen `text` in a `kind` conversation.
	pub(super) fn await_line(&self, kind: &str, text: &str) {
		eventually(&format!("{text:?} in a {kind}"), || {
			(self.count(kind, text) > 0).then_some(())
		});
	}

	/// Stop the bot, then wait [`DWELL`] so every line it committed has arrived.
	pub(super) fn stopped(&self, bot: Bot) {
		assert!(bot.stop().success(), "the bot exited with a failure");
		std::thread::sleep(DWELL);
	}

	/// The bot's status once it is up.
	pub(super) fn access(&self) -> Value {
		self.rig.status()["status"]["access"].clone()
	}
}

#[test]
fn a_private_message_and_a_mention_are_answered_once_and_other_room_lines_are_not() {
	let world = World::new("bot-live-replies");
	let bot = world.serve();
	world.dm("reply:hello there");
	world.await_line("direct", "hello there");
	world.room("@bot-host reply:seen in the room");
	world.await_line("room", "seen in the room");
	world.room("reply:not for the bot");
	world.room("@bot-host reply:the last answer");
	world.await_line("room", "the last answer");
	world.stopped(bot);
	assert_eq!(world.count("direct", "hello there"), 1);
	assert_eq!(world.count("room", "seen in the room"), 1);
	assert_eq!(
		world.count("room", "not for the bot"),
		0,
		"a line that named no one was answered"
	);
	// The link is the bot's authority and appears in no output.
	let link = &world.fixture.peers[0].link;
	let swiss = link.rsplit('/').next().unwrap().to_owned();
	assert!(!world.rig.log().contains(&swiss) && !world.rig.status().to_string().contains(&swiss));
	world.fixture.finish();
}

#[test]
fn history_from_before_the_first_start_is_never_answered() {
	let world = World::new("bot-live-history");
	world.dm("reply:an old question");
	world.room("@bot-host reply:an old mention");
	let bot = world.serve();
	world.dm("reply:a new question");
	world.await_line("direct", "a new question");
	world.stopped(bot);
	assert_eq!(world.count("direct", "an old question"), 0);
	assert_eq!(world.count("room", "an old mention"), 0);
	assert_eq!(world.count("direct", "a new question"), 1);
	world.fixture.finish();
}

fn bytes(length: usize) -> Vec<u8> {
	(0..length)
		.map(|at| (at as u8).wrapping_mul(31).wrapping_add(7))
		.collect()
}

#[test]
fn a_file_posted_to_the_bot_reaches_the_harness_with_the_same_bytes_and_is_cleaned_up() {
	let world = World::new("bot-live-files");
	let bot = world.serve();
	world.dm("reply:ready");
	world.await_line("direct", "ready");
	let direct = world.direct();
	let sent = world.fixture.temp.join("data.bin");
	let content = bytes(150_000);
	std::fs::write(&sent, &content).unwrap();
	let hash: String = Sha256::digest(&content)
		.iter()
		.map(|byte| format!("{byte:02x}"))
		.collect();
	// The sender serves the bytes, so its host stays up and polling until the
	// bot has fetched them and answered.
	let reply = run_within(WAIT, async {
		let runtime = host().await;
		let friend = attach(&runtime, &world.fixture.peers[1].link).await;
		let posted = friend
			.send_files(
				"bot-files-1",
				&direct,
				"describe-files",
				&[Outgoing::open(&sent).unwrap()],
			)
			.await
			.unwrap();
		assert_eq!(posted.status, EffectStatus::Committed);
		let until = Instant::now() + WAIT - Duration::from_secs(5);
		let reply = loop {
			if let Some(line) = world
				.seen()
				.into_iter()
				.find(|line| line.kind == "direct" && line.text.starts_with("inbox/"))
			{
				break line;
			}
			assert!(Instant::now() < until, "the harness never described the file");
			tokio::time::sleep(Duration::from_millis(50)).await;
		};
		runtime.close(glowcap::PendingWork::Cancel).await.unwrap();
		reply
	});
	assert!(
		reply.text.ends_with(&format!("-data.bin bytes=150000 sha256={hash}")),
		"{}",
		reply.text
	);
	// The turn is done, so the saved copy is gone.
	eventually("the inbox to be removed", || {
		let work = world.rig.dir.join("work");
		let left = std::fs::read_dir(&work)
			.unwrap()
			.flatten()
			.filter_map(|conversation| std::fs::read_dir(conversation.path().join("inbox")).ok())
			.flat_map(|turns| turns.flatten())
			.count();
		(left == 0).then_some(())
	});
	world.stopped(bot);
	world.fixture.finish();
}

/// A verb as the harness runs it, which names no bot directory.
pub(super) fn action(verb: &str, named: Value, arguments: &[&str]) -> Value {
	json!({"verb": verb, "state": "", "named": named, "arguments": arguments})
}
