//! The bot's home: what the agent saves there in one conversation reaches
//! every other, and a restart, `/reset`, and letting a conversation go leave
//! it as the agent left it.
use super::rig::Rig;
use serde_json::json;

/// `MAX_LISTED` and `MAX_SUMMARY_BYTES` in the bot's `home.rs`.
const MAX_LISTED: usize = 64;
const MAX_SUMMARY_BYTES: usize = 200;
/// `MAX_CONVERSATIONS` in the bot's `conversations.rs`.
const MAX_CONVERSATIONS: u64 = 256;

fn last_text(rig: &Rig, count: usize) -> String {
	rig.wait_for_replies(count)[count - 1]["text"]
		.as_str()
		.unwrap()
		.to_owned()
}

#[test]
fn a_memory_saved_in_one_conversation_is_listed_in_others_and_outlives_reset_restart_and_eviction() {
	let rig = Rig::new("bot-home");
	let memory = rig.dir.join("home/memory/ann.md");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "remember:ann.md Ann takes her tea black");
	// The agent found the home through the turn's variable.
	assert_eq!(last_text(&rig, 1), memory.display().to_string());
	rig.direct(2, "c2", "recall");
	assert_eq!(last_text(&rig, 2), "ann.md=Ann takes her tea black | unlisted=0");
	let status = rig.status();
	assert_eq!(status["home"], json!({"path": rig.dir.join("home"), "memories": 1}));

	rig.direct(3, "c1", "/reset");
	assert!(last_text(&rig, 3).starts_with("Started a new conversation"));
	assert!(memory.exists(), "/reset removed a memory");
	assert!(bot.stop().success(), "the bot exited with a failure");

	let bot = rig.serve(json!({}), None);
	rig.direct(4, "c3", "recall");
	assert_eq!(last_text(&rig, 4), "ann.md=Ann takes her tea black | unlisted=0");

	// Room lines that do not mention the bot run no turn, but each makes a
	// conversation the bot keeps, so these let c1, c2, and c3 go.
	for n in 0..MAX_CONVERSATIONS {
		rig.room(5 + n, &format!("r{n}"), "aside", false);
	}
	rig.wait_for_cursor(4 + MAX_CONVERSATIONS);
	assert!(!rig.workdir("c1").exists(), "c1 was kept");
	rig.direct(5 + MAX_CONVERSATIONS, "c1", "recall");
	assert_eq!(last_text(&rig, 5), "ann.md=Ann takes her tea black | unlisted=0");
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(
		std::fs::read_to_string(&memory).unwrap(),
		"Ann takes her tea black\nwritten by a turn\n"
	);
}

#[test]
fn the_listing_names_the_newest_memories_within_its_bounds() {
	let rig = Rig::new("bot-home-bounds");
	let bot = rig.serve(json!({}), None);
	let memory = rig.dir.join("home/memory");
	assert!(memory.is_dir(), "serve did not create the home");
	for n in 0..MAX_LISTED + 6 {
		std::fs::write(memory.join(format!("m{n:03}.md")), format!("memory {n}\n")).unwrap();
	}
	let outside = rig.dir.with_file_name("outside.md");
	std::fs::write(&outside, "never listed\n").unwrap();
	std::os::unix::fs::symlink(&outside, memory.join("link.md")).unwrap();
	std::fs::write(memory.join("long.md"), "y".repeat(MAX_SUMMARY_BYTES * 2)).unwrap();
	rig.direct(1, "c1", "recall");
	let text = last_text(&rig, 1);
	let parts: Vec<&str> = text.split(" | ").collect();
	assert_eq!(parts.len(), MAX_LISTED + 1, "{text}");
	assert_eq!(parts.last(), Some(&"unlisted=8"), "{text}");
	assert!(!text.contains("never listed"), "the listing followed a symlink: {text}");
	let long = parts.iter().find(|part| part.starts_with("long.md=")).unwrap();
	assert!(
		long.ends_with(" [cut]") && long.len() < MAX_SUMMARY_BYTES + 20,
		"{long}"
	);
	assert_eq!(rig.status()["home"]["memories"], MAX_LISTED + 8);
	assert!(bot.stop().success(), "the bot exited with a failure");
}
