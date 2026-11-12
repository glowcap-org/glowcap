//! The options the `glowcap` command hands each Rooms front, held against
//! what the front reads. The command's own test holds its flags to the same
//! list, so an option added on one side fails on the other until both name it.
use std::collections::BTreeSet;

const HANDED: &str = include_str!("../../../../../test/cli/rooms_front_options.txt");

/// The names under `[front]`, one to a line.
fn handed(front: &str) -> BTreeSet<&'static str> {
	let heading = format!("[{front}]");
	let names: BTreeSet<_> = HANDED
		.lines()
		.skip_while(|line| *line != heading)
		.skip(1)
		.take_while(|line| !line.starts_with('['))
		.filter(|line| !line.is_empty() && !line.starts_with('#'))
		.collect();
	assert!(!names.is_empty(), "the list has no section for {front}");
	names
}

/// `launcher` names the options the command sets itself and offers nobody.
fn held(front: &str, read: impl Iterator<Item = String>, launcher: &[&str]) {
	let handed = handed(front);
	let read: BTreeSet<String> = read.collect();
	for name in &handed {
		assert!(
			read.contains(*name),
			"the command hands {front} --{name}, which it does not read"
		);
		assert!(
			!launcher.contains(name),
			"the command offers --{name}, which it sets for {front} itself"
		);
	}
	for name in &read {
		assert!(
			handed.contains(name.as_str()) || launcher.contains(&name.as_str()),
			"{front} reads --{name}, which the command does not offer"
		);
	}
}

fn named(options: impl Iterator<Item = &'static str>) -> impl Iterator<Item = String> {
	options.map(str::to_owned)
}

#[test]
fn every_front_reads_what_the_command_hands_it_and_nothing_it_cannot_name() {
	use crate::{archive, irc_bridge, irc_server, server, session, web};
	held("rooms-server", named(server::Config::options()), &[]);
	held("rooms-session", named(session::Config::options()), &[]);
	held("rooms-web", web::Config::options(), web::Config::LAUNCHER);
	held(
		"rooms-irc-server",
		named(irc_server::Config::OPTIONS.iter().copied()),
		&[],
	);
	held("rooms-irc-bridge", named(irc_bridge::Config::options()), &[]);
	held("rooms-archive", named(archive::peer::Config::options()), &[]);
}
