use super::*;
use crate::bot::harness::Turn;
use nix::{errno::Errno, sys::signal::kill, unistd::Pid};
use rooms_testing::scratch::Scratch;
use std::time::Instant as StdInstant;

/// Runs a shell script. Lines `F:<text>` are final answers, `T:<text>` text.
struct Script(&'static str);

impl Harness for Script {
	fn name(&self) -> &'static str {
		"script"
	}
	fn program(&self) -> std::ffi::OsString {
		"/bin/sh".into()
	}
	fn invocation(&self, _: &Turn<'_>) -> Invocation {
		Invocation {
			program: "/bin/sh".into(),
			args: vec!["-c".into(), self.0.into()],
			env: Vec::new(),
			stdin: None,
			prepare: Vec::new(),
			resume: None,
		}
	}
	fn read(&self, line: &str) -> Vec<Signal> {
		match line.split_once(':') {
			Some(("S", id)) => vec![Signal::Session(id.into())],
			Some(("F", text)) => vec![Signal::Final(text.into())],
			Some(("T", text)) => vec![Signal::Text(text.into())],
			Some(("E", text)) => vec![Signal::Failure(FailureKind::Crash, text.into())],
			_ => Vec::new(),
		}
	}
	fn exit(&self, code: Option<i32>, stderr_tail: &str) -> Option<(FailureKind, String)> {
		(code != Some(0)).then(|| (FailureKind::Crash, stderr_tail.trim().to_owned()))
	}
}

/// A working directory and a group directory beside it, as the bot lays them out.
struct Dirs {
	work: Scratch,
	groups: Scratch,
}

impl Dirs {
	fn new(label: &str) -> Self {
		Self {
			work: Scratch::create(label),
			groups: Scratch::create(&format!("{label}-groups")),
		}
	}
	fn place(&self) -> Place<'_> {
		Place {
			workdir: &self.work,
			groups: &self.groups,
			record: "c1",
		}
	}
}

async fn run_with(harness: &dyn Harness, invocation: Invocation, dirs: &Dirs, deadline: Duration) -> Ran {
	let (_keep, mut shutdown) = watch::channel(false);
	run(harness, invocation, &dirs.place(), deadline, &mut shutdown)
		.await
		.unwrap()
}

async fn run_script(script: &'static str, deadline: Duration) -> (Ran, Dirs) {
	let dirs = Dirs::new("bot-runner");
	let harness = Script(script);
	let invocation = harness.invocation(&dummy_turn(&dirs.work));
	let ran = run_with(&harness, invocation, &dirs, deadline).await;
	(ran, dirs)
}

fn dummy_turn(dir: &Path) -> Turn<'_> {
	Turn {
		prompt: "",
		system: "",
		session: None,
		workdir: dir,
		home: dir,
		state: dir,
		model: None,
		permission: crate::bot::harness::Permission::Safe,
	}
}

fn read_pid(path: &Path) -> i32 {
	std::fs::read_to_string(path).unwrap().trim().parse().unwrap()
}

/// Wait until a harness script has written its child's pid to `path`.
async fn pid_written(path: &Path) {
	let until = StdInstant::now() + Duration::from_secs(20);
	while StdInstant::now() < until {
		if std::fs::read_to_string(path).is_ok_and(|text| text.trim().parse::<i32>().is_ok()) {
			return;
		}
		tokio::time::sleep(Duration::from_millis(20)).await;
	}
	panic!("the script never wrote {}", path.display());
}

fn gone(pid: i32) -> bool {
	let until = StdInstant::now() + Duration::from_secs(5);
	while StdInstant::now() < until {
		if kill(Pid::from_raw(pid), None) == Err(Errno::ESRCH) {
			return true;
		}
		std::thread::sleep(Duration::from_millis(20));
	}
	false
}

