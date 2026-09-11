#![cfg(feature = "service")]
//! Exercise the installed interactive client with real stdin and directory peers.
use std::{
	io::{BufRead, BufReader, Write},
	process::{Child, Command, Stdio},
	sync::mpsc::{self, Receiver},
	thread::JoinHandle,
	time::{Duration, Instant},
};

struct Process {
	child: Child,
	lines: Receiver<String>,
	reader: Option<JoinHandle<()>>,
}
impl Process {
	fn spawn(mut command: Command) -> Self {
		let mut child = command
			.stdin(Stdio::piped())
			.stdout(Stdio::piped())
			.stderr(Stdio::inherit())
			.spawn()
			.unwrap();
		let stdout = child.stdout.take().unwrap();
		let (send, lines) = mpsc::channel();
		let reader = std::thread::spawn(move || {
			for line in BufReader::new(stdout).lines() {
				if send.send(line.unwrap()).is_err() {
					break;
				}
			}
		});
		Self {
			child,
			lines,
			reader: Some(reader),
		}
	}
	fn until(&self, needle: &str) -> String {
		let deadline = Instant::now() + Duration::from_secs(12);
		let mut seen = String::new();
		loop {
			let line = self
				.lines
				.recv_timeout(deadline.saturating_duration_since(Instant::now()))
				.unwrap_or_else(|error| panic!("waiting for {needle:?}: {error}; output: {seen}"));
			seen.push_str(&line);
			seen.push('\n');
			if line.contains(needle) {
				return line;
			}
		}
	}
	fn send(&mut self, text: &str) {
		writeln!(self.child.stdin.as_mut().unwrap(), "{text}").unwrap();
	}
	fn wait(&mut self) {
		let deadline = Instant::now() + Duration::from_secs(8);
		loop {
			if let Some(status) = self.child.try_wait().unwrap() {
				assert!(status.success(), "process failed: {status}");
				self.reader.take().unwrap().join().unwrap();
				return;
			}
			assert!(Instant::now() < deadline, "client did not observe shutdown");
			std::thread::sleep(Duration::from_millis(10));
		}
	}
	fn signal(&mut self, signal: &str) {
		assert!(Command::new("/bin/kill")
			.args([signal, &self.child.id().to_string()])
			.status()
			.unwrap()
			.success());
		self.wait();
	}
}
impl Drop for Process {
	fn drop(&mut self) {
		let _ = self.child.kill();
		let _ = self.child.wait();
		if let Some(reader) = self.reader.take() {
			let _ = reader.join();
		}
	}
}
fn executable(variable: &str, fallback: &str) -> Command {
	let mut command = Command::new(std::env::var_os(variable).unwrap_or_else(|| fallback.into()));
	for (key, _) in std::env::vars_os() {
		if key.to_string_lossy().starts_with("GLOWCAP_ROOMS_") {
			command.env_remove(key);
		}
	}
	command.env_remove("LD_LIBRARY_PATH");
	command
}
fn chat(locator: &str, room: &str) -> Process {
	let mut command = executable("GLOWCAP_ROOMS_CHAT_TEST_BIN", env!("CARGO_BIN_EXE_rooms-chat"));
	command.args([locator, room, "alice"]);
	let client = Process::spawn(command);
	client.until("(type a line");
	client
}
#[test]
fn installed_chat_switches_preserves_refused_membership_and_observes_shutdown() {
	for transport in ["tcp", "iroh"] {
		let mut command = executable("GLOWCAP_ROOMS_SERVER_TEST_BIN", env!("CARGO_BIN_EXE_rooms-server"));
		command.args([&format!("--transport={transport}"), "--port=0"]);
		if transport == "iroh" {
			command.arg("--reachability=direct");
		}
		let mut server = Process::spawn(command);
		let banner = server.until("ROOMS-SERVER-LISTENING ");
		let announced = banner.strip_prefix("ROOMS-SERVER-LISTENING ").unwrap();
		let locator = if transport == "tcp" {
			format!("127.0.0.1:{announced}")
		} else {
			announced.into()
		};
		let mut first = chat(&locator, "general");
		let mut occupied = chat(&locator, "occupied");
		first.send("/help");
		first.until("/list");
		first.send("/list");
		first.until("occupied (1)");
		first.send("/enter occupied");
		// The next ordinary post must still use the old membership.
		first.send("still-in-general");
		first.until("alice: still-in-general");
		first.send("/open second");
		first.until("(in \"second\"");
		first.send("second-message");
		first.until("alice: second-message");
		first.send("/leave");
		first.until("* left");
		first.send("/enter general");
		first.until("(in \"general\"");
		first.send(&"x".repeat(8193));
		first.until("typed line exceeds");
		first.send("after-oversize");
		first.until("alice: after-oversize");
		drop(first.child.stdin.take());
		first.wait();
		// Keep stdin open to prove signal handling wakes the terminal reader.
		occupied.signal("-TERM");
		let mut interrupted = chat(&locator, "general");
		interrupted.signal("-INT");
		server.signal("-TERM");
	}
}
