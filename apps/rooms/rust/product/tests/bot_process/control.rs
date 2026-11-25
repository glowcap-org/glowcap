//! A `rooms-bot control` command run to its end within the rig's deadline.
use super::{rig::WAIT, session_rig::LinkSecret};
use rooms_testing::child_process::Process;
use serde_json::Value;
use std::{
	io::Write,
	process::{Command, Stdio},
	sync::mpsc,
};

/// Run a control `command` to its end within [`WAIT`], with `input` on
/// standard input when given, and answer the JSON it printed and whether it
/// succeeded. A command that printed nothing answers `null`, and anything
/// else that is not one JSON value fails the test. The command's stderr is
/// checked against every link in `secrets`, and a clean one goes to the
/// test's, which shows it when the test fails.
pub fn finish(mut command: Command, input: Option<&str>, secrets: &[LinkSecret]) -> (Value, bool) {
	command.stdout(Stdio::piped()).stderr(Stdio::piped());
	if input.is_some() {
		command.stdin(Stdio::piped());
	}
	let mut process = Process::new(command.spawn().unwrap(), "rooms-bot control").within(WAIT);
	let collect = |pipe: Box<dyn std::io::Read + Send>| {
		let (sender, receiver) = mpsc::channel();
		// The pump ends when the command's pipe closes, so it is not joined.
		std::thread::spawn(move || {
			let mut pipe = pipe;
			let mut bytes = Vec::new();
			std::io::Read::read_to_end(&mut pipe, &mut bytes).unwrap();
			sender.send(bytes).unwrap();
		});
		receiver
	};
	let stdout = collect(Box::new(process.child.stdout.take().unwrap()));
	let stderr = collect(Box::new(process.child.stderr.take().unwrap()));
	if let Some(text) = input {
		let mut stdin = process.child.stdin.take().unwrap();
		// A command that refuses before it reads its input closes it, which is
		// its answer, so the write may meet a closed pipe.
		match stdin.write_all(text.as_bytes()) {
			Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => {}
			written => written.unwrap(),
		}
	}
	let status = process.wait();
	let (stdout, stderr) = (stdout.recv_timeout(WAIT).unwrap(), stderr.recv_timeout(WAIT).unwrap());
	for secret in secrets {
		secret.assert_absent(&stderr, "a control command's standard error");
	}
	eprint!("{}", String::from_utf8_lossy(&stderr));
	let line = String::from_utf8(stdout).unwrap();
	let value = match line.trim() {
		"" => Value::Null,
		line => serde_json::from_str(line)
			.unwrap_or_else(|error| panic!("a control command printed what is not JSON: {error}")),
	};
	(value, status.success())
}