/// A fresh bot inherits SIGCHLD ignored and blocked. Its own subscription must make
/// children waitable before spawn, even when Tokio can use pidfds itself.
#[tokio::test]
async fn observing_a_harness_exit_leaves_its_status_for_the_reaper() {
	const ISOLATED: &str = "GLOWCAP_TEST_IGNORED_SIGCHLD";
	let Some(observed) = std::env::var_os(ISOLATED) else {
		let scratch = Scratch::create("child-observer-proof");
		let observed = scratch.join("observed");
		let test = std::thread::current().name().unwrap().to_owned();
		let mut isolated = std::process::Command::new("python3");
		isolated
			.args([
				"-c",
				r#"import os, signal, sys
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGCHLD})
os.execv(sys.argv[1], sys.argv[1:])"#,
			])
			.arg(std::env::current_exe().unwrap())
			.args(["--exact", &test])
			.env(ISOLATED, &observed);
		let mut process = rooms_testing::child_process::Process::new(isolated.spawn().unwrap(), "ignored SIGCHLD")
			.within(Duration::from_secs(15));
		assert!(process.wait().success());
		assert!(observed.exists(), "the isolated process must run the ownership check");
		return;
	};

	#[cfg(target_os = "linux")]
	{
		let mut probe = std::process::Command::new("true").spawn().unwrap();
		assert_eq!(
			probe.wait().unwrap_err().raw_os_error(),
			Some(Errno::ECHILD as i32),
			"the inherited signal handler should auto-reap before the runner starts"
		);
	}

	let dirs = Dirs::new("bot-ignored-sigchld");
	let store = crate::bot::store::Store::open(&dirs.groups).unwrap();
	let groups = store.groups().unwrap();
	let place = Place {
		groups: &groups,
		..dirs.place()
	};
	let harness = Script("while [ ! -f release ]; do sleep 0.1; done; exit 23");
	let mut invocation = harness.invocation(&dummy_turn(&dirs.work));
	let (_keep, mut shutdown) = watch::channel(false);
	let Launched {
		mut watched,
		mut child_signal,
		..
	} = launch(&mut invocation, &place, &shutdown).unwrap().unwrap();
	let group = &mut watched.group;
	// A sibling's exit wakes our subscription while our own harness is still running.
	assert!(std::process::Command::new("true").status().unwrap().success());
	assert!(
		timeout(Duration::from_millis(50), group.exited(&mut child_signal))
			.await
			.is_err()
	);
	std::fs::write(dirs.work.join("release"), "").unwrap();
	timeout(Duration::from_secs(5), group.exited(&mut child_signal))
		.await
		.unwrap()
		.unwrap();
	timeout(Duration::from_secs(1), group.exited(&mut child_signal))
		.await
		.unwrap()
		.unwrap();
	group.kill().unwrap();
	assert_eq!(watched.child.wait().await.unwrap().code(), Some(23));
	assert_eq!(
		group.exited(&mut child_signal).await.unwrap_err().raw_os_error(),
		Some(Errno::ECHILD as i32)
	);
	assert!(group.kill().is_err());
	drop(watched);
	let record = groups.join(place.record);
	let retained = std::fs::read(&record).unwrap();
	let next = Script("echo F:recovered");
	let mut invocation = next.invocation(&dummy_turn(&dirs.work));
	let Err(refused) = launch(&mut invocation, &place, &shutdown) else {
		panic!("another harness started over an unconfirmed group");
	};
	assert!(refused.to_string().contains("restart the bot"), "{refused}");
	assert_eq!(std::fs::read(&record).unwrap(), retained);
	group::reap_all(&store).unwrap();
	let ran = run(&next, invocation, &place, Duration::from_secs(5), &mut shutdown)
		.await
		.unwrap();
	assert_eq!(ran.finish, Finish::Answered("recovered".into()));
	assert!(!record.exists());
	std::fs::write(observed, "").unwrap();
}

#[tokio::test]
async fn a_final_answer_wins_over_a_failing_exit() {
	let (ran, _dir) = run_script("echo S:abc; echo F:done; exit 1", Duration::from_secs(10)).await;
	assert_eq!(ran.finish, Finish::Answered("done".into()));
	assert_eq!(ran.session.as_deref(), Some("abc"));
}

#[tokio::test]
async fn a_failing_exit_without_an_answer_carries_the_stderr_tail() {
	let (ran, _dir) = run_script("echo boom >&2; exit 4", Duration::from_secs(10)).await;
	assert_eq!(ran.finish, Finish::Failed(FailureKind::Crash, "boom".into()));
}

