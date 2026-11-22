//! A bot under test: the real `rooms-bot` executable serving a bot directory
//! against a directory that stands in for the session.
use rooms_testing::{child_process::Process, scratch::Scratch};
use serde_json::{Value, json};
use std::{
	io::{BufRead, BufReader, Write},
	path::PathBuf,
	process::{Command, Stdio},
	sync::mpsc,
	time::{Duration, Instant},
};

/// The longest any wait in these tests lasts.
pub const WAIT: Duration = Duration::from_secs(30);

pub fn eventually<T>(what: &str, mut check: impl FnMut() -> Option<T>) -> T {
	let until = Instant::now() + WAIT;
	loop {
		if let Some(found) = check() {
			return found;
		}
		assert!(Instant::now() < until, "timed out waiting for {what}");
		std::thread::sleep(Duration::from_millis(20));
	}
}

pub struct Rig {
	_temp: Scratch,
	pub dir: PathBuf,
	pub rooms: PathBuf,
}

pub struct Bot {
	pub process: Process,
}

impl Bot {
	pub fn terminate(mut self) {
		self.process.signal("-TERM");
	}
	/// Send SIGTERM and wait for the bot to exit.
	pub fn stop(mut self) -> std::process::ExitStatus {
		self.process.signal("-TERM");
		self.process.wait()
	}
	pub fn kill(&mut self) {
		self.process.signal("-KILL");
	}
}

fn request(dir: &std::path::Path, verb: &str, named: Value, arguments: &[&str]) -> String {
	json!({"verb": verb, "state": dir, "named": named, "arguments": arguments}).to_string()
}

impl Rig {
	pub fn new(label: &str) -> Self {
		let temp = Scratch::create(label);
		let (dir, rooms) = (temp.join("bot"), temp.join("rooms"));
		std::fs::create_dir(&rooms).unwrap();
		Self {
			_temp: temp,
			dir,
			rooms,
		}
	}

	fn command(&self, body: &str) -> Command {
		let mut command = Command::new(env!("CARGO_BIN_EXE_rooms-bot"));
		command
			.args(["control", body])
			.env_remove("GLOWCAP_ROOMS_BOT_FAULT")
			.env_remove("GLOWCAP_ROOMS_VIEW_FAULT");
		command
	}

	/// Start `serve` and wait until it reports it is serving. `extra` adds or
	/// overrides flags. The first start names the harness and glowcap path.
	pub fn serve(&self, extra: Value, fault: Option<&str>) -> Bot {
		self.start(json!({"rooms-dir": [self.rooms]}), extra, fault)
	}

	/// Start `serve` against the live session `link` names. The first start
	/// stores the link, and later starts reuse it.
	/// The link travels on standard input, and the started process's command
	/// line is checked to hold no part of it.
	pub fn serve_linked(&self, link: &str, extra: Value) -> Bot {
		self.serve_linked_at(link, extra, None)
	}

	/// [`Rig::serve_linked`] with the bot armed to end itself at `fault`.
	pub fn serve_linked_at(&self, link: &str, extra: Value, fault: Option<&str>) -> Bot {
		if self.dir.join("session.link").exists() {
			return self.start(json!({}), extra, fault);
		}
		let bot = self.start_with(json!({"link": ["-"]}), extra, fault, Some(link));
		let command_line = std::fs::read(format!("/proc/{}/cmdline", bot.process.child.id()));
		if let Ok(command_line) = command_line {
			let secret = link.rsplit('/').next().unwrap().as_bytes();
			assert!(
				!command_line.windows(secret.len()).any(|window| window == secret),
				"the session link reached the bot's command line"
			);
		}
		bot
	}

	/// Start `serve` with `link` replacing the stored link.
	pub fn serve_replacing(&self, link: &str) -> Bot {
		self.start_with(
			json!({"link": ["-"], "replace-link": ["true"]}),
			json!({}),
			None,
			Some(link),
		)
	}

	/// An executable stand-in for the `glowcap` the harness is told to run.
	pub fn glowcap(&self) -> std::path::PathBuf {
		use std::os::unix::fs::PermissionsExt;
		let path = self._temp.join("glowcap");
		if !path.exists() {
			std::fs::write(&path, "#!/bin/sh\n").unwrap();
			std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
		}
		path
	}

	fn start(&self, named: Value, extra: Value, fault: Option<&str>) -> Bot {
		self.start_with(named, extra, fault, None)
	}

	fn start_with(&self, mut named: Value, extra: Value, fault: Option<&str>, stdin: Option<&str>) -> Bot {
		if !self.dir.join("config.json").exists() {
			named["harness"] = json!(["fake"]);
			named["glowcap"] = json!([self.glowcap()]);
		}
		for (key, value) in extra.as_object().into_iter().flatten() {
			named[key] = value.clone();
		}
		let mut command = self.command(&request(&self.dir, "serve", named, &[]));
		// A `view:` point arms the session view the harness's verbs attach,
		// not the bot.
		if let Some(point) = fault {
			match point.strip_prefix("view:") {
				Some(view) => command.env("GLOWCAP_ROOMS_VIEW_FAULT", view),
				None => command.env("GLOWCAP_ROOMS_BOT_FAULT", point),
			};
		}
		if stdin.is_some() {
			command.stdin(Stdio::piped());
		}
		let mut process = Process::new(command.stdout(Stdio::piped()).spawn().unwrap(), "bot").within(WAIT);
		if let Some(text) = stdin {
			let mut input = process.child.stdin.take().unwrap();
			std::io::Write::write_all(&mut input, format!("{text}\n").as_bytes()).unwrap();
		}
		let stdout = process.child.stdout.take().unwrap();
		let (ready, serving) = mpsc::channel();
		std::thread::spawn(move || {
			for line in BufReader::new(stdout).lines().map_while(Result::ok) {
				if line.starts_with("ROOMS-BOT-SERVING") {
					let _ = ready.send(());
				}
			}
		});
		serving
			.recv_timeout(WAIT)
			.expect("the bot never reported it was serving");
		Bot { process }
	}

