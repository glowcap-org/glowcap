//! Process choices cross the actual socket adapter, managed workspace, CapTP
//! directory and room callback. Both creation and public entry retain custody.
use super::*;
use serde_json::json;

use super::session_rig::{call, direct_message, ready};

#[test]
fn status_names_the_session_directory_to_start_when_no_peer_listens() {
	let temp = Scratch::create("session-not-running");
	let state = temp.join("peer");
	let status = || {
		let failure = session_rig::try_call(&state, "status", json!({})).unwrap_err();
		assert!(failure.contains("not-running"), "{failure}");
		assert!(failure.contains(state.to_str().unwrap()), "{failure}");
		assert!(failure.contains("session start"), "{failure}");
	};
	status();
	std::fs::create_dir(&state).unwrap();
	drop(std::os::unix::net::UnixListener::bind(state.join("control.sock")).unwrap());
	status();
}

#[test]
fn managed_local_control_joins_and_replies_through_actual_custody() {
	let temp = Scratch::create("managed-journey");
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
	let (mut server, port) = ready(server, "ROOMS-SERVER-LISTENING ");
	let locator = format!("127.0.0.1:{port}");
	let mut peers = Vec::new();
	for nick in ["managed-one", "managed-two"] {
		let state = temp.join(nick);
		let mut command = super::command();
		command.args([
			format!("--state={}", state.display()),
			"--transport=tcp".into(),
			"--dial-transports=tcp".into(),
			"--local-control".into(),
		]);
		let (peer, _) = ready(command, "ROOMS-SESSION-LISTENING ");
		let joined = call(
			&state,
			"join",
			json!({"locator":[locator],"nick":[nick],"room":["managed-room"]}),
		);
		assert_eq!(joined["joined"][0]["room"], "managed-room");
		peers.push((peer, state));
	}
	let sent = call(
		&peers[0].1,
		"reply",
		json!({"room":["managed-room"],"text":["A managed process post"]}),
	);
	assert_eq!(sent["status"], "committed");
	assert!(
		sent["result"]["line"].is_string(),
		"actual post retained no line: {sent}"
	);
	for (_, state) in &peers {
		let deadline = Instant::now() + Duration::from_secs(5);
		loop {
			let batch = call(state, "tick", json!({"wait":["0"]}));
			if batch["pending"]
				.as_array()
				.unwrap()
				.iter()
				.any(|event| event["event"]["notice"]["text"] == "A managed process post")
			{
				break;
			}
			assert!(Instant::now() < deadline, "post did not reach {state:?}: {batch}");
			std::thread::sleep(Duration::from_millis(20));
		}
	}
	let direct = call(
		&peers[0].1,
		"reply",
		json!({"dm":["managed-two"],"text":["A managed private post"]}),
	);
	assert_eq!(direct["status"], "committed");
	let incoming = direct_message(&peers[1].1, "A managed private post");
	let reply = call(
		&peers[1].1,
		"reply",
		json!({"conversation":[incoming],"text":["A managed private reply"]}),
	);
	assert_eq!(reply["status"], "committed");
	direct_message(&peers[0].1, "A managed private reply");
	for (peer, _) in &mut peers {
		peer.signal("-TERM");
	}
	server.signal("-TERM");
}
#[test]
fn a_session_whose_stdout_is_closed_keeps_serving_its_local_control() {
	let temp = Scratch::create("closed-stdout");
	let state = temp.join("unread");
	let mut command = super::command();
	command.args([
		format!("--state={}", state.display()),
		"--transport=tcp".into(),
		"--local-control".into(),
	]);
	let mut process = Process::new(
		command.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap(),
		"session",
	);
	drop(process.child.stdout.take());
	let errors = process.child.stderr.take().unwrap();
	let (send, receive) = mpsc::channel();
	std::thread::spawn(move || {
		for line in BufReader::new(errors).lines().map_while(Result::ok) {
			if line.contains("nobody read the readiness announcement") {
				let _ = send.send(());
			}
		}
	});
	receive
		.recv_timeout(Duration::from_secs(8))
		.expect("the session never reported its unread announcement");
	let batch = call(&state, "tick", json!({"wait":["0"]}));
	assert!(batch["pending"].is_array(), "{batch}");
	process.signal("-TERM");
}

/// A nickname belongs to its workspace, so starting the workspace again under
/// another one is refused by name, and starting it under its own still works.
#[test]
fn starting_a_workspace_under_another_nickname_is_refused() {
	use super::session_rig::{Fixture, try_call};
	let fixture = Fixture::start("start-other-nick", &["nick-one"], "workshop");
	let state = &fixture.peers[0].state;
	let refused = try_call(state, "start", json!({"nick": ["nick-two"]})).unwrap_err();
	assert!(
		refused.contains(r#"nickname is \"nick-one\""#) && refused.contains("another --dir"),
		"{refused}"
	);
	let status = call(state, "status", json!({}));
	assert_eq!(status["workspace"]["directories"][0]["nick"], "nick-one");
	call(state, "start", json!({"nick": ["nick-one"]}));
	let locator = fixture.locator.clone();
	let refused = try_call(state, "start", json!({"locator": [locator], "nick": ["nick-two"]})).unwrap_err();
	assert!(refused.contains("another --dir"), "{refused}");
	fixture.finish();
}

#[test]
fn private_startup_keeps_session_links_out_of_managed_child_diagnostics() {
	let temp = Scratch::create("private-startup");
	let state = temp.join("managed");
	call(&state, "start", json!({"transport":["tcp"]}));
	let links = ["use.sturdyref", "management.sturdyref"]
		.map(|file| session_rig::LinkSecret::of(&std::fs::read_to_string(state.join(file)).unwrap()));
	call(&state, "stop", json!({}));
	let log = std::fs::read_to_string(state.join("control.log")).unwrap();
	assert!(log.contains("rooms session: ready"));
	for secret in links {
		secret.assert_absent(&log, "control.log");
	}
}

#[test]
fn private_startup_announces_foreground_session_readiness_without_bearer_links() {
	let temp = Scratch::create("private-foreground-session");
	let state = temp.join("peer");
	let path = temp.join("output");
	let log = std::fs::File::create(&path).unwrap();
	let mut cmd = super::command();
	cmd.arg(format!("--state={}", state.display()))
		.arg("--transport=tcp")
		.env(rooms_services::announce::PRIVATE_STARTUP, "1")
		.stdout(log.try_clone().unwrap())
		.stderr(log);
	let mut peer = Process::new(cmd.spawn().unwrap(), "private foreground session");
	let deadline = Instant::now() + Duration::from_secs(8);
	loop {
		if std::fs::read_to_string(&path).unwrap().contains("rooms session: ready") {
			break;
		}
		assert!(
			peer.child.try_wait().unwrap().is_none() && Instant::now() < deadline,
			"session readiness deadline"
		);
		std::thread::sleep(Duration::from_millis(10));
	}
	let links = ["use.sturdyref", "management.sturdyref"]
		.map(|file| session_rig::LinkSecret::of(&std::fs::read_to_string(state.join(file)).unwrap()));
	peer.signal("-TERM");
	let log = std::fs::read_to_string(path).unwrap();
	for secret in links {
		secret.assert_absent(&log, "foreground startup");
	}
}