#[tokio::test]
async fn a_clean_exit_with_only_text_answers_with_the_text() {
	let (ran, _dir) = run_script("echo T:partial", Duration::from_secs(10)).await;
	assert_eq!(ran.finish, Finish::Answered("partial".into()));
	let (ran, _dir) = run_script("true", Duration::from_secs(10)).await;
	assert!(matches!(ran.finish, Finish::Failed(FailureKind::Crash, _)));
}

#[tokio::test]
async fn the_deadline_ends_the_whole_group() {
	let script = "sleep 300 & echo $! > child.pid; echo S:x; wait";
	// The deadline is long enough for a loaded host's shell to write its pid.
	let (ran, dirs) = run_script(script, Duration::from_secs(5)).await;
	assert_eq!(ran.finish, Finish::TimedOut);
	assert!(
		gone(read_pid(&dirs.work.join("child.pid"))),
		"the harness's child outlived the deadline"
	);
	assert!(!dirs.groups.join("c1").exists(), "the group record outlived the run");
}

#[tokio::test]
async fn an_answer_is_taken_when_a_process_it_left_behind_holds_the_output_open() {
	let script = "sleep 300 & echo $! > child.pid; echo S:x; echo F:done";
	let started = StdInstant::now();
	let (ran, dirs) = run_script(script, Duration::from_secs(60)).await;
	assert_eq!(ran.finish, Finish::Answered("done".into()));
	assert_eq!(ran.session.as_deref(), Some("x"));
	assert!(
		started.elapsed() < Duration::from_secs(30),
		"the run waited for the deadline instead of the grace"
	);
	assert!(
		gone(read_pid(&dirs.work.join("child.pid"))),
		"the process holding the output outlived the run"
	);
}

/// A harness that exits without an answer while a process it left behind
/// holds its output open finishes as the crash it is, with its exit code's
/// stderr tail, and not at the deadline.
#[tokio::test]
async fn an_exit_without_an_answer_is_a_crash_while_a_process_it_left_behind_holds_the_output_open() {
	let script = "echo boom >&2; sleep 300 & echo $! > child.pid; exit 4";
	let started = StdInstant::now();
	let (ran, dirs) = run_script(script, Duration::from_secs(60)).await;
	assert_eq!(ran.finish, Finish::Failed(FailureKind::Crash, "boom".into()));
	assert!(
		started.elapsed() < Duration::from_secs(30),
		"the run waited for the deadline instead of the leader's exit"
	);
	assert!(
		gone(read_pid(&dirs.work.join("child.pid"))),
		"the process holding the output outlived the run"
	);
}

#[tokio::test]
async fn a_deadline_reached_with_an_answer_held_returns_the_answer() {
	let (ran, _dirs) = run_script("echo F:done; sleep 300", Duration::from_secs(5)).await;
	assert_eq!(ran.finish, Finish::Answered("done".into()));
}

