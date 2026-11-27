//! A scripted stand-in for a coding harness, used only by the Rooms bot's
//! process tests. It reads the prompt on stdin and obeys the last directive in
//! the text of its JSON lines, so a test places a failure at an exact point of
//! a turn.
//!
//! Directives: `reply:<text>`, `exit-after-reply:<text>`, `crash`,
//! `crash-once`, `hang`, `slow-once:<text>`, `wait-file:<text>` (answers once
//! a `release` file exists in the working directory), `outage-then-wait:<text>`
//! (the first run reports an `outage` failure and exits 1, and later runs wait
//! as `wait-file:` does), and `long:<bytes>` (an
//! answer of that many bytes in numbered paragraphs), `describe-files`
//! (answers with the saved path, size and SHA-256 of each file the last
//! message carried), and `act:<json array>` (runs the sibling
//! `rooms-bot control <request>` once for each request in the array, saves
//! each stdout as `act-<n>.out` and each stderr as `act-<n>.err` in the
//! working directory, and answers with the exit codes, or with the silent
//! final answer for `act-quietly:<json array>`; a request `{"after": "<file>"}` runs no verb and waits
//! until that file exists in the working directory, so a test can read what an
//! earlier action printed before a later one runs), `act-once:<json array>` (the same, as an agent that
//! follows its prompt: it skips a request whose verb the prompt's bot record
//! says not to repeat, a line `- <verb> ...` holding "Do not", and answers
//! `skipped` for it, after a `go` file exists in the working directory, so a
//! test can place the files it sends first), `fail:<kind> <message>` (reports a failure of that kind,
//! `auth`, `rate`, `refused`, `outage`, or `crash`, with the message and exits 1),
//! `reject-resume:<text>` (a resumed run reports a failure without naming a
//! session and exits 1, as an agent does with a session it cannot find, and
//! a new run answers with the text), `reject-resume-crash` (the same, and
//! a new run crashes), `reject-resume-slow:<seconds>` (a resumed run waits
//! that long, then fails as `reject-resume:` does, and a new run writes
//! `fresh.marker` and never answers), `remember:<file> <summary>` (writes the
//! summary as the first line of `memory/<file>` under
//! `GLOWCAP_ROOMS_TURN_HOME` and answers with the path it wrote), and
//! `recall` (answers with the memories the prompt lists, as
//! `<file>=<summary>` separated by ` | `, then `unlisted=<count>`).
//!
//! A text that holds several directive keys obeys the first key in the order
//! of `KEYS`, not the first in the text, so a key that is a prefix of another
//! comes after it.
//!
//! A `hang`, an unreleased `wait-file`, a first `slow-once`, or a new
//! `reject-resume-slow:` run would idle forever, so the harness ends itself,
//! and the `sleep` a `hang` started, after [`SELF_DEADLINE`].
//!
//! State lives in the working directory: `harness.pid`, `prompt.txt`,
//! `settings.txt`, `environment.txt` (the environment the bot gave it, one
//! `NAME=value` per line), `child.pid`, the `*.marker` files, and `runs.log`,
//! which gains one line each time the harness starts.
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
	io::{Read, Write},
	process::{Command, Stdio},
	sync::atomic::{AtomicU32, Ordering},
	time::Duration,
};

/// How long the harness lives at most, so a test that fails never leaves one
/// running.
const SELF_DEADLINE: Duration = Duration::from_secs(120);

/// The process number of the `sleep` a `hang` started, or 0.
static CHILD: AtomicU32 = AtomicU32::new(0);

/// Exit after [`SELF_DEADLINE`], ending the child it spawned first.
fn start_deadline() {
	std::thread::spawn(|| {
		std::thread::sleep(SELF_DEADLINE);
		let child = CHILD.load(Ordering::SeqCst);
		if let Some(pid) = i32::try_from(child).ok().filter(|pid| *pid > 1) {
			// best-effort: a child that already ended needs no signal.
			let _ = nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), nix::sys::signal::Signal::SIGKILL);
		}
		eprintln!("fake harness: self-deadline reached");
		std::process::exit(2);
	});
}

