//! Exercise the executable's loader, CLI, custody, banner and signal barrier.
#![cfg(test)]
use std::{
	io::{BufRead, BufReader},
	path::PathBuf,
	process::{Child, Command, ExitStatus, Stdio},
	sync::mpsc,
	time::{Duration, Instant},
};
#[path = "session_process/client.rs"]
mod client;
#[path = "session_process/journey.rs"]
mod journey;
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
		assert_eq!(
			self.wait().success(),
			name != "-KILL",
			"unexpected session shutdown status"
		);
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
		let mut publication = None;
		let mut receipt_base = None;
		for signal in ["-TERM", "-KILL", "-INT"] {
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
				let mut reader = BufReader::new(stdout);
				reader.read_line(&mut line).unwrap();
				let mut management = String::new();
				reader.read_line(&mut management).unwrap();
				let _ = sender.send((line, management));
			});
			let (line, management) = receiver
				.recv_timeout(Duration::from_secs(8))
				.expect("session ready deadline");
			reader.join().unwrap();
			let link = line
				.trim()
				.strip_prefix("ROOMS-SESSION-LISTENING ")
				.expect("session authority banner");
			let parsed = glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0).unwrap();
			if let Some((designator, swiss)) = &publication {
				assert_eq!(&parsed.swissnum, swiss);
				if transport == "iroh" {
					assert_eq!(
						&parsed.locator.designator, designator,
						"restart replaced the session's iroh identity"
					);
				}
			}
			publication = Some((parsed.locator.designator, parsed.swissnum));
			let management_link = std::fs::read_to_string(state.join("control.sturdyref")).unwrap();
			assert_eq!(
				management.trim().strip_prefix("ROOMS-SESSION-MANAGEMENT "),
				Some(management_link.trim())
			);
			receipt_base = Some(client::exercise(link, management_link.trim(), receipt_base));
			let bytes = std::fs::read(state.join("rooms-bootstrap")).unwrap();
			if let Some(previous) = &identity {
				assert_eq!(&bytes, previous);
			}
			identity = Some(bytes);
			assert!(state.join("workspace.sturdyref").exists());
			// The healthcheck is the same executable reading its own mirror:
			// it prints the one sturdyref while the peer is up.
			let ready = command()
				.arg(format!("--check-ready={}", state.join("workspace.sturdyref").display()))
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
			let ready = command()
				.arg(format!("--check-ready={}", state.join("workspace.sturdyref").display()))
				.output()
				.unwrap();
			assert!(
				ready.status.success(),
				"a refused contender removed the running peer's readiness"
			);
			assert_eq!(String::from_utf8(ready.stdout).unwrap().trim(), link);
			assert_eq!(
				std::fs::read_to_string(state.join("control.sturdyref")).unwrap(),
				management_link
			);
			if signal == "-KILL" {
				// A killed QUIC peer cannot send a close packet. Crash recovery
				// checks retained custody; graceful signals also fence observers.
				process.signal(signal);
			} else {
				client::shutdown_with_live_observer(link, || process.signal(signal));
			}
			// A crash leaves ordinary filesystem mirrors behind; the next
			// exclusive owner clears them. Deployment readiness uses a tmpfs.
			if signal == "-KILL" {
				continue;
			}
			assert!(!state.join("workspace.sturdyref").exists());
			assert!(!state.join("control.sturdyref").exists());
			let stopped = command()
				.arg(format!("--check-ready={}", state.join("workspace.sturdyref").display()))
				.stderr(Stdio::null())
				.output()
				.unwrap();
			assert!(!stopped.status.success(), "a stopped peer does not check ready");
		}
	}
}