#[tokio::test]
async fn the_group_is_recorded_outside_the_working_directory_while_it_runs() {
	let dirs = Dirs::new("bot-runner-record");
	let harness = Script("touch started; while [ ! -e release ]; do sleep 0.02; done; echo F:ok");
	let invocation = harness.invocation(&dummy_turn(&dirs.work));
	let check = async {
		let until = StdInstant::now() + Duration::from_secs(10);
		while !dirs.work.join("started").exists() && StdInstant::now() < until {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
		let record = std::fs::read_to_string(dirs.groups.join("c1")).unwrap_or_default();
		let listing: Vec<_> = std::fs::read_dir(&*dirs.work)
			.unwrap()
			.map(|entry| entry.unwrap().file_name())
			.collect();
		std::fs::write(dirs.work.join("release"), "").unwrap();
		(record, listing)
	};
	let (ran, (record, listing)) = tokio::join!(run_with(&harness, invocation, &dirs, Duration::from_secs(20)), check);
	assert_eq!(ran.finish, Finish::Answered("ok".into()));
	assert!(
		record.contains(r#""group":"#),
		"no record while the harness ran: {record:?}"
	);
	assert_eq!(
		listing,
		["started"],
		"the working directory holds more than the harness made"
	);
	assert!(!dirs.groups.join("c1").exists());
}

#[tokio::test]
async fn a_dropped_run_ends_its_group() {
	let dirs = Dirs::new("bot-runner-dropped");
	let harness = Script("sleep 300 & echo $! > child.pid; wait");
	let invocation = harness.invocation(&dummy_turn(&dirs.work));
	let (_keep, mut shutdown) = watch::channel(false);
	let place = dirs.place();
	let running = run(&harness, invocation, &place, Duration::from_secs(60), &mut shutdown);
	// Abandon the run once its child is running, not after a guessed delay.
	let started = async {
		pid_written(&dirs.work.join("child.pid")).await;
	};
	let abandoned = tokio::select! {
		_ = running => false,
		() = started => true,
	};
	assert!(abandoned, "the run ended on its own");
	assert!(
		gone(read_pid(&dirs.work.join("child.pid"))),
		"a dropped run left its group running"
	);
	assert!(!dirs.groups.join("c1").exists());
}

#[tokio::test]
async fn shutdown_cancels_and_ends_the_group() {
	let dirs = Dirs::new("bot-runner-shutdown");
	let (stop, mut shutdown) = watch::channel(false);
	let harness = Script("sleep 300 & echo $! > child.pid; wait");
	let invocation = harness.invocation(&dummy_turn(&dirs.work));
	let child = dirs.work.join("child.pid");
	let ending = tokio::spawn(async move {
		pid_written(&child).await;
		stop.send_replace(true);
		stop
	});
	let ran = run(
		&harness,
		invocation,
		&dirs.place(),
		Duration::from_secs(30),
		&mut shutdown,
	)
	.await
	.unwrap();
	let _stop = ending.await.unwrap();
	assert_eq!(ran.finish, Finish::Cancelled);
	assert!(gone(read_pid(&dirs.work.join("child.pid"))));
}

#[tokio::test]
async fn an_oversized_line_is_skipped_not_buffered() {
	// The oversized line is itself a final answer. Buffered, it would win.
	let script = "echo F:small; printf F:; head -c 5000000 /dev/zero | tr '\\0' x; echo";
	let (ran, _dir) = run_script(script, Duration::from_secs(20)).await;
	assert_eq!(ran.finish, Finish::Answered("small".into()));
	assert!(ran.notes.iter().any(|note| note.contains("skipped")), "{:?}", ran.notes);
}

#[tokio::test]
async fn answer_text_and_session_ids_are_bounded_by_the_runner() {
	struct Loud;
	impl Harness for Loud {
		fn name(&self) -> &'static str {
			"loud"
		}
		fn program(&self) -> std::ffi::OsString {
			"/bin/sh".into()
		}
		fn invocation(&self, _: &Turn<'_>) -> Invocation {
			Invocation {
				program: "/bin/sh".into(),
				args: vec![
					"-c".into(),
					"i=0; while [ $i -lt 400 ]; do echo T; i=$((i+1)); done; echo S".into(),
				],
				env: Vec::new(),
				stdin: None,
				prepare: Vec::new(),
				resume: None,
			}
		}
		fn read(&self, line: &str) -> Vec<Signal> {
			match line {
				"T" => vec![Signal::Text("é".repeat(1000))],
				"S" => vec![Signal::Session("-x".repeat(100))],
				_ => Vec::new(),
			}
		}
		fn text_is_delta(&self) -> bool {
			true
		}
		fn exit(&self, _: Option<i32>, _: &str) -> Option<(FailureKind, String)> {
			None
		}
	}
	let dirs = Dirs::new("bot-runner-bounds");
	let invocation = Loud.invocation(&dummy_turn(&dirs.work));
	let ran = run_with(&Loud, invocation, &dirs, Duration::from_secs(20)).await;
	let Finish::Answered(text) = &ran.finish else {
		panic!("{:?}", ran.finish);
	};
	assert!(text.len() <= MAX_ANSWER_BYTES && text.len() > MAX_ANSWER_BYTES - 4);
	assert_eq!(ran.session, None, "an implausible session id was kept");
	assert!(plausible_session("019a4b2c-77d0-7c52-a0d3-3f1bb0e1c9a7"));
	assert!(!plausible_session(&"a".repeat(MAX_SESSION_ID_BYTES + 1)));
	assert!(!plausible_session("a b") && !plausible_session("") && !plausible_session("--flag"));
}

#[tokio::test]
async fn a_program_that_cannot_start_is_a_crash_not_an_error() {
	struct Missing;
	impl Harness for Missing {
		fn name(&self) -> &'static str {
			"missing"
		}
		fn program(&self) -> std::ffi::OsString {
			"/nonexistent/harness".into()
		}
		fn invocation(&self, _: &Turn<'_>) -> Invocation {
			Invocation {
				program: "/nonexistent/harness".into(),
				args: Vec::new(),
				env: Vec::new(),
				stdin: None,
				prepare: Vec::new(),
				resume: None,
			}
		}
		fn read(&self, _: &str) -> Vec<Signal> {
			Vec::new()
		}
		fn exit(&self, _: Option<i32>, _: &str) -> Option<(FailureKind, String)> {
			None
		}
	}
	let dirs = Dirs::new("bot-runner-missing");
	let invocation = Missing.invocation(&dummy_turn(&dirs.work));
	let ran = run_with(&Missing, invocation, &dirs, Duration::from_secs(5)).await;
	assert_eq!(ran.heard, Heard::NeverRan);
	assert!(matches!(ran.finish, Finish::Failed(FailureKind::Crash, detail) if detail.contains(COULD_NOT_START)));
}