fn record_run(resumed: Option<&str>) {
	let line = format!("run pid={} resume={}\n", std::process::id(), resumed.unwrap_or("-"));
	let written = std::fs::OpenOptions::new()
		.create(true)
		.append(true)
		.open("runs.log")
		.and_then(|mut file| file.write_all(line.as_bytes()));
	if let Err(error) = written {
		fail("cannot record its run", error);
	}
}

const KEYS: &[&str] = &[
	"reject-resume-crash",
	"reject-resume-slow:",
	"reject-resume:",
	"fail:",
	"exit-after-reply:",
	"reply:",
	"crash-once",
	"crash",
	"hang",
	"slow-once:",
	"wait-file:",
	"outage-then-wait:",
	"long:",
	"describe-files",
	"act-once:",
	"act-quietly:",
	"act:",
	"remember:",
	"recall",
];

fn emit(line: &str) {
	let mut out = std::io::stdout().lock();
	// best-effort: a bot that stopped reading has already decided this turn.
	let _ = writeln!(out, "{line}").and_then(|()| out.flush());
}

fn json_line(key: &str, value: &str) -> String {
	serde_json::json!({ key: value }).to_string()
}

/// The last directive in the prompt's line texts, as its key and the rest.
fn directive(prompt: &str) -> Option<(&'static str, String)> {
	prompt.lines().rev().find_map(|line| {
		let text = serde_json::from_str::<Value>(line)
			.ok()?
			.get("text")?
			.as_str()?
			.to_owned();
		KEYS.iter()
			.find_map(|key| text.split_once(key).map(|(_, rest)| (*key, rest.to_owned())))
	})
}

/// Numbered paragraphs of about a thousand bytes, `bytes` long in all.
fn long_answer(bytes: usize) -> String {
	let mut text = String::new();
	let mut paragraph = 0;
	while text.len() < bytes {
		if !text.is_empty() {
			text.push_str("\n\n");
		}
		let head = format!("p{paragraph} ");
		let body = 1000usize
			.min(bytes.saturating_sub(text.len()))
			.saturating_sub(head.len());
		text.push_str(&head);
		text.push_str(&"x".repeat(body));
		paragraph += 1;
	}
	text
}

/// The files the last prompt line that has any carries, one answer part each.
fn describe_files(prompt: &str) -> String {
	let files = prompt
		.lines()
		.rev()
		.filter_map(|line| serde_json::from_str::<Value>(line).ok())
		.find_map(|line| line.get("files").and_then(Value::as_array).cloned())
		.unwrap_or_default();
	let parts: Vec<String> = files
		.iter()
		.map(|file| match file.get("saved").and_then(Value::as_str) {
			Some(saved) => match std::fs::read(saved) {
				Ok(bytes) => {
					let hash: String = Sha256::digest(&bytes)
						.iter()
						.map(|byte| format!("{byte:02x}"))
						.collect();
					format!("{saved} bytes={} sha256={hash}", bytes.len())
				}
				Err(error) => format!("{saved} unreadable: {error}"),
			},
			None => format!(
				"skipped: {}",
				file.get("skipped").and_then(Value::as_str).unwrap_or("?")
			),
		})
		.collect();
	if parts.is_empty() {
		"no files".into()
	} else {
		parts.join(" | ")
	}
}

/// Whether the prompt's record of the bot says not to repeat `verb`: a line
/// that starts `- <verb> ` and holds "Do not".
fn told_not_to(prompt: &str, verb: &str) -> bool {
	let start = format!("- {verb} ");
	prompt
		.lines()
		.any(|line| line.starts_with(&start) && line.contains("Do not"))
}

