//! Host executable startup against a real Tor control service. Networking
//! is disabled: this proves key custody and local forwarding, not circuits.
#![cfg(test)]
use std::{
	io::{BufRead, BufReader},
	path::{Path, PathBuf},
	process::{Child, Command, Stdio},
	sync::mpsc,
	time::{Duration, Instant},
};

struct Process(Child);
impl Process {
	fn wait(&mut self) -> std::process::ExitStatus {
		let deadline = Instant::now() + Duration::from_secs(10);
		loop {
			if let Some(status) = self.0.try_wait().unwrap() {
				return status;
			}
			assert!(Instant::now() < deadline, "onion process did not finish");
			std::thread::sleep(Duration::from_millis(10));
		}
	}
	fn stop(&mut self) {
		assert!(
			Command::new("/bin/kill")
				.args(["-TERM", &self.0.id().to_string()])
				.status()
				.unwrap()
				.success()
		);
		assert!(self.wait().success());
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
		let _ = std::fs::remove_dir_all(&self.0);
	}
}

fn first_line(child: &mut Process) -> String {
	let output = child.0.stdout.take().unwrap();
	let (sender, receiver) = mpsc::channel();
	std::thread::spawn(move || {
		let mut line = String::new();
		BufReader::new(output).read_line(&mut line).unwrap();
		let _ = sender.send(line);
	});
	receiver
		.recv_timeout(Duration::from_secs(15))
		.expect("host onion startup deadline")
}
fn command(binary: &str, state: &Path, control: &Path, socks: &Path, port: u16) -> Command {
	let mut command = Command::new(binary);
	for (name, _) in std::env::vars_os() {
		if name.to_string_lossy().starts_with("GLOWCAP_") {
			command.env_remove(name);
		}
	}
	command
		.args([
			format!("--state={}", state.display()),
			"--transport=onion".into(),
			format!("--port={port}"),
		])
		.env("GLOWCAP_ONION_CONTROL", control)
		.env("GLOWCAP_ONION_SOCKS", socks)
		.stdout(Stdio::piped())
		.stderr(Stdio::from(
			std::fs::File::create(state.with_extension("stderr")).unwrap(),
		));
	command
}

#[test]
#[ignore = "requires tor executable; starts local Tor with networking disabled"]
fn session_peers_restore_onion_keys_before_readiness() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	tokio::task::LocalSet::new().block_on(&runtime, async {
		tokio::time::timeout(Duration::from_secs(60), scenario())
			.await
			.expect("onion process scenario deadline");
	});
}
async fn scenario() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-onion-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	#[cfg(unix)]
	{
		use std::os::unix::fs::PermissionsExt;
		std::fs::set_permissions(&temp.0, std::fs::Permissions::from_mode(0o700)).unwrap();
	}
	let control = temp.0.join("control");
	let socks = temp.0.join("socks");
	let mut tor = Process(
		Command::new("tor")
			.args([
				"--RunAsDaemon",
				"0",
				"--DisableNetwork",
				"1",
				"--CookieAuthentication",
				"0",
				"--DataDirectory",
			])
			.arg(temp.0.join("tor"))
			.arg("--ControlSocket")
			.arg(&control)
			.arg("--SocksPort")
			.arg(format!("unix:{}", socks.display()))
			.arg("--Log")
			.arg(format!("notice file {}", temp.0.join("tor.log").display()))
			.stdout(Stdio::null())
			.stderr(Stdio::null())
			.spawn()
			.expect("start local Tor"),
	);
	let deadline = Instant::now() + Duration::from_secs(10);
	while !control.exists() {
		assert!(
			tor.0.try_wait().unwrap().is_none(),
			"Tor startup failed: {}",
			std::fs::read_to_string(temp.0.join("tor.log")).unwrap_or_default()
		);
		assert!(Instant::now() < deadline, "Tor control startup deadline");
		tokio::time::sleep(Duration::from_millis(20)).await;
	}
	for (name, binary) in [
		("server", env!("CARGO_BIN_EXE_rooms-server")),
		("archive", env!("CARGO_BIN_EXE_rooms-archive")),
		("session", env!("CARGO_BIN_EXE_rooms-session")),
	] {
		let state = temp.0.join(name);
		let port = std::net::TcpListener::bind("127.0.0.1:0")
			.unwrap()
			.local_addr()
			.unwrap()
			.port();
		let mut first = Process(command(binary, &state, &control, &socks, port).spawn().unwrap());
		let announced = first_line(&mut first);
		assert!(
			announced.starts_with(&format!("ROOMS-{}-LISTENING ocapn://", name.to_uppercase())),
			"{name} did not announce onion readiness: {}",
			std::fs::read_to_string(state.with_extension("stderr")).unwrap()
		);
		assert!(announced.contains(".onion"));
		let key_file = state.join("onion-key");
		let key = std::fs::read(&key_file).expect("key committed before readiness");
		assert!(!key.is_empty());
		#[cfg(unix)]
		{
			use std::os::unix::fs::PermissionsExt;
			assert_eq!(
				std::fs::metadata(&key_file).unwrap().permissions().mode() & 0o777,
				0o600
			);
		}
		if name == "server" {
			directory_over_forward(port).await;
		}
		first.stop();
		assert!(
			!std::fs::read_to_string(state.with_extension("stderr"))
				.unwrap()
				.contains(std::str::from_utf8(&key).unwrap())
		);
		let mut again = Process(command(binary, &state, &control, &socks, port).spawn().unwrap());
		assert_eq!(
			first_line(&mut again),
			announced,
			"{name} changed its address on restart: {}",
			std::fs::read_to_string(state.with_extension("stderr")).unwrap()
		);
		assert_eq!(std::fs::read(&key_file).unwrap(), key);
		again.stop();
		for malformed in [b"".as_slice(), b"not-a-service-key".as_slice()] {
			std::fs::write(&key_file, malformed).unwrap();
			let mut refused = Process(command(binary, &state, &control, &socks, port).spawn().unwrap());
			assert!(
				first_line(&mut refused).is_empty(),
				"{name} announced after a malformed key"
			);
			assert!(!refused.wait().success());
			assert_eq!(std::fs::read(&key_file).unwrap(), malformed);
			assert!(
				std::net::TcpListener::bind(("127.0.0.1", port)).is_ok(),
				"failed startup retained its forward listener"
			);
		}
	}
	tor.stop();
}

async fn directory_over_forward(port: u16) {
	use glowcap::{ConnectOptions, PendingWork, Runtime, RuntimeConfig};
	let runtime = Runtime::open(RuntimeConfig::providers([glowcap::tcp::provider(Default::default())]))
		.await
		.unwrap();
	let session = runtime
		.connect(&glowcap::tcp::locator("127.0.0.1", port), ConnectOptions::default())
		.await
		.unwrap();
	let directory = session.fetch("directory").await.unwrap();
	let room = session
		.send(&directory, "open", &["onion forwarding".into()])
		.await
		.unwrap();
	assert!(matches!(room, glowcap::Argument::Reference(_)));
	session.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
}