async fn run_resuming(script: &'static str, asked: &str) -> Ran {
	let dirs = Dirs::new("bot-runner-resume");
	let harness = Script(script);
	let mut invocation = harness.invocation(&dummy_turn(&dirs.work));
	invocation.resume = Some(asked.into());
	run_with(&harness, invocation, &dirs, Duration::from_secs(20)).await
}

#[tokio::test]
async fn a_harness_that_continues_another_session_fails_the_turn() {
	let ran = run_resuming("echo S:new; echo F:answer", "old").await;
	assert!(matches!(&ran.finish, Finish::LostSession(text) if text.contains("old") && text.contains("new")));
	assert_eq!(ran.session.as_deref(), Some("new"));
	assert_eq!(
		run_resuming("echo S:old; echo F:answer", "old").await.finish,
		Finish::Answered("answer".into())
	);
}

#[tokio::test]
async fn a_failed_resume_is_told_from_a_run_the_agent_began() {
	let heard = |ran: &Ran| ran.heard;
	let unconfirmed = run_resuming("echo E:no conversation; exit 1", "old").await;
	assert!(matches!(unconfirmed.finish, Finish::Failed(FailureKind::Crash, _)));
	assert_eq!(heard(&unconfirmed), Heard::Silent);
	let killed = run_resuming("echo S:old; kill -9 $$", "old").await;
	assert!(matches!(killed.finish, Finish::Failed(FailureKind::Crash, _)));
	assert_eq!(heard(&killed), Heard::Engaged);
	let worked = run_resuming("echo T:partial; exit 3", "old").await;
	assert_eq!(heard(&worked), Heard::Engaged);
}

#[test]
fn preparation_creates_directories_and_replaces_a_stale_link() {
	let dir = Scratch::create("bot-runner-prepare");
	let (made, target, other, at) = (
		dir.join("a/b"),
		dir.join("auth"),
		dir.join("other"),
		dir.join("a/b/link"),
	);
	std::fs::write(&target, "x").unwrap();
	std::fs::write(&other, "y").unwrap();
	let link = |target: &Path| Prepare::Link {
		target: target.to_owned(),
		at: at.clone(),
	};
	prepare(&[Prepare::Dir(made), link(&other)]).unwrap();
	prepare(&[link(&target)]).unwrap();
	prepare(&[link(&target)]).unwrap();
	assert_eq!(std::fs::read_link(&at).unwrap(), target);
	assert!(prepare(&[link(&dir.join("absent"))]).is_err());
}