/// Run each request in `array` as `rooms-bot control <request>` and describe
/// what it printed. With a `prompt`, a request it says not to repeat is
/// skipped, as an agent that follows the prompt skips it.
fn act(array: &str, prompt: Option<&str>) -> String {
	let requests: Vec<Value> = match serde_json::from_str(array) {
		Ok(requests) => requests,
		Err(error) => fail("act: needs a JSON array of requests", error),
	};
	let bot = match std::env::current_exe() {
		Ok(path) => path.with_file_name("rooms-bot"),
		Err(error) => fail("cannot find rooms-bot", error),
	};
	requests
		.iter()
		.enumerate()
		.map(|(at, request)| {
			if let Some(file) = request.get("after").and_then(Value::as_str) {
				while !std::path::Path::new(file).exists() {
					std::thread::sleep(Duration::from_millis(20));
				}
				return "after".to_owned();
			}
			let verb = request.get("verb").and_then(Value::as_str).unwrap_or_default();
			if prompt.is_some_and(|prompt| told_not_to(prompt, verb)) {
				return "skipped".to_owned();
			}
			match Command::new(&bot).arg("control").arg(request.to_string()).output() {
				Ok(output) => {
					// Both streams are saved for a test to scan, since a real agent
					// reads them both.
					for (stream, bytes) in [("out", &output.stdout), ("err", &output.stderr)] {
						if let Err(error) = std::fs::write(format!("act-{at}.{stream}"), bytes) {
							fail("cannot save an action's output", error);
						}
					}
					format!("exit={}", output.status.code().unwrap_or(-1))
				}
				Err(error) => format!("could not run rooms-bot: {error}"),
			}
		})
		.collect::<Vec<_>>()
		.join(" ")
}

/// Write one memory in the home the turn's variable names.
fn remember(text: &str) -> String {
	let Some((file, summary)) = text.split_once(' ') else {
		fail("remember: needs a file and a summary", text);
	};
	let home = match std::env::var("GLOWCAP_ROOMS_TURN_HOME") {
		Ok(home) => std::path::PathBuf::from(home),
		Err(error) => fail("remember: GLOWCAP_ROOMS_TURN_HOME", error),
	};
	let path = home.join("memory").join(file);
	if let Err(error) = std::fs::write(&path, format!("{summary}\nwritten by a turn\n")) {
		fail("remember: cannot write the memory", error);
	}
	path.display().to_string()
}

/// The memories the prompt lists, and how many it says are not listed.
fn recall(prompt: &str) -> String {
	let mut parts: Vec<String> = prompt
		.lines()
		.filter_map(|line| serde_json::from_str::<Value>(line).ok())
		.filter_map(|line| {
			let file = line.get("file")?.as_str()?.to_owned();
			Some(match line.get("summary").and_then(Value::as_str) {
				Some(summary) => format!("{file}={summary}"),
				None => file,
			})
		})
		.collect();
	let unlisted = prompt
		.lines()
		.find_map(|line| line.strip_suffix(" older memories are not listed. List your memory directory to see them."))
		.unwrap_or("0");
	parts.push(format!("unlisted={unlisted}"));
	parts.join(" | ")
}

fn fail(what: &str, error: impl std::fmt::Display) -> ! {
	eprintln!("fake harness: {what}: {error}");
	std::process::exit(2);
}

fn idle() -> ! {
	loop {
		std::thread::sleep(Duration::from_secs(60));
	}
}

