//! Exercise the directory executable's loader, options, custody, banner, and
//! signal barrier the way an operator meets them.
#![cfg(test)]
use rooms_testing::{child_process::Process, scratch::Scratch};
use std::{
	io::{BufRead, BufReader},
	process::{Command, Stdio},
	sync::mpsc,
	time::Duration,
};
#[path = "server_process/operator.rs"]
mod operator;
fn command() -> Command {
	let installed = std::env::var_os("GLOWCAP_ROOMS_SERVER_TEST_BIN");
	let mut command = Command::new(
		installed
			.clone()
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-server").into()),
	);
	for (key, _) in std::env::vars_os() {
		if key.to_string_lossy().starts_with("GLOWCAP_ROOMS_") {
			command.env_remove(key);
		}
	}
	if installed.is_some() {
		// The installed executable must locate its companion without build env.
		command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
	}
	command
}
/// Read `process`'s stderr until `until` appears, answering everything read.
fn stderr_until(process: &mut Process, until: &str) -> String {
	let stderr = process.child.stderr.take().unwrap();
	let (sender, receiver) = mpsc::sync_channel(1);
	let until = until.to_owned();
	std::thread::spawn(move || {
		let mut reader = BufReader::new(stderr);
		let mut seen = String::new();
		loop {
			let mut line = String::new();
			if reader.read_line(&mut line).unwrap() == 0 {
				break;
			}
			seen.push_str(&line);
			if line.contains(&until) {
				break;
			}
		}
		let _ = sender.send(seen);
	});
	receiver
		.recv_timeout(Duration::from_secs(10))
		.expect("the boot block in time")
}

#[test]
fn rooms_server_executable_prints_the_capabilities_it_minted() {
	let temp = Scratch::create("server-caps");
	let state = temp.join("state");
	let started = || {
		let mut cmd = command();
		cmd.arg(format!("--state={}", state.display()))
			.arg("--transport=tcp")
			.arg("--capabilities=diagnostics,admin-listeners,irc")
			.stdout(Stdio::piped())
			.stderr(Stdio::piped());
		cmd
	};
	// Standalone, the block names what is serving and ends on the ready line.
	let mut process = Process::new(started().spawn().unwrap(), "directory");
	let block = stderr_until(&mut process, "rooms: ready");
	assert!(
		block.lines().any(|line| line == "rooms: directory listening"),
		"{block}"
	);
	assert!(block.contains("  transport   "), "{block}");
	let recipe_of = |token: &str, block: &str| -> String {
		block
			.lines()
			.find_map(|line| line.strip_prefix(&format!("{token} ")))
			.unwrap_or_else(|| panic!("{token} in {block}"))
			.to_owned()
	};
	let locator = block
		.lines()
		.find_map(|line| line.trim().strip_prefix("locator     "))
		.unwrap();
	let listeners = recipe_of("ROOMS-ADMIN-LISTENERS", &block);
	let diagnostics = recipe_of("ROOMS-DIAGNOSTICS", &block);
	let irc = recipe_of("ROOMS-IRC", &block);
	let swiss_of = |recipe: &str| {
		String::from_utf8(
			glowcap::parse_sturdyref(recipe, glowcap::CaptpVersion::V1_0)
				.unwrap()
				.swissnum,
		)
		.unwrap()
	};
	for (file, recipe) in [
		("admin-listeners", &listeners),
		("diagnostics", &diagnostics),
		("irc", &irc),
	] {
		let parsed = glowcap::parse_sturdyref(recipe, glowcap::CaptpVersion::V1_0).unwrap();
		assert_eq!(parsed.locator, glowcap::parse_locator(locator).unwrap());
		assert_eq!(
			std::fs::read_to_string(state.join(file)).unwrap().trim(),
			swiss_of(recipe)
		);
		assert_eq!(parsed.swissnum.len(), 64);
	}
	assert!(!block.contains("ROOMS-OPERATOR"), "{block}");
	process.signal("-TERM");
	// Supervised, the complete recipes ride in the readiness record for the
	// supervisor to print, and nothing prints here. A new listening address
	// changes their route, while the saved publication identities remain exact.
	let mut again = Process::new(
		started()
			.env("GLOWCAP_ROOMS_SUPERVISED", "1")
			.env("GLOWCAP_ROOMS_READY_FORMAT", "json")
			.spawn()
			.unwrap(),
		"directory",
	);
	let mut ready = String::new();
	BufReader::new(again.child.stdout.take().unwrap())
		.read_line(&mut ready)
		.unwrap();
	let record: serde_json::Value = serde_json::from_str(
		ready
			.trim()
			.strip_prefix("ROOMS-SERVER-READY ")
			.expect("the readiness record"),
	)
	.unwrap();
	let lines: Vec<String> = record["capabilities"]
		.as_array()
		.expect("the carried capability lines")
		.iter()
		.map(|line| line.as_str().unwrap().to_owned())
		.collect();
	let lines = lines.join("\n");
	assert_eq!(
		swiss_of(&recipe_of("ROOMS-ADMIN-LISTENERS", &lines)),
		swiss_of(&listeners)
	);
	assert_eq!(
		swiss_of(&recipe_of("ROOMS-DIAGNOSTICS", &lines)),
		swiss_of(&diagnostics)
	);
	assert_eq!(swiss_of(&recipe_of("ROOMS-IRC", &lines)), swiss_of(&irc));
	again.signal("-TERM");
	let quiet = stderr_until(&mut again, "\0");
	assert!(
		!quiet.contains("ROOMS-"),
		"a supervised server printed its own lines: {quiet}"
	);
}

