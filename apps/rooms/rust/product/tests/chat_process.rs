//! Exercise the installed interactive client with real stdin and directory peers.
#![cfg(test)]
use rooms_testing::child_process::Process;
use std::{
	io::{BufRead, BufReader, Write},
	process::{Command, Stdio},
	sync::mpsc::{self, Receiver},
	thread::JoinHandle,
	time::{Duration, Instant},
};

/// The shared child guard, plus the thread that reads its stdout lines.
struct Chat {
	// Declared before `reader`: the child dies first, which ends the reader.
	process: Process,
	lines: Receiver<String>,
	reader: Reader,
}
impl Chat {
	fn spawn(mut command: Command, name: &'static str) -> Self {
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
			process: Process::new(child, name).within(Duration::from_secs(8)),
			lines,
			reader: Reader(Some(reader)),
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
		writeln!(self.process.child.stdin.as_mut().unwrap(), "{text}").unwrap();
	}
	fn wait(&mut self) {
		let status = self.process.wait();
		assert!(status.success(), "process failed: {status}");
		self.reader.join();
	}
	fn signal(&mut self, signal: &str) {
		self.process.signal(signal);
		self.reader.join();
	}
}
/// The stdout reader, joined after the child that feeds it has been reaped.
struct Reader(Option<JoinHandle<()>>);
impl Reader {
	fn join(&mut self) {
		self.0.take().unwrap().join().unwrap();
	}
}
impl Drop for Reader {
	fn drop(&mut self) {
		if let Some(reader) = self.0.take() {
			// best-effort: the child is gone, so a reader that panicked has
			// nothing left to report, and a drop cannot propagate it.
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
fn chat(locator: &str, room: &str) -> Chat {
	let mut command = executable("GLOWCAP_ROOMS_CHAT_TEST_BIN", env!("CARGO_BIN_EXE_rooms-chat"));
	command.args([locator, room, "alice"]);
	let client = Chat::spawn(command, "client");
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
		let mut server = Chat::spawn(command, "server");
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
		// The next ordinary post must still use the old membership. status-allow: replacement state identity
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
		drop(first.process.child.stdin.take());
		first.wait();
		// Keep stdin open to prove signal handling wakes the terminal reader.
		occupied.signal("-TERM");
		let mut interrupted = chat(&locator, "general");
		interrupted.signal("-INT");
		server.signal("-TERM");
	}
}
