//! Process choices cross the actual socket adapter, managed workspace, CapTP
//! directory and room callback. Both creation and public entry retain custody.
use super::*;
use serde_json::{Value, json};
use std::io::Read;

fn ready(mut command: Command, prefix: &str) -> (Process, String) {
	let mut process = Process(command.stdout(Stdio::piped()).spawn().unwrap());
	let output = process.0.stdout.take().unwrap();
	let (send, receive) = mpsc::channel();
	let prefix = prefix.to_owned();
	std::thread::spawn(move || {
		for line in BufReader::new(output).lines() {
			let line = line.unwrap();
			if let Some(value) = line.strip_prefix(&prefix) {
				let _ = send.send(value.to_owned());
				break;
			}
		}
	});
	let route = receive
		.recv_timeout(Duration::from_secs(8))
		.expect("product readiness deadline");
	(process, route)
}
fn call(state: &std::path::Path, verb: &str, named: Value) -> Value {
	let options = json!({"verb":verb,"state":state,"named":named,"arguments":[]});
	let mut process = Process(
		super::command()
			.args(["control", &options.to_string()])
			.stdout(Stdio::piped())
			.spawn()
			.unwrap(),
	);
	let status = process.wait();
	let mut output = String::new();
	process.0.stdout.take().unwrap().read_to_string(&mut output).unwrap();
	assert!(status.success(), "{verb} {named}: {output}");
	serde_json::from_str(&output).unwrap()
}
fn direct_message(state: &std::path::Path, text: &str) -> String {
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
#[test]
fn managed_local_control_joins_and_replies_through_actual_custody() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-managed-journey-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
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
		let state = temp.0.join(nick);
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
