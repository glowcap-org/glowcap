#![allow(dead_code, reason = "each test target uses the part of the rig it needs")]
//! Real Rooms processes for tests that need a session: the server, session
//! peers that have joined a room, and the control calls a person's shell would
//! make against a peer. Every wait has a deadline.
use rooms_testing::{child_process::Process, scratch::Scratch};
use serde_json::{Value, json};
use std::{
	io::{BufRead, BufReader, Read},
	path::{Path, PathBuf},
	process::{Command, Stdio},
	sync::mpsc,
	time::{Duration, Instant},
};

/// Assert that two secrets, such as session links, are equal without
/// printing either, so a failure puts no link in the test's output.
#[track_caller]
pub fn assert_same_secret(found: impl AsRef<[u8]>, expected: impl AsRef<[u8]>, what: &str) {
	assert!(found.as_ref() == expected.as_ref(), "{what}");
}

mod link_secret;
pub use link_secret::LinkSecret;

/// A `rooms-session` command with the test environment cleared.
pub fn command() -> Command {
	session_command(std::env::var_os("GLOWCAP_ROOMS_SESSION_TEST_BIN"))
}

/// The `rooms-session` this test build compiled, even when the run names an
/// installed one. Only a build with the `test-support` feature answers a
/// test's fault point.
fn built_command() -> Command {
	session_command(None)
}

fn session_command(installed: Option<std::ffi::OsString>) -> Command {
	let mut command = Command::new(
		installed
			.clone()
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-session").into()),
	);
	for (key, _) in std::env::vars_os() {
		if key.to_string_lossy().starts_with("GLOWCAP_ROOMS_SESSION_") {
			command.env_remove(key);
		}
	}
	if installed.is_some() {
		command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
	}
	command
}

/// How long a process may take to announce it is ready, or a control call
/// to finish, on a loaded host.
const READY: Duration = Duration::from_secs(30);

/// Start `command` and wait for the line that begins with `prefix`. Returns the
/// process and the rest of that line. The process's later output is read to
/// its end, so a write after the ready line never meets a closed pipe.
pub fn ready(mut command: Command, prefix: &str) -> (Process, String) {
	let mut process = Process::new(command.stdout(Stdio::piped()).spawn().unwrap(), "session");
	let output = process.child.stdout.take().unwrap();
	let (send, receive) = mpsc::channel();
	let prefix = prefix.to_owned();
	let pump = std::thread::spawn(move || {
		let mut announced = false;
		for line in BufReader::new(output).lines().map_while(Result::ok) {
			if let Some(value) = line.strip_prefix(&prefix)
				&& !announced
			{
				announced = true;
				// tolerant: the receiver is gone once the test stopped waiting.
				let _ = send.send(value.to_owned());
			}
		}
	});
	let route = receive.recv_timeout(READY).expect("product readiness deadline");
	(process.pumped_by(pump), route)
}

/// One control call to the session whose state is `state`.
pub fn call(state: &Path, verb: &str, named: Value) -> Value {
	try_call(state, verb, named).unwrap_or_else(|output| panic!("{verb}: {output}"))
}

/// One control call, tried again while the session paces it. Sixteen sends in
/// a row can use up the message allowance the owner's next line needs.
pub fn call_when_paced(state: &Path, verb: &str, named: Value) -> Value {
	let deadline = std::time::Instant::now() + Duration::from_secs(10);
	loop {
		match try_call(state, verb, named.clone()) {
			Ok(value) => return value,
			Err(output) if output.contains("rate-limited") && std::time::Instant::now() < deadline => {
				std::thread::sleep(Duration::from_millis(500));
			}
			Err(output) => panic!("{verb}: {output}"),
		}
	}
}

/// One control call that may fail. The error is what the call printed.
pub fn try_call(state: &Path, verb: &str, named: Value) -> Result<Value, String> {
	let options = json!({"verb":verb,"state":state,"named":named,"arguments":[]});
	let mut process = Process::new(
		command()
			.args(["control", &options.to_string()])
			.stdout(Stdio::piped())
			.spawn()
			.unwrap(),
		"session",
	)
	.within(READY);
	// Read on a thread, so an answer past the pipe buffer never blocks the
	// child before it exits.
	let mut stdout = process.child.stdout.take().unwrap();
	let reader = std::thread::spawn(move || {
		let mut output = String::new();
		stdout.read_to_string(&mut output).map(|_| output)
	});
	let status = process.wait();
	let output = reader.join().unwrap().unwrap();
	if !status.success() {
		return Err(format!("{named}: {output}"));
	}
	Ok(serde_json::from_str(&output).unwrap())
}

