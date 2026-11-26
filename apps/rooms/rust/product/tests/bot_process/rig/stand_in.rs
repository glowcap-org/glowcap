//! What a test does to the directory that stands in for the session, and
//! what it reads back from it: events in, injected faults, and the lines,
//! calls, and receipts the bot left.
use super::{Rig, eventually, texts};
use serde_json::{Value, json};
use std::io::Write;

impl Rig {
	/// Append one event row, as the session would deliver it.
	pub fn push(&self, row: Value) {
		let mut file = std::fs::OpenOptions::new()
			.create(true)
			.append(true)
			.open(self.rooms.join("inbox.jsonl"))
			.unwrap();
		writeln!(file, "{row}").unwrap();
	}

	/// A direct line from the other person, which names no sender.
	pub fn direct(&self, at: u64, conversation: &str, text: &str) {
		self.push(json!({"at": at, "conversation": conversation, "kind": "direct", "text": text}));
	}

	pub fn room(&self, at: u64, conversation: &str, text: &str, mentions_bot: bool) {
		self.push(
			json!({"at": at, "conversation": conversation, "kind": "room", "sender": "ann",
			"text": text, "mentions": {"member": mentions_bot}}),
		);
	}

	/// Every line the bot has sent, in order.
	pub fn sent(&self) -> Vec<Value> {
		let Ok(text) = std::fs::read_to_string(self.rooms.join("outbox.jsonl")) else {
			return Vec::new();
		};
		text.lines().map(|line| serde_json::from_str(line).unwrap()).collect()
	}

	/// The text of every line sent so far.
	pub fn texts(&self) -> Vec<String> {
		texts(&self.sent())
	}

	pub fn wait_for_replies(&self, count: usize) -> Vec<Value> {
		eventually(&format!("{count} sent line(s)"), || {
			let sent = self.sent();
			(sent.len() >= count).then_some(sent)
		})
	}

	/// Wait until the durable cursor reaches event `at` and no turn is open
	/// or waiting. The stand-in writes the cursor after event `at` as `e`
	/// and `at` in hexadecimal.
	pub fn wait_for_cursor(&self, at: u64) {
		eventually(&format!("cursor {at}"), || {
			let status = self.status();
			let cursor = status["status"]["cursor"].as_str()?;
			let reached = cursor
				.strip_prefix('e')
				.and_then(|hex| u64::from_str_radix(hex, 16).ok());
			let idle = status["status"]["open_turns"] == 0 && status["status"]["queued"] == 0;
			(reached >= Some(at) && idle).then_some(())
		});
	}

	/// Every send, observe, keep, and release call the bot made, in order.
	pub fn calls(&self) -> Vec<Value> {
		let Ok(text) = std::fs::read_to_string(self.rooms.join("calls.jsonl")) else {
			return Vec::new();
		};
		text.lines().map(|line| serde_json::from_str(line).unwrap()).collect()
	}

	/// The operations of the calls named `call`, in order.
	pub fn operations(&self, call: &str) -> Vec<String> {
		self.calls()
			.iter()
			.filter(|row| row["call"] == call)
			.map(|row| row["operation"].as_str().unwrap().to_owned())
			.collect()
	}

	/// The `(call, operation, base)` of every send, observe, and keep call.
	pub fn call_log(&self) -> Vec<(String, String, u64)> {
		self.calls()
			.iter()
			.map(|row| {
				(
					row["call"].as_str().unwrap().to_owned(),
					row["operation"].as_str().unwrap().to_owned(),
					row["base"].as_u64().unwrap(),
				)
			})
			.collect()
	}

	/// The receipts the stand-in holds.
	pub fn receipts(&self) -> Vec<Value> {
		match std::fs::read(self.rooms.join("receipts.json")) {
			Ok(bytes) => serde_json::from_slice(&bytes).unwrap(),
			Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
			Err(error) => panic!("reading the stand-in's receipts: {error}"),
		}
	}

	/// `count` commands from someone else in the session, each holding a
	/// settled receipt as any session command does. The stand-in makes them
	/// through its own window, so each evicts and is refused as the session's
	/// reservation does, and the run fails where a command would be refused.
	pub fn crowd(&self, count: usize) {
		let output = std::process::Command::new(env!("CARGO_BIN_EXE_rooms-bot"))
			.args(["crowd"])
			.arg(&self.rooms)
			.arg(count.to_string())
			.env_remove("GLOWCAP_ROOMS_BOT_FAULT")
			.output()
			.unwrap();
		assert!(
			output.status.success(),
			"someone else's command was refused for a full set of receipts: {}",
			String::from_utf8_lossy(&output.stdout)
		);
	}

	/// Make the stand-in's activity unable to say whether any line posted.
	pub fn lose_echoes(&self) {
		std::fs::write(self.rooms.join("echo-fault"), "").unwrap();
	}

	/// Make every echo read as one across a session restart, where only the
	/// receipt can tell.
	pub fn restart_echoes(&self) {
		std::fs::write(self.rooms.join("echo-fault"), "restarted").unwrap();
	}

	/// Outcomes the stand-in injects into the next send, observe, or keep calls.
	pub fn send_faults(&self, faults: &[&str]) {
		std::fs::write(self.rooms.join("send-faults"), faults.join("\n") + "\n").unwrap();
	}

	/// A failure every read gets until it is cleared with `None`.
	pub fn events_fault(&self, fault: Option<&str>) {
		let path = self.rooms.join("events-fault");
		match fault {
			Some(fault) => std::fs::write(path, fault).unwrap(),
			None => std::fs::remove_file(path).unwrap(),
		}
	}

	/// How many reads the `events-fault` failed.
	pub fn failed_reads(&self) -> usize {
		std::fs::read_to_string(self.rooms.join("failed-reads")).map_or(0, |text| text.lines().count())
	}
}
