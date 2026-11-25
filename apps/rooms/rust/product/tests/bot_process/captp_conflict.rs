//! A verb the session answers as a moved workspace, which committed nothing,
//! tries again under a new operation, so another turn posting at the same
//! moment is never an agent's failure. A `--dm` open that meets it forgets its
//! note and opens again under a new operation.
use super::captp::{FRIEND, World, action};
use super::captp_direct::{output, say, turn};
use super::rig::eventually;
use super::words;
use serde_json::json;

/// Another turn posting at the same moment moves the workspace under a `say`.
/// That committed nothing, so the verb says again under a new operation and
/// the agent sees no failure, and the line posts once. The armed session
/// answers the same operation as moved every time, so a retry that kept it
/// fails the verb.
#[test]
fn a_say_that_meets_a_moved_workspace_says_again_and_posts_once() {
	let world = World::new("bot-live-say-conflict");
	let bot = world.serve_at(Some("view:say-conflict"));
	assert_eq!(turn(&world, &[say(FRIEND, "after the conflict")]), "exit=0");
	let said = output(&world, 0);
	assert_eq!(said["ok"], true, "{said}");
	// The open was this verb's, made once before the retry, so it is reported
	// and the retry reached no second conversation.
	assert!(said["opened"]["operation"].is_string(), "{said}");
	world.await_line("direct", "after the conflict");
	world.stopped(bot);
	assert_eq!(world.count("direct", "after the conflict"), 1);
	let log = world.rig.log();
	let opened = format!("opened a direct conversation with {FRIEND} under");
	assert_eq!(log.matches(&opened).count(), 1, "{log}");
	assert!(!log.contains(words::REUSED_DIRECT), "{log}");
	// The armed conflict always retries once. The retry can meet one moved
	// workspace of its own: the session's supervisor installs the inbox of each
	// conversation it starts to supervise with one write, and this turn opens
	// one, so one retry can find its base passed. The bot writes the workspace
	// only for a settled line or open, and this turn's are its own and still
	// open, so a third try fails this.
	let retries = log.matches(words::CONFLICT_RETRY).count();
	assert!((1..=2).contains(&retries), "{retries} retries: {log}");
	world.finish();
}

/// A `--dm` open the session answers as a moved workspace committed nothing,
/// so it forgets its note and opens again under a new operation: the agent
/// sees no failure, one conversation opens, and the line posts once. The
/// armed session answers the same operation as moved every time, so a retry
/// under the first operation fails the verb, and the serving loop, which
/// shares the fault, would forget a note the verb leaked before any check
/// could see it, so the verb's own log lines say what became of the note.
#[test]
fn a_dm_open_that_meets_a_moved_workspace_opens_again_and_posts_once() {
	let world = World::new("bot-live-open-conflict");
	let bot = world.serve_at(Some("view:open-conflict"));
	assert_eq!(turn(&world, &[say(FRIEND, "after the open conflict")]), "exit=0");
	let said = output(&world, 0);
	assert_eq!(said["ok"], true, "{said}");
	world.await_line("direct", "after the open conflict");
	world.stopped(bot);
	assert_eq!(world.count("direct", "after the open conflict"), 1);
	let log = world.rig.log();
	let opened = format!("opened a direct conversation with {FRIEND} under");
	assert_eq!(log.matches(&opened).count(), 1, "{log}");
	// The open meets the moved workspace and tries again. The say after it can
	// meet one too: the session's supervisor installs the inbox of each
	// conversation it starts to supervise with one write, and this turn opens
	// one, so one say can find its base passed and try again under a new
	// operation. The bot writes nothing for this turn's own open lines.
	let retries = log.matches(words::CONFLICT_RETRY).count();
	assert!((1..=2).contains(&retries), "{retries} retries: {log}");
	assert_eq!(
		log.matches(words::MOVED).count(),
		1,
		"the verb did not forget its note: {log}"
	);
	assert!(
		!log.contains(&format!("{} a direct conversation", words::MAY_HAVE_OPENED)),
		"the open was left unsettled: {log}"
	);
	assert_eq!(std::fs::read_dir(world.rig.dir.join("opens")).unwrap().count(), 0);
	world.finish();
}

/// A `send` the session answers as a moved workspace is sent again, and the
/// file posts once.
#[test]
fn a_send_that_meets_a_moved_workspace_sends_again_and_posts_once() {
	let world = World::new("bot-live-send-conflict");
	let bot = world.serve_at(Some("view:send-conflict"));
	world.dm("reply:ready");
	world.await_line("direct", "ready");
	let workdir = std::fs::read_dir(world.rig.dir.join("work"))
		.unwrap()
		.flatten()
		.next()
		.unwrap()
		.path();
	std::fs::write(workdir.join("note.txt"), "a file from the bot").unwrap();
	let requests = json!([action(
		"send",
		json!({"text": ["file after conflict"], "file": [workdir.join("note.txt")]}),
		&[]
	)]);
	world.dm(&format!("act:{requests}"));
	world.await_line("direct", "exit=0");
	let sent = eventually("the file", || {
		world.seen().into_iter().find(|line| line.text == "file after conflict")
	});
	assert_eq!(sent.files, 1);
	world.stopped(bot);
	assert_eq!(world.count("direct", "file after conflict"), 1);
	assert_eq!(
		world.rig.log().matches(words::CONFLICT_RETRY).count(),
		1,
		"the conflict ran no retry: {}",
		world.rig.log()
	);
	world.finish();
}

/// `command` is the verb every other session command goes through, so it
/// tries again as `say` does.
#[test]
fn a_command_that_meets_a_moved_workspace_runs_again_and_posts_once() {
	let world = World::new("bot-live-command-conflict");
	let bot = world.serve_at(Some("view:command-conflict"));
	world.dm("reply:ready");
	world.await_line("direct", "ready");
	let room = world.fixture.room_id(0);
	let requests = json!([action(
		"command",
		json!({}),
		&["say", room.as_str(), "command after conflict"]
	)]);
	world.dm(&format!("act:{requests}"));
	world.await_line("direct", "exit=0");
	world.await_line("room", "command after conflict");
	world.stopped(bot);
	assert_eq!(world.count("room", "command after conflict"), 1);
	assert_eq!(
		world.rig.log().matches(words::CONFLICT_RETRY).count(),
		1,
		"the conflict ran no retry: {}",
		world.rig.log()
	);
	world.finish();
}
