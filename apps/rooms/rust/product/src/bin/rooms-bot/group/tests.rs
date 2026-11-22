use super::*;
use rooms_testing::scratch::Scratch;
use std::{
	os::unix::process::CommandExt,
	process::{Child, Command},
	time::{Duration, Instant},
};

/// A `sleep` leading its own process group.
fn leader() -> Child {
	Command::new("sleep").arg("30").process_group(0).spawn().unwrap()
}

/// Whether the child has ended within a few seconds. It is reaped here, so a
/// zombie never counts as alive.
fn ends(child: &mut Child) -> bool {
	let until = Instant::now() + Duration::from_secs(5);
	while Instant::now() < until {
		if child.try_wait().unwrap().is_some() {
			return true;
		}
		std::thread::sleep(Duration::from_millis(20));
	}
	false
}

fn plant(dir: &Path, body: &str) -> PathBuf {
	let path = dir.join("c1");
	std::fs::write(&path, body).unwrap();
	path
}

#[test]
fn a_dropped_group_is_ended_and_its_record_removed() {
	let dir = Scratch::create("bot-group-drop");
	let mut child = leader();
	let group = Group::record(&dir, "c1", child.id()).unwrap();
	assert!(dir.join("c1").exists());
	drop(group);
	assert!(ends(&mut child), "dropping the group left its leader running");
	assert!(!dir.join("c1").exists());
}

#[cfg(target_os = "linux")]
#[test]
fn a_confirmed_leader_left_by_a_killed_bot_is_ended() {
	let dir = Scratch::create("bot-group-reap");
	let mut child = leader();
	let group = Group::record(&dir, "c1", child.id()).unwrap();
	// A killed bot runs no destructor.
	std::mem::forget(group);
	assert_eq!(reap(&dir.join("c1")), Reaped::Ended(child.id()));
	assert!(ends(&mut child));
}

#[test]
fn a_leader_whose_identity_changed_is_left_alone() {
	let dir = Scratch::create("bot-group-reused");
	let mut child = leader();
	let record = plant(
		&dir,
		&format!(
			r#"{{"group":{},"identity":{{"boot":"another-boot","start":1}}}}"#,
			child.id()
		),
	);
	assert!(matches!(reap(&record), Reaped::Left(..)));
	let unconfirmed = plant(&dir, &format!(r#"{{"group":{},"identity":null}}"#, child.id()));
	assert!(matches!(reap(&unconfirmed), Reaped::Left(..)));
	assert!(
		child.try_wait().unwrap().is_none(),
		"an unconfirmed group was signalled"
	);
	child.kill().unwrap();
	child.wait().unwrap();
}

#[test]
fn a_record_naming_a_group_the_bot_never_records_is_discarded_unsignalled() {
	let dir = Scratch::create("bot-group-planted");
	let own = getpgrp().as_raw();
	for group in ["0".to_owned(), "1".to_owned(), own.to_string(), u32::MAX.to_string()] {
		let record = plant(&dir, &format!(r#"{{"group":{group},"identity":null}}"#));
		assert!(matches!(reap(&record), Reaped::Discarded(_)), "group {group}");
	}
	for garbage in ["", "12", "{", r#"{"group":"x"}"#] {
		assert!(
			matches!(reap(&plant(&dir, garbage)), Reaped::Discarded(_)),
			"{garbage:?}"
		);
	}
}

#[test]
fn a_record_whose_group_is_gone_is_stale_bookkeeping() {
	let dir = Scratch::create("bot-group-gone");
	let mut child = leader();
	let id = child.id();
	child.kill().unwrap();
	child.wait().unwrap();
	let record = plant(&dir, &format!(r#"{{"group":{id},"identity":null}}"#));
	assert_eq!(reap(&record), Reaped::Gone);
}