fn main() {
	let mut args = std::env::args().skip(1);
	let mut resumed = None;
	let mut settings = Vec::new();
	while let Some(arg) = args.next() {
		match arg.as_str() {
			"--resume" | "--system" | "--model" | "--permission" => {
				let value = args.next().unwrap_or_default();
				if arg == "--resume" {
					resumed = Some(value.clone());
				}
				settings.push(format!("{arg} {}", value.replace('\n', "\\n")));
			}
			_ => {}
		}
	}
	start_deadline();
	record_run(resumed.as_deref());
	if let Err(error) = std::fs::write("harness.pid", std::process::id().to_string()) {
		fail("cannot record its pid", error);
	}
	let mut prompt = String::new();
	if let Err(error) = std::io::stdin().read_to_string(&mut prompt) {
		fail("cannot read the prompt", error);
	}
	if let Err(error) = std::fs::write("settings.txt", settings.join("\n")) {
		fail("cannot record its settings", error);
	}
	if let Err(error) = std::fs::write("prompt.txt", &prompt) {
		fail("cannot record its prompt", error);
	}
	let environment: Vec<String> = std::env::vars_os()
		.map(|(name, value)| format!("{}={}", name.to_string_lossy(), value.to_string_lossy()))
		.collect();
	if let Err(error) = std::fs::write("environment.txt", environment.join("\n")) {
		fail("cannot record its environment", error);
	}
	let directed = directive(&prompt);
	if let (Some(_), Some((key @ ("reject-resume:" | "reject-resume-crash" | "reject-resume-slow:"), text))) =
		(&resumed, &directed)
	{
		if *key == "reject-resume-slow:" {
			let wait: u64 = text
				.trim()
				.parse()
				.unwrap_or_else(|error| fail("reject-resume-slow: needs whole seconds", error));
			// A wait past the self-deadline would end the harness first.
			if wait >= SELF_DEADLINE.as_secs() {
				fail("reject-resume-slow: outlasts the self-deadline", wait);
			}
			std::thread::sleep(Duration::from_secs(wait));
		}
		emit(&serde_json::json!({"failure": "crash", "message": "no conversation found"}).to_string());
		eprintln!("fake harness: {key} refused the session");
		std::process::exit(1);
	}
	// A new session has the UUID form every harness session id has.
	let session = resumed.unwrap_or_else(|| format!("fa4e0000-0000-4000-8000-{:012x}", std::process::id()));
	emit(&json_line("session", &session));
	emit(&json_line("activity", "thinking"));
	emit(&json_line("text", "working"));
	let marker = |name: &str| std::path::Path::new(name).exists();
	let mark = |name: &str| {
		if let Err(error) = std::fs::write(name, "") {
			fail("cannot write a marker", error);
		}
	};
	let Some((key, text)) = directed else {
		emit(&json_line("final", "no directive"));
		return;
	};
	match key {
		"exit-after-reply:" => {
			emit(&json_line("final", &text));
			std::process::exit(1);
		}
		"reply:" | "reject-resume:" => emit(&json_line("final", &text)),
		"fail:" => {
			let (kind, message) = text.split_once(' ').unwrap_or((text.as_str(), ""));
			emit(&serde_json::json!({"failure": kind, "message": message}).to_string());
			std::process::exit(1);
		}
		"crash-once" if marker("crash.marker") => emit(&json_line("final", "recovered")),
		"crash-once" | "crash" | "reject-resume-crash" => {
			if key == "crash-once" {
				mark("crash.marker");
			}
			eprintln!("fake harness: crash");
			std::process::exit(3);
		}
		"hang" => {
			match Command::new("sleep").arg("300").stdin(Stdio::null()).spawn() {
				Ok(child) => {
					CHILD.store(child.id(), Ordering::SeqCst);
					if let Err(error) = std::fs::write("child.pid", child.id().to_string()) {
						fail("cannot record its child", error);
					}
				}
				Err(error) => fail("cannot start sleep", error),
			}
			idle();
		}
		"reject-resume-slow:" => {
			mark("fresh.marker");
			idle();
		}
		"slow-once:" if marker("slow.marker") => emit(&json_line("final", &text)),
		"slow-once:" => {
			mark("slow.marker");
			idle();
		}
		"outage-then-wait:" if !marker("outage.marker") => {
			mark("outage.marker");
			emit(&serde_json::json!({"failure": "outage", "message": "unavailable"}).to_string());
			std::process::exit(1);
		}
		"wait-file:" | "outage-then-wait:" => {
			mark("waiting.marker");
			while !marker("release") {
				std::thread::sleep(Duration::from_millis(20));
			}
			emit(&json_line("final", &text));
		}
		"long:" => match text.trim().parse() {
			Ok(bytes) => emit(&json_line("final", &long_answer(bytes))),
			Err(error) => fail("long: needs a byte count", error),
		},
		"describe-files" => emit(&json_line("final", &describe_files(&prompt))),
		"act:" => emit(&json_line("final", &act(&text, None))),
		"act-quietly:" => {
			act(&text, None);
			emit(&json_line("final", "[[no reply]]"));
		}
		"act-once:" => {
			while !marker("go") {
				std::thread::sleep(Duration::from_millis(20));
			}
			emit(&json_line("final", &act(&text, Some(&prompt))));
		}
		"remember:" => emit(&json_line("final", &remember(text.trim()))),
		"recall" => emit(&json_line("final", &recall(&prompt))),
		_ => emit(&json_line("final", "no directive")),
	}
}
