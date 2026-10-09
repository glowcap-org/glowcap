//! Exercise the directory executable's loader, options, custody, banner, and
//! signal barrier the way an operator meets them.
use std::{
	io::{BufRead, BufReader},
	path::PathBuf,
	process::{Child, Command, ExitStatus, Stdio},
	sync::mpsc,
	time::{Duration, Instant},
};
#[path = "server_process/operator.rs"]
mod operator;
struct Process(Child);
impl Process {
	fn wait(&mut self) -> ExitStatus {
		let deadline = Instant::now() + Duration::from_secs(5);
		loop {
			if let Some(status) = self.0.try_wait().unwrap() {
				return status;
			}
			assert!(Instant::now() < deadline, "directory process did not finish");
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
		assert!(self.wait().success(), "directory signal shutdown failed");
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
	let stderr = process.0.stderr.take().unwrap();
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
	let temp = Temp(std::env::temp_dir().join(format!("rooms-server-caps-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let state = temp.0.join("state");
	let started = || {
		let mut cmd = command();
		cmd.arg(format!("--state={}", state.display()))
			.arg("--transport=tcp")
			.arg("--diagnostics")
			.arg("--admin-listeners")
			.arg("--irc")
			.stdout(Stdio::piped())
			.stderr(Stdio::piped());
		cmd
	};
	// Standalone, the block names what is serving and ends on the ready line.
	let mut process = Process(started().spawn().unwrap());
	let block = stderr_until(&mut process, "rooms: ready");
	assert!(block.starts_with("rooms: directory listening"), "{block}");
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
	let printed = command()
		.arg(format!("--capabilities={}", state.display()))
		.env("GLOWCAP_ROOMS_LOCATOR", locator)
		.current_dir(std::env::temp_dir())
		.output()
		.unwrap();
	assert!(
		printed.status.success(),
		"capabilities are readable while the server owns custody"
	);
	let printed = String::from_utf8(printed.stdout).unwrap();
	assert_eq!(recipe_of("ROOMS-ADMIN-LISTENERS", &printed), listeners);
	assert_eq!(recipe_of("ROOMS-DIAGNOSTICS", &printed), diagnostics);
	assert_eq!(recipe_of("ROOMS-IRC", &printed), irc);
	assert!(printed.contains("ROOMS-OPERATOR (not minted here; start with --operator to mint it)"));
	process.signal("-TERM");
	// Supervised, only complete recipes print. A new listening address changes
	// their route, while the saved publication identities remain exact.
	let mut again = Process(started().env("GLOWCAP_ROOMS_SUPERVISED", "1").spawn().unwrap());
	let lines = stderr_until(&mut again, "ROOMS-IRC");
	assert!(!lines.contains("rooms: directory listening"), "{lines}");
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
	std::fs::write(state.join("diagnostics"), "invalid state").unwrap();
	let refused = command()
		.arg(format!("--capabilities={}", state.display()))
		.env("GLOWCAP_ROOMS_LOCATOR", locator)
		.output()
		.unwrap();
	assert!(!refused.status.success());
	assert!(
		refused.stdout.is_empty(),
		"invalid state must not produce a partial capability handoff"
	);
	assert_eq!(
		std::fs::read_to_string(state.join("diagnostics")).unwrap(),
		"invalid state"
	);
}

#[test]
fn rooms_server_executable_custody_restart_and_signals() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-server-process-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let mut help = Process(command().arg("--help").stdout(Stdio::null()).spawn().unwrap());
	assert!(help.wait().success());
	let mut invalid = Process(
		command()
			.args(["--transport=tcp", "--port=bad"])
			.stderr(Stdio::null())
			.spawn()
			.unwrap(),
	);
	assert!(!invalid.wait().success());
	for transport in ["tcp", "iroh"] {
		let state = temp.0.join(transport);
		let mut document = None;
		let mut designator = None;
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
				"a second process acquired live directory custody"
			);
			process.signal(signal);
		}
	}
}
