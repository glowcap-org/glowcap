//! Adversarial child processes make acquisition cancellation observable. They
//! implement no Rooms or CapTP behavior. They only wait at process boundaries.
use super::*;
use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};
pub(super) struct Fixture(pub(super) PathBuf);
impl Fixture {
	pub(super) fn new() -> Self {
		let mut random = [0u8; 16];
		rooms_platform::entropy::fill(&mut random).unwrap();
		let name: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
		let root = std::env::temp_dir().join(format!("rooms-web-startup-{name}"));
		fs::create_dir(&root).unwrap();
		fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
		Self(root)
	}
	pub(super) fn script(&self, name: &str, body: &str) -> PathBuf {
		let path = self.0.join(name);
		fs::write(&path, format!("#!/usr/bin/env python3\n{body}")).unwrap();
		fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
		path
	}
	fn assets(&self) -> PathBuf {
		let root = self.0.join("repo/apps/rooms/web");
		for path in [
			"ui/fonts",
			"../lib",
			"../../../bindings/ts",
			"../../../zig-out/wasm/rooms",
			"../../../ui/fonts",
		] {
			fs::create_dir_all(root.join(path)).unwrap();
		}
		fs::write(root.join("../../../ui/fonts/OFL.txt"), "fixture font license").unwrap();
		fs::write(root.join("ui/main.tsx"), "// a source input\n").unwrap();
		fs::write(root.join("ui/page.html"), "<!doctype html><title>Test</title>").unwrap();
		fs::write(root.join("deno.json"), "{}").unwrap();
		fs::write(root.join("deno.lock"), "{}").unwrap();
		fs::write(
			root.join("compiler.json"),
			r#"{"args":["fixture","--destination","{outdir}"],"inputs":["compiler-input.txt"]}"#,
		)
		.unwrap();
		fs::write(root.join("compiler-input.txt"), "fixture compiler input\n").unwrap();
		for name in ["rooms_browser.js", "rooms_browser.d.ts", "rooms_browser_bg.wasm"] {
			fs::write(root.join("../../../zig-out/wasm/rooms").join(name), b"\0asm\x01\0\0\0").unwrap();
		}
		root
	}
	async fn marker(&self, web: &mut Web) -> serde_json::Value {
		loop {
			assert!(
				web.child.try_wait().unwrap().is_none(),
				"web must wait at the acquisition boundary"
			);
			if let Ok(bytes) = fs::read(self.0.join("waiting"))
				&& let Ok(value) = serde_json::from_slice(&bytes)
			{
				return value;
			}
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	}
	pub(super) fn env(&self, command: &mut Command) {
		command.env("GLOWCAP_ROOMS_TEST_FIXTURE", &self.0);
		let mut paths = vec![self.0.clone()];
		paths.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap()));
		command.env("PATH", std::env::join_paths(paths).unwrap());
	}
}
impl Drop for Fixture {
	fn drop(&mut self) {
		if std::thread::panicking()
			&& let Ok(log) = fs::read_to_string(self.0.join("tor-output"))
		{
			eprintln!("Tor startup output: {log}");
		}
		fs::remove_dir_all(&self.0).unwrap();
	}
}
fn retired(value: &serde_json::Value) {
	let pid = value["pid"].as_i64().unwrap() as i32;
	assert_eq!(
		nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None),
		Err(nix::errno::Errno::ESRCH),
		"child must be reaped before web exits"
	);
	assert!(
		!Path::new(value["owned"].as_str().unwrap()).exists(),
		"owned temporary state must retire after its child"
	);
}
#[tokio::test(flavor = "current_thread")]
async fn web_retires_a_server_that_has_not_announced_readiness() {
	tokio::time::timeout(Duration::from_secs(45), async {
        let fixture = Fixture::new();
        let script = fixture.script("waiting-server", r#"import json, os, pathlib, signal, sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
pathlib.Path(os.environ['GLOWCAP_ROOMS_TEST_FIXTURE'], 'waiting').write_text(json.dumps({'pid': os.getpid(), 'owned': os.environ['GLOWCAP_ROOMS_STATE']}))
while True: signal.pause()
"#);
        let mut command = Web::command(0);
        command.arg(format!("--server={}", script.display())); fixture.env(&mut command);
        let mut web = Web::spawn(command);
        let waiting = fixture.marker(&mut web).await;
        tokio::time::timeout(Duration::from_secs(5), web.stop()).await.expect("cancel server startup promptly");
        retired(&waiting);
    }).await.expect("startup cancellation scenario deadline");
}
const COMPILER: &str = r#"import json, os, pathlib, signal, sys
root = pathlib.Path(os.environ['GLOWCAP_ROOMS_TEST_FIXTURE'])
assert sys.argv[1:3] == ['fixture', '--destination'], sys.argv
out = pathlib.Path(sys.argv[3])
if os.environ.get('GLOWCAP_ROOMS_TEST_FIRST_BUILD') == '1' and not (root / 'built').exists():
    out.mkdir(parents=True, exist_ok=True)
    (out / 'page.js').write_text('// complete fixture artifact\n')
    (out / 'ground.js').write_text('// complete fixture artifact\n')
    (root / 'built').write_text('1')
else:
    (root / 'waiting').write_text(json.dumps({'pid': os.getpid(), 'owned': str(out)}))
    while True: signal.pause()
"#;
#[tokio::test(flavor = "current_thread")]
async fn web_reaps_the_browser_compiler_during_startup_and_after_a_request_disconnects() {
	tokio::time::timeout(Duration::from_secs(45), async {
		for during_request in [false, true] {
			let fixture = Fixture::new();
			fixture.script("deno", COMPILER);
			let assets = fixture.assets();
			let mut command = Web::command(0);
			command.arg(format!("--assets={}", assets.display()));
			fixture.env(&mut command);
			if during_request {
				command.env("GLOWCAP_ROOMS_TEST_FIRST_BUILD", "1");
			}
			let mut web = Web::spawn(command);
			let mut request = None;
			if during_request {
				web.ready().await;
				fs::write(assets.join("compiler-input.txt"), "changed compiler input\n").unwrap();
				tokio::time::sleep(Duration::from_millis(1050)).await;
				let mut socket = TcpStream::connect(("127.0.0.1", web.port)).await.unwrap();
				socket
					.write_all(b"GET /page.js HTTP/1.1\r\nHost: localhost\r\n\r\n")
					.await
					.unwrap();
				request = Some(socket);
			}
			let waiting = fixture.marker(&mut web).await;
			drop(request);
			let stopped = tokio::time::timeout(Duration::from_secs(5), web.stop()).await;
			stopped.expect("cancel browser compilation promptly");
			retired(&waiting);
		}
	})
	.await
	.expect("compiler cancellation scenario deadline");
}

#[tokio::test(flavor = "current_thread")]
async fn web_cancels_an_attachment_probe_and_closes_its_runtime() {
	tokio::time::timeout(Duration::from_secs(45), async {
		let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
		let mut command = Web::command(0);
		command
			.arg(format!("--port={}", listener.local_addr().unwrap().port()))
			.arg("--trace=0");
		let mut web = Web::spawn(command);
		let (mut pending, _) = listener.accept().await.unwrap();
		tokio::time::timeout(Duration::from_secs(5), web.stop())
			.await
			.expect("cancel the unanswered directory probe promptly");
		let mut bytes = Vec::new();
		tokio::time::timeout(Duration::from_secs(3), pending.read_to_end(&mut bytes))
			.await
			.expect("probe runtime closes its stream")
			.unwrap();
	})
	.await
	.expect("attachment cancellation scenario deadline");
}

#[tokio::test(flavor = "current_thread")]
async fn web_cancels_private_tor_before_its_endpoints_appear() {
	tokio::time::timeout(Duration::from_secs(45), async {
		let fixture = Fixture::new();
		fixture.script(
			"tor",
			r#"import json, os, pathlib, signal, sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
owned = pathlib.Path(sys.argv[sys.argv.index('-f') + 1]).parent
pathlib.Path(os.environ['GLOWCAP_ROOMS_TEST_FIXTURE'], 'waiting').write_text(json.dumps({'pid': os.getpid(), 'owned': str(owned)}))
while True: signal.pause()
"#,
		);
		let mut command = Web::command(0);
		fixture.env(&mut command);
		command
			.arg("--transport=onion")
			.env_remove("GLOWCAP_ONION_SOCKS")
			.env_remove("GLOWCAP_ONION_CONTROL");
		let mut web = Web::spawn(command);
		let waiting = fixture.marker(&mut web).await;
		tokio::time::timeout(Duration::from_secs(5), web.stop())
			.await
			.expect("cancel private Tor startup promptly");
		retired(&waiting);
	})
	.await
	.expect("Tor cancellation scenario deadline");
}

#[tokio::test(flavor = "current_thread")]
#[ignore = "requires an installed Tor; the fixture disables public networking"]
async fn web_owns_a_real_private_tor_and_preserves_the_directory_service_key() {
	tokio::time::timeout(Duration::from_secs(45), async {
		let real_tor = std::env::split_paths(&std::env::var_os("PATH").unwrap())
			.map(|path| path.join("tor"))
			.find(|path| path.is_file())
			.expect("Tor on PATH");
		let fixture = Fixture::new();
		fixture.script(
			"tor",
			r#"import json, os, pathlib, sys
owned = pathlib.Path(sys.argv[sys.argv.index('-f') + 1]).parent
pathlib.Path(os.environ['GLOWCAP_ROOMS_TEST_FIXTURE'], 'waiting').write_text(json.dumps({'pid': os.getpid(), 'owned': str(owned)}))
tor = os.environ['GLOWCAP_ROOMS_TEST_REAL_TOR']
output = open(pathlib.Path(os.environ['GLOWCAP_ROOMS_TEST_FIXTURE'], 'tor-output'), 'w')
os.dup2(output.fileno(), 1)
os.dup2(output.fileno(), 2)
os.execv(tor, [tor] + sys.argv[1:] + ['--DisableNetwork', '1'])
"#,
		);
		let state = fixture.0.join("directory");
		let mut command = Web::command(0);
		fixture.env(&mut command);
		command
			.arg("--transport=onion")
			.arg(format!("--state={}", state.display()))
			.env_remove("GLOWCAP_ONION_SOCKS")
			.env_remove("GLOWCAP_ONION_CONTROL")
			.env("GLOWCAP_ROOMS_TEST_REAL_TOR", real_tor);
		let mut web = Web::spawn(command);
		web.ready().await;
		let locator = web.get("/locator").await;
		assert!(locator.starts_with("HTTP/1.1 200"), "{locator}");
		let locator = glowcap::parse_locator(locator.split_once("\r\n\r\n").unwrap().1.trim()).unwrap();
		assert_eq!(locator.transport, glowcap::TRANSPORT_ONION);
		web.reach().await;
		let key = fs::read(state.join("onion-key")).unwrap();
		assert!(!key.is_empty());
		let waiting = fixture.marker(&mut web).await;
		web.stop().await;
		retired(&waiting);
		assert_eq!(
			fs::read(state.join("onion-key")).unwrap(),
			key,
			"retirement preserves the durable onion identity"
		);
	})
	.await
	.expect("private Tor scenario deadline");
}