	/// Run a command to its end and return its stdout and success.
	pub fn run(&self, verb: &str, named: Value) -> (Value, bool) {
		let output = self.command(&request(&self.dir, verb, named, &[])).output().unwrap();
		let line = String::from_utf8(output.stdout).unwrap();
		(
			serde_json::from_str(line.trim()).unwrap_or(Value::Null),
			output.status.success(),
		)
	}

	/// Run a command to its end with environment variables set.
	pub fn run_env(&self, verb: &str, named: Value, env: &[(&str, &str)]) -> (Value, bool) {
		let output = self
			.command(&request(&self.dir, verb, named, &[]))
			.envs(env.iter().copied())
			.output()
			.unwrap();
		let line = String::from_utf8(output.stdout).unwrap();
		(
			serde_json::from_str(line.trim()).unwrap_or(Value::Null),
			output.status.success(),
		)
	}

	/// Run a turn's verb to its end as the harness of a turn in
	/// `conversation` would.
	pub fn run_turn(&self, conversation: &str, verb: &str, named: Value, arguments: &[&str]) -> (Value, bool) {
		let body = json!({"verb": verb, "state": "", "named": named, "arguments": arguments}).to_string();
		let output = self
			.command(&body)
			.env("GLOWCAP_ROOMS_TURN_BOT", &self.dir)
			.env("GLOWCAP_ROOMS_TURN_CONVERSATION", conversation)
			.output()
			.unwrap();
		let line = String::from_utf8(output.stdout).unwrap();
		(
			serde_json::from_str(line.trim()).unwrap_or(Value::Null),
			output.status.success(),
		)
	}

	/// Run a command with `input` on standard input to its end.
	pub fn run_fed(&self, verb: &str, named: Value, input: &str) -> (Value, bool) {
		let mut child = self
			.command(&request(&self.dir, verb, named, &[]))
			.stdin(Stdio::piped())
			.stdout(Stdio::piped())
			.spawn()
			.unwrap();
		let mut stdin = child.stdin.take().unwrap();
		// best-effort: a command that refuses before it reads exits without
		// taking its input, and its exit is what the test reads.
		let _ = stdin.write_all(input.as_bytes());
		drop(stdin);
		let output = child.wait_with_output().unwrap();
		let line = String::from_utf8(output.stdout).unwrap();
		(
			serde_json::from_str(line.trim()).unwrap_or(Value::Null),
			output.status.success(),
		)
	}

	pub fn status(&self) -> Value {
		let (status, ok) = self.run("status", json!({}));
		assert!(ok, "status failed: {status}");
		status
	}

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
			Err(_) => Vec::new(),
		}
	}

	/// `count` commands from someone else in the session, each holding a
	/// settled receipt as any session command does. Each lets the oldest
	/// receipt that may go go first, the way the stand-in does: never one
	/// still running, nor a committed line nobody kept. One left unknown goes.
	pub fn crowd(&self, count: usize) {
		use rooms_application::content::session::custody::MAX_EFFECTS;
		let mut receipts = self.receipts();
		for n in 0..count {
			if receipts.len() == MAX_EFFECTS {
				let oldest = receipts
					.iter()
					.position(|receipt| {
						receipt["status"] != "pending" && (receipt["status"] != "committed" || receipt["kept"] == true)
					})
					.expect("someone else's command was refused for a full set of receipts");
				receipts.remove(oldest);
			}
			receipts.push(
				json!({"operation": format!("other-{n}"), "base": 0, "conversation": "elsewhere",
				"text": "x", "status": "committed", "kept": true}),
			);
		}
		std::fs::write(self.rooms.join("receipts.json"), serde_json::to_vec(&receipts).unwrap()).unwrap();
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

	/// How many reads the `events-fault` refused.
	pub fn refused_reads(&self) -> usize {
		std::fs::read_to_string(self.rooms.join("refused-reads")).map_or(0, |text| text.lines().count())
	}

	/// The ledger as the bot last wrote it.
	pub fn ledger(&self) -> Value {
		serde_json::from_slice(&std::fs::read(self.dir.join("turns.json")).unwrap()).unwrap()
	}

	pub fn log(&self) -> String {
		std::fs::read_to_string(self.dir.join("bot.log")).unwrap_or_default()
	}

	pub fn workdir(&self, conversation: &str) -> PathBuf {
		self.dir.join("work").join(conversation)
	}
}

/// The pid a fake harness recorded in `file` of a working directory.
pub fn recorded_pid(dir: &std::path::Path, file: &str) -> i32 {
	eventually(&format!("{file} in {}", dir.display()), || {
		std::fs::read_to_string(dir.join(file)).ok()?.trim().parse().ok()
	})
}

/// Whether the process is gone. A process that has exited and awaits its
/// parent's reaping still counts as present to `kill`, so this polls.
pub fn gone(pid: i32) -> bool {
	use nix::{errno::Errno, sys::signal::kill, unistd::Pid};
	let until = Instant::now() + Duration::from_secs(10);
	while Instant::now() < until {
		if kill(Pid::from_raw(pid), None) == Err(Errno::ESRCH) {
			return true;
		}
		std::thread::sleep(Duration::from_millis(20));
	}
	false
}
