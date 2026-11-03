//! Exercise the executable's loader, CLI, custody, banner and signal barrier.
#![cfg(test)]
use rooms_testing::{child_process::Process, scratch::Scratch};
use std::{
	io::{BufRead, BufReader},
	process::{Command, Stdio},
	sync::mpsc,
	time::Duration,
};
fn command() -> Command {
	let installed = std::env::var_os("GLOWCAP_ROOMS_ARCHIVE_TEST_BIN");
	let mut command = Command::new(
		installed
			.clone()
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-archive").into()),
	);
	for (key, _) in std::env::vars_os() {
		if key.to_string_lossy().starts_with("GLOWCAP_ARCHIVE_") {
			command.env_remove(key);
		}
	}
	if installed.is_some() {
		// The installed executable must locate its companion without build env.
		command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
	}
	command
}
#[test]
fn archive_peer_executable_custody_restart_and_signals() {
	let temp = Scratch::create("archive-process");
	let mut help = Process::new(
		command().arg("--help").stdout(Stdio::null()).spawn().unwrap(),
		"archive",
	);
	assert!(help.wait().success());
	let mut invalid = Process::new(
		command().arg("--port=bad").stderr(Stdio::null()).spawn().unwrap(),
		"archive",
	);
	assert!(!invalid.wait().success());
	for transport in ["tcp", "iroh"] {
		let state = temp.join(transport);
		let mut identity = None;
		let mut swiss = None;
		for signal in ["-TERM", "-INT"] {
			let mut cmd = command();
			cmd.arg(format!("--state={}", state.display()))
				.arg(format!("--transport={transport}"));
			if transport == "iroh" {
				cmd.arg("--reachability=direct");
			}
			let mut process = Process::new(cmd.stdout(Stdio::piped()).spawn().unwrap(), "archive");
			let stdout = process.child.stdout.take().unwrap();
			let (sender, receiver) = mpsc::sync_channel(1);
			let reader = std::thread::spawn(move || {
				let mut line = String::new();
				BufReader::new(stdout).read_line(&mut line).unwrap();
				let _ = sender.send(line);
			});
			let line = receiver
				.recv_timeout(Duration::from_secs(5))
				.expect("archive ready deadline");
			reader.join().unwrap();
			let link = line
				.trim()
				.strip_prefix("ROOMS-ARCHIVE-LISTENING ")
				.expect("archive authority banner");
			let parsed = glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0).unwrap();
			if let Some(previous) = &swiss {
				assert_eq!(&parsed.swissnum, previous);
			}
			swiss = Some(parsed.swissnum);
			let bytes = std::fs::read(state.join("peer.json")).unwrap();
			if let Some(previous) = &identity {
				assert_eq!(&bytes, previous);
			}
			identity = Some(bytes);
			let mut contender = Process::new(
				command()
					.arg(format!("--state={}", state.display()))
					.arg("--transport=tcp")
					.stderr(Stdio::null())
					.spawn()
					.unwrap(),
				"archive",
			);
			assert!(
				!contender.wait().success(),
				"a second process acquired live archive custody"
			);
			process.signal(signal);
		}
	}
}
