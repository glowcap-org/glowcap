//! Exercise the executable's loader, CLI, custody, banner and signal barrier.
use std::{
	io::{BufRead, BufReader},
	path::PathBuf,
	process::{Child, Command, ExitStatus, Stdio},
	sync::mpsc,
	time::{Duration, Instant},
};
struct Process(Child);
impl Process {
	fn wait(&mut self) -> ExitStatus {
		let deadline = Instant::now() + Duration::from_secs(5);
		loop {
			if let Some(status) = self.0.try_wait().unwrap() {
				return status;
			}
			assert!(Instant::now() < deadline, "archive process did not finish");
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
		assert!(self.wait().success(), "archive signal shutdown failed");
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
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}
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
	let temp = Temp(std::env::temp_dir().join(format!("rooms-archive-process-{}", std::process::id())));
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
				"a second process acquired live archive custody"
			);
			process.signal(signal);
		}
	}
}
