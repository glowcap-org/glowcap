//! A bot `send` whose room takes each append slowly: the fill outlasts the
//! 15 s a `say` waits, each of its rounds is within the bound, and the verb
//! stays for it and prints the files' final outcome, so the files arrive.
use super::captp::{World, action};
use super::captp_direct::{output, turn};
use super::rig::eventually;
use super::session_rig::{attach, host, run_within};
use serde_json::json;
use std::time::Duration;

/// How long the session's view waits for a `say` (`rooms.rs`).
const SAY_WAIT: Duration = Duration::from_secs(15);

#[test]
fn send_waits_for_a_slow_fill_and_the_files_arrive() {
	let mut world = World::new("bot-slow-send");
	world.fixture.peers[0].restart_at(Some("slow-upload-writes"));
	let bot = world.serve();
	world.dm("reply:ready");
	world.await_line("direct", "ready");
	assert_eq!(turn(&world, &[action("workspace", json!({}), &[])]), "exit=0");
	let work = std::fs::read_dir(world.rig.dir.join("work"))
		.unwrap()
		.flatten()
		.map(|conversation| conversation.path())
		.find(|path| path.join("act-0.out").exists())
		.unwrap();
	let content: Vec<u8> = (0..150_000usize).map(|at| (at % 251) as u8).collect();
	std::fs::write(work.join("big.bin"), &content).unwrap();
	let args = action(
		"send",
		json!({"text": ["slow files"], "file": [work.join("big.bin")]}),
		&[],
	);
	let started = std::time::Instant::now();
	assert_eq!(turn(&world, &[args]), "exit=0");
	assert!(
		started.elapsed() > SAY_WAIT,
		"the fill did not outlast a `say`'s wait ({:?}), so the fault did not slow it",
		started.elapsed()
	);
	let printed = output(&world, 0);
	assert_eq!(printed["status"], "committed", "{printed}");
	assert_eq!(
		printed["files"], "complete",
		"the verb waits for the slow fill and prints how it ended: {printed}"
	);
	let link = world.fixture.peers[1].link.clone();
	let destination = world.fixture.temp.join("fetched.bin");
	let fetched = run_within(Duration::from_secs(25), async {
		let runtime = host().await;
		let friend = attach(&runtime, &link).await;
		let batch = friend.events("", false).await.unwrap();
		let attachment = batch
			.events
			.iter()
			.find(|event| !event.attachments.is_empty())
			.map(|event| event.attachments[0].clone())
			.expect("the line with files reached the friend");
		friend.fetch(&attachment, &destination).await.unwrap();
		runtime.close(glowcap::PendingWork::Cancel).await.unwrap();
		std::fs::read(&destination).unwrap()
	});
	assert_eq!(fetched, content, "the files arrived whole");
	world.stopped(bot);
	world.finish();
}

/// A turn in the room that sends `big.bin` once, as an agent that follows its
/// prompt does, and the directory its agent works in once it runs. The file
/// is placed there and the agent released, so the room's post is the only
/// thing the test waits for.
fn sending(world: &World, caption: &str) -> std::path::PathBuf {
	let args = action("send", json!({"text": [caption], "file": ["big.bin"]}), &[]);
	world.room(&format!("@bot-host act-once:{}", serde_json::Value::Array(vec![args])));
	let work = eventually("the agent to start", || {
		std::fs::read_dir(world.rig.dir.join("work"))
			.ok()?
			.flatten()
			.map(|conversation| conversation.path())
			.find(|path| {
				std::fs::read_to_string(path.join("prompt.txt")).is_ok_and(|prompt| prompt.contains("act-once:"))
			})
	});
	let content: Vec<u8> = (0..150_000usize).map(|at| (at % 251) as u8).collect();
	std::fs::write(work.join("big.bin"), &content).unwrap();
	std::fs::write(work.join("go"), "").unwrap();
	work
}

/// The prompt the restarted run was given, once it answered `skipped`.
fn rerun_prompt(world: &World, work: &std::path::Path) -> String {
	world.await_line("room", "skipped");
	std::fs::read_to_string(work.join("prompt.txt")).unwrap()
}

/// The bot's record of the cut-off `send` in `prompt`: its line, which says
/// not to send again whether the bot knows the outcome or still settles it.
fn record_of_send(prompt: &str) -> &str {
	let line = prompt
		.lines()
		.find(|line| line.starts_with("- send 1 file to this conversation: "))
		.unwrap_or_else(|| panic!("the prompt holds no record of the send: {prompt}"));
	assert!(line.contains("Do not"), "{line}");
	line
}

/// A bot stopped while its `send` waits for the fill takes the verb with it.
/// The line was posted before the stop, and the restarted bot keeps it and
/// tells the rerun what its `send` did, so an agent that follows the prompt
/// does not send again and the line stands once.
#[test]
fn a_bot_stopped_while_a_send_waits_tells_the_rerun_what_it_sent() {
	let mut world = World::new("bot-stop-send");
	world.fixture.peers[0].restart_at(Some("slow-upload-writes"));
	let bot = world.serve();
	world.dm("reply:ready");
	world.await_line("direct", "ready");
	assert_eq!(turn(&world, &[action("workspace", json!({}), &[])]), "exit=0");
	let work = sending(&world, "stopped files");
	// The post is acknowledged and the fill is slow, so the verb is waiting.
	world.await_line("room", "stopped files");
	world.stopped(bot);
	let bot = world.serve();
	let prompt = rerun_prompt(&world, &work);
	record_of_send(&prompt);
	assert!(
		prompt.contains("This run resumes your session"),
		"a stopped run keeps its session, so the rerun may say so: {prompt}"
	);
	eventually("the loop to settle the send", || {
		world.rig.log().contains(super::words::ACTION_KEPT).then_some(())
	});
	assert_eq!(world.count("room", "stopped files"), 1, "the line stands once");
	super::captp_crashes::still_open(&world);
	world.stopped(bot);
	world.finish();
}

/// The same for a conversation's first turn killed outright: no harness
/// session was stored, so the rerun is not told its history shows anything,
/// and it is told what its `send` did.
#[test]
fn a_first_turn_killed_during_a_send_tells_the_rerun_without_a_history() {
	let mut world = World::new("bot-kill-first-send");
	world.fixture.peers[0].restart_at(Some("slow-upload-writes"));
	let mut bot = world.serve();
	// A line sent before the bot reads the head of activity is never asked.
	world.dm("reply:ready");
	world.await_line("direct", "ready");
	let work = sending(&world, "killed files");
	world.await_line("room", "killed files");
	bot.kill();
	bot.process.wait();
	let bot = world.serve();
	let prompt = rerun_prompt(&world, &work);
	record_of_send(&prompt);
	assert!(
		!prompt.contains("history"),
		"no harness session was stored, so no history is claimed: {prompt}"
	);
	eventually("the loop to settle the send", || {
		world.rig.log().contains(super::words::ACTION_KEPT).then_some(())
	});
	assert_eq!(world.count("room", "killed files"), 1, "the line stands once");
	world.stopped(bot);
	world.finish();
}
