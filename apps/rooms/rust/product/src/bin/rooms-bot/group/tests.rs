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

#[tokio::test]
async fn a_refused_group_is_gone_only_after_its_leader_exits_and_no_member_remains() {
	for survivor in [false, true] {
		let dir = Scratch::create("bot-group-refused");
		let mut changes = child_signals().unwrap();
		let mut command = tokio::process::Command::new("sh");
		command
			.args(["-c", "read line; exit 23"])
			.stdin(std::process::Stdio::piped());
		command.as_std_mut().process_group(0);
		let mut child = command.spawn().unwrap();
		let id = child.id().unwrap();
		let mut group = Group::record(&dir, "c1", id).unwrap();
		assert!(!group.gone_after_reap(&mut child).unwrap(), "the leader is running");
		let mut member = survivor.then(|| {
			Command::new("sleep")
				.arg("10")
				.process_group(i32::try_from(id).unwrap())
				.spawn()
				.unwrap()
		});
		drop(child.stdin.take());
		tokio::time::timeout(Duration::from_secs(5), group.exited(&mut changes))
			.await
			.unwrap()
			.unwrap();
		assert_eq!(group.gone_after_reap(&mut child).unwrap(), !survivor);
		assert_eq!(child.wait().await.unwrap().code(), Some(23));
		assert!(group.target().is_err(), "the reaped leader no longer grants authority");
		if let Some(member) = &mut member {
			drop(group);
			assert!(dir.join("c1").exists());
			assert!(
				member.try_wait().unwrap().is_none(),
				"the probe must leave the member running"
			);
			member.kill().unwrap();
			member.wait().unwrap();
		} else {
			group.end().unwrap();
			assert!(!dir.join("c1").exists());
		}
	}
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

/// A signal the system refused leaves the group alone and the log says which
/// refusal it was, as the cause of a survivor is not always a permission.
#[test]
fn a_group_whose_signal_was_refused_is_left_with_the_refusal() {
	let refused = Error::Io {
		context: "ending the harness process group",
		source: Errno::EPERM.into(),
	};
	let Reaped::Left(group, why) = signalled(7, Err(refused)) else {
		panic!("a refused signal ended the group");
	};
	assert_eq!(group, 7);
	assert!(
		why.contains("could not be signalled") && why.contains("not permitted"),
		"{why}"
	);
	assert_eq!(signalled(7, Ok(())), Reaped::Ended(7));
}

/// Only a definite "no such process, or another start" reads as gone. A
/// verb in another namespace is never judged.
#[test]
fn a_verb_is_gone_only_when_its_process_definitely_is() {
	let mut child = leader();
	let verb = Verb::of(child.id()).unwrap();
	assert_eq!(verb.presence(), Presence::Alive);
	assert_eq!(Verb::this_process().unwrap().presence(), Presence::Alive);
	let reused = Verb {
		identity: Identity {
			start: verb.identity.start + 1,
			..verb.identity.clone()
		},
		..verb.clone()
	};
	assert_eq!(reused.presence(), Presence::Gone, "another start is another process");
	let foreign = Verb {
		namespace: "pid:[0]".into(),
		..verb.clone()
	};
	assert!(
		matches!(foreign.presence(), Presence::Unknown(_)),
		"another namespace is not judged"
	);
	child.kill().unwrap();
	child.wait().unwrap();
	assert_eq!(verb.presence(), Presence::Gone, "a reaped process is gone");
}