#[test]
fn rooms_server_executable_custody_restart_and_signals() {
	let temp = Scratch::create("server-process");
	let mut help = Process::new(
		command().arg("--help").stdout(Stdio::null()).spawn().unwrap(),
		"directory",
	);
	assert!(help.wait().success());
	let mut invalid = Process::new(
		command()
			.args(["--transport=tcp", "--port=bad"])
			.stderr(Stdio::null())
			.spawn()
			.unwrap(),
		"directory",
	);
	assert!(!invalid.wait().success());
	for transport in ["tcp", "iroh"] {
		let state = temp.join(transport);
		let mut document = None;
		let mut designator = None;
		for signal in ["-TERM", "-INT"] {
			let mut cmd = command();
			cmd.arg(format!("--state={}", state.display()))
				.arg(format!("--transport={transport}"));
			if transport == "iroh" {
				cmd.arg("--reachability=direct");
			}
			let mut process = Process::new(cmd.stdout(Stdio::piped()).spawn().unwrap(), "directory");
			let stdout = process.child.stdout.take().unwrap();
			let (sender, receiver) = mpsc::sync_channel(1);
			let reader = std::thread::spawn(move || {
				let mut line = String::new();
				BufReader::new(stdout).read_line(&mut line).unwrap();
				let _ = sender.send(line);
			});
			let line = receiver
				.recv_timeout(Duration::from_secs(5))
				.expect("directory ready deadline");
			reader.join().unwrap();
			let token = line
				.trim()
				.strip_prefix("ROOMS-SERVER-LISTENING ")
				.expect("server announce banner");
			// The token is what the web front reads: a bare port for a
			// loopback TCP room, the complete locator for iroh.
			if transport == "tcp" {
				assert!(
					token.parse::<u16>().is_ok(),
					"a loopback TCP room announces its port: {token}"
				);
			} else {
				let parsed = glowcap::parse_locator(token).unwrap();
				assert_eq!(parsed.transport, transport);
				// The identity seed in the document names the same node.
				if let Some(previous) = &designator {
					assert_eq!(&parsed.designator, previous);
				}
				designator = Some(parsed.designator);
			}
			let bytes = std::fs::read(state.join("rooms.json")).unwrap();
			if let Some(previous) = &document {
				assert_eq!(&bytes, previous);
			}
			document = Some(bytes);
			let mut contender = Process::new(
				command()
					.arg(format!("--state={}", state.display()))
					.arg("--transport=tcp")
					.stderr(Stdio::null())
					.spawn()
					.unwrap(),
				"directory",
			);
			assert!(
				!contender.wait().success(),
				"a second process acquired live directory custody"
			);
			process.signal(signal);
		}
	}
}
