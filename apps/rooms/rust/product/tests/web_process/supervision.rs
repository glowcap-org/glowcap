//! Attachment borrows a running directory. Takeover acquires its kept state.
use super::*;
use std::path::PathBuf;

struct State(PathBuf);
impl State {
	fn new() -> Self {
		let mut entropy = [0u8; 16];
		rooms_platform::entropy::fill(&mut entropy).unwrap();
		let name: String = entropy.iter().map(|byte| format!("{byte:02x}")).collect();
		let path = std::env::temp_dir().join(format!("rooms-web-supervision-{name}"));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for State {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}

#[tokio::test(flavor = "current_thread")]
async fn web_attaches_by_local_address_and_takes_over_the_same_kept_directory() {
	tokio::time::timeout(Duration::from_secs(20), async {
		let state = State::new();
		let server = std::env::var_os("GLOWCAP_ROOMS_SERVER_TEST_BIN")
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-server").into());
		let mut command = Command::new(server);
		for (key, _) in std::env::vars_os() {
			if key.to_string_lossy().starts_with("GLOWCAP_ROOMS_") {
				command.env_remove(key);
			}
		}
		if std::env::var_os("GLOWCAP_ROOMS_SERVER_TEST_BIN").is_some() {
			command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
		}
		command.as_std_mut().process_group(0);
		command
			.args(["--transport=tcp", "--port=0", "--announce-host=127.0.0.2", "--operator"])
			.arg(format!("--state={}", state.0.display()))
			.env("GLOWCAP_ROOMS_READY_FORMAT", "json")
			.stdout(Stdio::piped())
			.stderr(Stdio::inherit())
			.kill_on_drop(true);
		let mut external = Web::spawn(command);
		let mut output = BufReader::new(external.child.stdout.take().unwrap()).lines();
		let ready = output.next_line().await.unwrap().unwrap();
		let ready: serde_json::Value =
			serde_json::from_str(ready.strip_prefix("ROOMS-SERVER-READY ").unwrap()).unwrap();
		let locator = ready["location"].as_str().unwrap();
		let port = ready["local_endpoint"]["port"].as_u64().unwrap() as u16;
		let operator = std::fs::read(state.0.join("operator")).unwrap();
		let identity = std::fs::read(state.0.join("rooms.json")).unwrap();
		let web_command = || {
			let mut command = Web::command(0);
			command
				.args(["--trace=0", "--operator", "--announce-host=127.0.0.2"])
				.arg(format!("--port={port}"))
				.arg(format!("--state={}", state.0.display()));
			command
		};
		let mut web = Web::spawn(web_command());
		web.ready().await;
		assert_same_endpoint(&web.status("locator").await, locator);
		web.reach().await;
		// Cross a periodic probe. The announced IP has no listener.
		tokio::time::sleep(Duration::from_millis(2200)).await;
		assert_same_endpoint(&web.status("locator").await, locator);
		web.stop().await;
		assert!(
			external.child.try_wait().unwrap().is_none(),
			"attachment does not own the external process"
		);
		let mut web = Web::spawn(web_command());
		web.ready().await;
		external.stop().await;
		// Only the supervisor can replace the now-reaped directory listener.
		loop {
			if TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
				let reply = web.get("/locator").await;
				if reply.starts_with("HTTP/1.1 200") {
					break;
				}
			}
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
		assert_same_endpoint(&web.status("locator").await, locator);
		web.reach().await;
		assert_eq!(std::fs::read(state.0.join("operator")).unwrap(), operator);
		assert_eq!(std::fs::read(state.0.join("rooms.json")).unwrap(), identity);
		web.stop().await;
	})
	.await
	.expect("external directory attachment and takeover deadline");
}

// Child readiness also carries profile hints. Attachment learns the public
// address from advertisedLocation; both must route to the exact same endpoint.
fn assert_same_endpoint(actual: &str, expected: &str) {
	let actual = glowcap::parse_locator(actual).unwrap();
	let expected = glowcap::parse_locator(expected).unwrap();
	assert_eq!(actual.transport, expected.transport);
	assert_eq!(actual.designator, expected.designator);
}