/// The id of the direct conversation a line with `text` arrived in.
pub fn direct_message(state: &Path, text: &str) -> String {
	let deadline = Instant::now() + Duration::from_secs(8);
	loop {
		let batch = call(state, "tick", json!({"wait":["0"]}));
		if let Some(event) = batch["pending"]
			.as_array()
			.unwrap()
			.iter()
			.find(|event| event["event"]["target"]["kind"] == "direct" && event["event"]["notice"]["text"] == text)
		{
			return event["event"]["target"]["id"].as_str().unwrap().into();
		}
		assert!(
			Instant::now() < deadline,
			"private message did not reach {state:?}: {batch}"
		);
		std::thread::sleep(Duration::from_millis(20));
	}
}

/// Wait until a line with `text` reaches the session at `state`.
pub fn text_arrived(state: &Path, text: &str) {
	let deadline = Instant::now() + Duration::from_secs(8);
	loop {
		let batch = call(state, "tick", json!({"wait":["0"]}));
		if batch["pending"]
			.as_array()
			.unwrap()
			.iter()
			.any(|event| event["event"]["notice"]["text"] == text)
		{
			return;
		}
		assert!(Instant::now() < deadline, "{text:?} did not reach {state:?}: {batch}");
		std::thread::sleep(Duration::from_millis(20));
	}
}

pub struct Peer {
	pub process: Process,
	pub state: PathBuf,
	/// The use link the peer announced.
	pub link: String,
	arguments: Vec<String>,
}

impl Peer {
	fn launch(arguments: &[String]) -> (Process, String) {
		Self::launch_with(arguments, None)
	}

	fn launch_with(arguments: &[String], fault: Option<&str>) -> (Process, String) {
		let mut command = match fault {
			Some(point) => {
				let mut command = built_command();
				command.env("GLOWCAP_ROOMS_SESSION_FAULT", point);
				command
			}
			None => command(),
		};
		command.args(arguments);
		ready(command, "ROOMS-SESSION-LISTENING ")
	}

	/// Stop the peer and start it again on the same state. A session on a fixed
	/// port announces the same link again.
	pub fn restart(&mut self) {
		self.restart_at(None);
	}

	/// [`Peer::restart`] with the session armed to end itself at `fault`.
	pub fn restart_at(&mut self, fault: Option<&str>) {
		self.process.signal("-TERM");
		assert!(self.process.wait().success(), "the session did not stop cleanly");
		self.relaunch(fault);
	}

	/// Start a peer whose process has ended again on the same state.
	pub fn relaunch(&mut self, fault: Option<&str>) {
		let (process, link) = Self::launch_with(&self.arguments, fault);
		self.process = process;
		assert_same_secret(&link, &self.link, "the restarted session announced a new link");
	}
}

/// Fields drop in order, so the sessions and the server are killed and
/// reaped before their state directory is removed.
pub struct Fixture {
	pub server: Process,
	pub locator: String,
	pub peers: Vec<Peer>,
	pub room: String,
	pub temp: Scratch,
}

impl Fixture {
	/// A server and one session per nickname, all in `room`. A nonzero entry of
	/// `ports` fixes that session's listening port, so its link survives a
	/// restart.
	pub fn start_on(name: &str, nicks: &[&str], room: &str, ports: &[u16]) -> Self {
		let temp = Scratch::create(name);
		let installed = std::env::var_os("GLOWCAP_ROOMS_SERVER_TEST_BIN");
		let mut server = Command::new(
			installed
				.clone()
				.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-server").into()),
		);
		if installed.is_some() {
			server.env_remove("LD_LIBRARY_PATH");
		}
		server.args(["--transport=tcp", "--port=0"]);
		let (server, port) = ready(server, "ROOMS-SERVER-LISTENING ");
		let locator = format!("127.0.0.1:{port}");
		let mut peers = Vec::new();
		for (at, nick) in nicks.iter().enumerate() {
			let state = temp.join(nick);
			let arguments = vec![
				format!("--state={}", state.display()),
				"--transport=tcp".into(),
				format!("--port={}", ports.get(at).copied().unwrap_or(0)),
				"--dial-transports=tcp".into(),
				"--local-control".into(),
			];
			let (process, link) = Peer::launch(&arguments);
			let joined = call(&state, "join", json!({"locator":[locator],"nick":[nick],"room":[room]}));
			assert_eq!(joined["joined"][0]["room"], room);
			peers.push(Peer {
				process,
				state,
				link,
				arguments,
			});
		}
		Self {
			server,
			locator,
			peers,
			room: room.into(),
			temp,
		}
	}

	pub fn start(name: &str, nicks: &[&str], room: &str) -> Self {
		Self::start_on(name, nicks, room, &[])
	}

	pub fn finish(mut self) {
		for peer in &mut self.peers {
			peer.process.signal("-TERM");
		}
		self.server.signal("-TERM");
	}

	/// The id of the room conversation as member `member` knows it.
	pub fn room_id(&self, member: usize) -> String {
		let status = call(&self.peers[member].state, "status", json!({}));
		status["workspace"]["conversations"]
			.as_array()
			.and_then(|rows| rows.iter().find(|row| row["kind"] == "room"))
			.and_then(|row| row["id"].as_str())
			.unwrap_or_else(|| panic!("no room conversation: {status}"))
			.into()
	}
}

