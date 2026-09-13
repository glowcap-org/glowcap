#![cfg(feature = "processes")]
//! Exercise the executable's loader, CLI, custody, banner and signal barrier.
use std::{
	io::{BufRead, BufReader},
	path::PathBuf,
	process::{Child, Command, ExitStatus, Stdio},
	sync::mpsc,
	time::{Duration, Instant},
};
#[path = "session_process/client.rs"]
mod client;
struct Process(Child);
impl Process {
	fn wait(&mut self) -> ExitStatus {
		let deadline = Instant::now() + Duration::from_secs(5);
		loop {
			if let Some(status) = self.0.try_wait().unwrap() {
				return status;
			}
			assert!(Instant::now() < deadline, "session process did not finish");
			std::thread::sleep(Duration::from_millis(5));
		}
	}
	fn signal(&mut self, name: &str) {
		assert!(
			Command::new("/bin/kill")
				.args([name, &self.0.id().to_string()])
				.status()
				.unwrap()
				.success()
		);
		assert!(self.wait().success(), "session signal shutdown failed");
	}
}
impl Drop for Process {
	fn drop(&mut self) {
		let _ = self.0.kill();
		let _ = self.0.wait();
	}
}
struct Temp(PathBuf);
impl Drop for Temp {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}
fn command() -> Command {
	let installed = std::env::var_os("GLOWCAP_ROOMS_SESSION_TEST_BIN");
	let mut command = Command::new(
		installed
			.clone()
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-session").into()),
	);
	for (key, _) in std::env::vars_os() {
		if key.to_string_lossy().starts_with("GLOWCAP_ROOMS_SESSION_") {
			command.env_remove(key);
		}
	}
	if installed.is_some() {
		command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
	}
	command
}
#[test]
fn session_peer_executable_custody_restart_and_signals() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-session-process-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let mut help = Process(command().arg("--help").stdout(Stdio::null()).spawn().unwrap());
	assert!(help.wait().success());
	let mut invalid = Process(command().arg("--port=bad").stderr(Stdio::null()).spawn().unwrap());
	assert!(!invalid.wait().success());
	for transport in ["tcp", "iroh"] {
		let state = temp.0.join(transport);
		let mut identity = None;
		let mut swiss = None;
		for signal in ["-TERM", "-INT"] {
			let mut cmd = command();
			cmd.arg(format!("--state={}", state.display()))
				.arg(format!("--transport={transport}"));
			if transport == "iroh" {
				cmd.arg("--reachability=direct");
			}
			let mut process = Process(cmd.stdout(Stdio::piped()).spawn().unwrap());
			let stdout = process.0.stdout.take().unwrap();
			let (sender, receiver) = mpsc::sync_channel(1);
			let reader = std::thread::spawn(move || {
				let mut line = String::new();
				BufReader::new(stdout).read_line(&mut line).unwrap();
				let _ = sender.send(line);
			});
			let line = receiver
				.recv_timeout(Duration::from_secs(8))
				.expect("session ready deadline");
			reader.join().unwrap();
			let link = line
				.trim()
				.strip_prefix("ROOMS-SESSION-LISTENING ")
				.expect("session authority banner");
			let parsed = glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0).unwrap();
			if let Some(previous) = &swiss {
				assert_eq!(&parsed.swissnum, previous);
			}
			swiss = Some(parsed.swissnum);
			client::exercise(link);
			let bytes = std::fs::read(state.join("session.json")).unwrap();
			if let Some(previous) = &identity {
				assert_eq!(&bytes, previous);
			}
			identity = Some(bytes);
			assert!(state.join("admin.sturdyref").exists());
			// The healthcheck is the same executable reading its own mirror:
			// it prints the one sturdyref while the peer is up.
			let ready = command()
				.arg(format!("--check-ready={}", state.join("admin.sturdyref").display()))
				.output()
				.unwrap();
			assert!(ready.status.success(), "a running peer checks ready");
			assert_eq!(String::from_utf8(ready.stdout).unwrap().trim(), link);
			let mut contender = Process(
				command()
					.arg(format!("--state={}", state.display()))
					.arg("--transport=tcp")
					.stderr(Stdio::null())
					.spawn()
					.unwrap(),
			);
			assert!(
				!contender.wait().success(),
				"a second process acquired live session custody"
			);
			process.signal(signal);
			assert!(!state.join("admin.sturdyref").exists());
			let stopped = command()
				.arg(format!("--check-ready={}", state.join("admin.sturdyref").display()))
				.stderr(Stdio::null())
				.output()
				.unwrap();
			assert!(!stopped.status.success(), "a stopped peer does not check ready");
		}
	}
}
