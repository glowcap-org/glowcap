//! An agent's verb that cannot reach its session prints an error, and the
//! agent reads it. Whatever the dial or the attach fails with, the error holds
//! no part of the link that was dialed, in the verb's output or its error
//! stream.
use super::captp::{World, action};
use super::captp_direct::{output, turn};
use serde_json::json;

/// `link` with the first character of its swissnum changed: a link the
/// session holds no capability for, at the session's own address.
fn unknown_swissnum(link: &str) -> String {
	let (head, tail) = link.split_once("/s/").unwrap();
	let (swiss, hints) = tail
		.split_once('?')
		.map_or((tail, String::new()), |(swiss, hints)| (swiss, format!("?{hints}")));
	let mut letters = swiss.chars();
	let first = if letters.next() == Some('A') { 'B' } else { 'A' };
	format!("{head}/s/{first}{}{hints}", letters.as_str())
}

/// `link` pointed at `port`, in place of the port its locator names.
fn unreachable_port(link: &str, port: u16) -> String {
	let (head, tail) = link.split_once("%3A").unwrap();
	let rest = tail.trim_start_matches(|digit: char| digit.is_ascii_digit());
	format!("{head}%3A{port}{rest}")
}

/// What the latest turn's first action printed on its error stream.
fn error_stream(world: &World) -> String {
	let work = std::fs::read_dir(world.rig.dir.join("work")).unwrap().flatten();
	let path = work
		.map(|conversation| conversation.path().join("act-0.err"))
		.find(|path| path.exists())
		.unwrap();
	std::fs::read_to_string(path).unwrap()
}

#[test]
fn a_verb_that_cannot_dial_prints_an_error_with_no_part_of_the_link() {
	let world = World::new("bot-live-verb-dial-errors");
	let bot = world.serve();
	let stored = world.rig.dir.join("session.link");
	let real = std::fs::read_to_string(&stored).unwrap().trim().to_owned();
	let refused = unknown_swissnum(&real);
	let dead = unreachable_port(&real, super::session_rig::free_port());
	let say = || [action("say", json!({"text": ["hello"]}), &[])];
	// The serving loop keeps the attachment it has, and each verb reads the
	// stored link when it dials, so the link can change under a running bot.
	for (what, link, class) in [
		("an unknown swissnum", &refused, "refused"),
		("a closed port", &dead, "unreachable"),
	] {
		std::fs::write(&stored, format!("{link}\n")).unwrap();
		assert_eq!(turn(&world, &say()), "exit=1", "{what}");
		let printed = output(&world, 0);
		assert_eq!(printed["error"]["class"], class, "{what}");
		let error = error_stream(&world);
		assert!(
			error.starts_with("rooms bot: "),
			"{what}: the verb's error stream said {error:?}"
		);
	}
	world
		.rig
		.assert_keeps_no_link([real.as_str(), refused.as_str(), dead.as_str()]);
	std::fs::write(&stored, format!("{real}\n")).unwrap();
	world.stopped(bot);
	world.finish();
}