/// A TCP port nothing listens on now, for a session that must come back on
/// the same port. It is below the range the system hands to a bind of port
/// zero, so no listener that binds port zero takes it while the session is
/// down. Test processes run side by side, so this process also holds a lock on
/// a claim file named for the port until it exits, and another process's
/// `free_port` passes over a port whose claim is held.
pub fn free_port() -> u16 {
	use std::sync::{
		Mutex,
		atomic::{AtomicU32, Ordering},
	};
	const FIRST: u32 = 20_000;
	const COUNT: u32 = 12_000;
	static NEXT: AtomicU32 = AtomicU32::new(0);
	static CLAIMS: Mutex<Vec<std::fs::File>> = Mutex::new(Vec::new());
	let claims = std::env::temp_dir().join("glowcap-rooms-test-ports");
	std::fs::create_dir_all(&claims).unwrap();
	let start = std::process::id() % COUNT;
	for _ in 0..COUNT {
		let port = u16::try_from(FIRST + (start + NEXT.fetch_add(1, Ordering::Relaxed)) % COUNT).unwrap();
		let claim = std::fs::OpenOptions::new()
			.create(true)
			.truncate(false)
			.write(true)
			.open(claims.join(port.to_string()))
			.unwrap();
		if claim.try_lock().is_ok() && std::net::TcpListener::bind(("127.0.0.1", port)).is_ok() {
			CLAIMS.lock().unwrap().push(claim);
			return port;
		}
	}
	panic!("no free port between {FIRST} and {}", FIRST + COUNT);
}

/// Run `scenario` on a fresh current-thread runtime with a LocalSet, for at most `limit`.
pub fn run_within<F: std::future::Future>(limit: Duration, scenario: F) -> F::Output {
	tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap()
		.block_on(rooms_testing::local_set::run_within(limit, scenario))
}

/// A Host that dials over TCP, for a test acting as a member.
pub async fn host() -> glowcap::Runtime {
	glowcap::Runtime::open(glowcap::RuntimeConfig::providers([glowcap::tcp::provider(
		glowcap::tcp::Config {
			profiles: glowcap::tcp::Profiles::TCP,
			..Default::default()
		},
	)]))
	.await
	.unwrap()
}

pub async fn attach(
	runtime: &glowcap::Runtime,
	link: &str,
) -> rooms_services::session::attached::View<rooms_platform::HostPlatform> {
	rooms_services::session::attached::View::attach(runtime, rooms_platform::HostPlatform, link)
		.await
		.unwrap()
}

/// How many receipt places of the session `grants` manages are free: a new
/// collaborator access named `label` says lines into `room` without keeping
/// them, each holding a place, until the session refuses one as full. A place
/// still held after `patience` counts as taken. The access stays issued, so
/// its lines keep their places, and a second count sees only what the first
/// left free. Pacing is waited out for at most [`READY`].
pub async fn free_places(
	grants: &rooms_services::session::attached::Grants<rooms_platform::HostPlatform>,
	room: &str,
	label: &str,
	patience: Duration,
) -> usize {
	use rooms_application::content::session::{Preset, Terms, custody::MAX_EFFECTS};
	let terms = Terms::new(Preset::Collaborator.values()).unwrap();
	let issued = grants.issue(label, &terms).await.unwrap();
	let holder = host().await;
	let view = attach(&holder, &issued.link).await;
	let deadline = Instant::now() + patience;
	let paced = Instant::now() + READY;
	let mut placed = 0;
	'places: while placed < MAX_EFFECTS {
		let (operation, text) = (format!("{label}-{placed}"), format!("{label} {placed}"));
		loop {
			let base = view.revision().await.unwrap();
			match view.say_at(&operation, base, room, &text).await {
				Ok(status) => {
					assert_eq!(
						status,
						rooms_services::session::attached::EffectStatus::Committed,
						"{label}: {operation}"
					);
					placed += 1;
					break;
				}
				Err(rooms_services::session::attached::Error::Peer(error))
					if error.failure_code() == Some(rooms_application::failure::FailureCode::RateLimited) =>
				{
					assert!(Instant::now() < paced, "{label}: the session paced every line");
				}
				Err(rooms_services::session::attached::Error::Peer(error))
					if error.failure_code() == Some(rooms_application::failure::FailureCode::ReceiptsFull) =>
				{
					if placed > 0 || Instant::now() >= deadline {
						break 'places;
					}
				}
				Err(error) => panic!("{label}: {operation}: {error}"),
			}
			tokio::time::sleep(Duration::from_millis(200)).await;
		}
	}
	drop(view);
	holder.close(glowcap::PendingWork::Cancel).await.unwrap();
	placed
}
