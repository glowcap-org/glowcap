//! Exercise the executable's HTTP/upgrade boundary and retirement together.
#![cfg(test)]
use futures_util::{SinkExt, StreamExt};
use std::{os::unix::process::CommandExt, path::Path, process::Stdio, time::Duration};
use tokio::{
	io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
	net::TcpStream,
	process::{Child, Command},
};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

struct Web {
	child: Child,
	group: i32,
	port: u16,
	shared: Vec<String>,
	/// The banner's `open the ...` links, as printed.
	links: Vec<String>,
}
/// A launch's `--name=value` options, one value per name.
type Options = std::collections::BTreeMap<&'static str, String>;
#[path = "web_process/ice.rs"]
mod ice;
#[path = "web_process/preparation.rs"]
mod preparation;
#[path = "web_process/startup.rs"]
mod startup;
#[path = "web_process/supervision.rs"]
mod supervision;
#[path = "web_process/trace.rs"]
mod trace;
impl Web {
	fn binary() -> std::path::PathBuf {
		std::env::var_os("GLOWCAP_ROOMS_WEB_TEST_BIN")
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-web").into())
			.into()
	}
	/// The options every launch starts from. rooms-web reads each option once,
	/// so a test that needs another value replaces it here before the command
	/// is built.
	fn options(trace: u16) -> Options {
		let server = std::env::var_os("GLOWCAP_ROOMS_SERVER_TEST_BIN")
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-server").into());
		Options::from([
			("http-port", "0".to_owned()),
			("port", "0".to_owned()),
			("transport", "tcp".to_owned()),
			("trace", "1".to_owned()),
			("trace-port", trace.to_string()),
			("server", Path::new(&server).display().to_string()),
		])
	}
	fn command(trace: u16) -> Command {
		Self::command_with(Self::options(trace))
	}
	/// A launch serving the checkout's browser sources, unless `options` names
	/// other assets.
	fn command_with(mut options: Options) -> Command {
		options.entry("assets").or_insert_with(|| {
			Path::new(env!("CARGO_MANIFEST_DIR"))
				.join("../../web")
				.display()
				.to_string()
		});
		Self::endpoint_command_with(options)
	}
	fn endpoint_command(trace: u16) -> Command {
		Self::endpoint_command_with(Self::options(trace))
	}
	fn endpoint_command_with(options: Options) -> Command {
		let installed = std::env::var_os("GLOWCAP_ROOMS_WEB_TEST_BIN");
		let mut command = Command::new(Self::binary());
		if installed.is_some() {
			command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
		}
		command.as_std_mut().process_group(0);
		for (key, _) in std::env::vars_os() {
			if key.to_string_lossy().starts_with("GLOWCAP_ROOMS_")
				|| key.to_string_lossy().starts_with("GLOWCAP_RELAY_")
			{
				command.env_remove(key);
			}
		}
		for (key, value) in &options {
			command.arg(format!("--{key}={value}"));
		}
		command
			.env("GLOWCAP_RELAY_MAX_SESSIONS", "1")
			.env("GLOWCAP_RELAY_MAX_REGISTRATIONS", "2")
			.env("GLOWCAP_RELAY_MAX_REGISTRATIONS_PER_IDENTITY", "2")
			.stdout(Stdio::piped())
			.stderr(Stdio::inherit())
			.kill_on_drop(true);
		command
	}
	fn spawn(mut command: Command) -> Self {
		let child = command.spawn().unwrap();
		let group = child.id().unwrap() as i32;
		Self {
			child,
			group,
			port: 0,
			shared: Vec::new(),
			links: Vec::new(),
		}
	}
	async fn start(trace: u16) -> Self {
		let mut web = Self::spawn(Self::command(trace));
		web.ready().await;
		web
	}
	async fn ready(&mut self) {
		let web = self;
		let mut lines = BufReader::new(web.child.stdout.take().unwrap()).lines();
		loop {
			let line = lines.next_line().await.unwrap().expect("web readiness before EOF");
			if line.starts_with("ROOMS-SESSION-") {
				web.shared.push(line.clone());
			}
			if let Some(link) = line.strip_prefix("  open the ") {
				web.links.push(link.to_owned());
			}
			if let Some(port) = line.strip_prefix("ROOMS-WEB-LISTENING ") {
				web.port = port.parse().unwrap();
			}
			if line == "rooms: ready" {
				break;
			}
		}
		assert_ne!(web.port, 0);
	}
	fn url(&self, path: &str) -> String {
		format!("ws://127.0.0.1:{}{path}", self.port)
	}
	async fn status(&self, field: &str) -> String {
		let mut command = Command::new(Self::binary());
		command
			.arg(format!("--{field}=http://127.0.0.1:{}", self.port))
			.current_dir(std::env::temp_dir())
			.kill_on_drop(true);
		if std::env::var_os("GLOWCAP_ROOMS_WEB_TEST_BIN").is_some() {
			command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
		}
		let output = command.output().await.unwrap();
		assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
		String::from_utf8(output.stdout).unwrap().trim().into()
	}
	async fn reach(&self) {
		let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/web/wasm_relay_peer.ts");
		let mut peer = Command::new("deno")
			.args(["run", "--allow-read", "--allow-net", "--allow-env"])
			.arg(script)
			.arg(format!("http://127.0.0.1:{}", self.port))
			.stdout(Stdio::inherit())
			.stderr(Stdio::inherit())
			.kill_on_drop(true)
			.spawn()
			.unwrap();
		let result = tokio::time::timeout(Duration::from_secs(10), peer.wait()).await;
		if result.is_err() {
			peer.kill().await.unwrap();
		}
		assert!(
			result.expect("Wasm relay peer deadline").unwrap().success(),
			"Wasm peer reaches the real directory through the host relay"
		);
	}
	async fn get(&self, path: &str) -> String {
		self.request("GET", path, "").await
	}
	async fn request(&self, method: &str, path: &str, headers: &str) -> String {
		let mut socket = TcpStream::connect(("127.0.0.1", self.port)).await.unwrap();
		socket
			.write_all(
				format!(
					"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n{headers}\r\n",
					self.port
				)
				.as_bytes(),
			)
			.await
			.unwrap();
		let mut response = String::new();
		socket.read_to_string(&mut response).await.unwrap();
		response
	}
	async fn stop(&mut self) {
		nix::sys::signal::kill(
			nix::unistd::Pid::from_raw(self.group),
			nix::sys::signal::Signal::SIGTERM,
		)
		.unwrap();
		assert!(
			self.child.wait().await.unwrap().success(),
			"web retires every owned worker"
		);
	}
}

#[tokio::test(flavor = "current_thread")]
async fn web_shared_session_announces_independent_links_and_releases_custody() {
	tokio::time::timeout(Duration::from_secs(20), async {
		let state = rooms_testing::scratch::Scratch::create("web-session");
		let mut previous = None;
		for _ in 0..2 {
			let mut command = Web::endpoint_command(0);
			command
				.arg("--no-browser-assets")
				.arg(format!("--session-state={}", state.display()));
			command.env("GLOWCAP_ROOMS_SESSION_REACHABILITY", "discovery");
			let mut web = Web::spawn(command);
			web.ready().await;
			let use_link = std::fs::read_to_string(state.join("workspace.sturdyref")).unwrap();
			let management = std::fs::read_to_string(state.join("control.sturdyref")).unwrap();
			assert_eq!(
				web.shared,
				[
					format!("ROOMS-SESSION-LISTENING {}", use_link.trim()),
					format!("ROOMS-SESSION-MANAGEMENT {}", management.trim())
				]
			);
			assert_ne!(use_link, management);
			if let Some(previous) = previous {
				assert_eq!(previous, (use_link.clone(), management.clone()));
			}
			previous = Some((use_link, management));
			assert!(web.get("/locator").await.starts_with("HTTP/1.1 200"));
			web.stop().await;
			assert!(!state.join("workspace.sturdyref").exists());
			assert!(!state.join("control.sturdyref").exists());
		}
	})
	.await
	.expect("shared session lifecycle deadline");
}

// The session's relay door registers at this front's relay, which must be
// serving by then, and the page is offered the session through it.
#[tokio::test(flavor = "current_thread")]
async fn web_shared_session_opens_a_relay_door_at_this_servers_relay_and_a_tcp_door_it_forwards_to() {
	tokio::time::timeout(Duration::from_secs(30), async {
		let state = rooms_testing::scratch::Scratch::create("web-session-doors");
		let mut command = Web::endpoint_command(0);
		command
			.arg("--no-browser-assets")
			.arg(format!("--session-state={}", state.display()))
			.arg("--session-transport=noise-relay");
		let mut web = Web::spawn(command);
		web.ready().await;
		let link = web.shared[0]
			.strip_prefix("ROOMS-SESSION-LISTENING ")
			.unwrap()
			.to_owned();
		let door = glowcap::parse_sturdyref(&link, glowcap::CaptpVersion::V1_0)
			.unwrap()
			.locator;
		assert_eq!(door.transport, glowcap::TRANSPORT_NOISE_RELAY);
		assert_eq!(
			door.hints.get("rendezvous-relay"),
			Some(&glowcap::HintValue::String(format!(
				"ws://127.0.0.1:{}/relay",
				web.port
			))),
			"the session's relay door did not name this server's relay"
		);
		assert_offered(&web, &link);
		web.stop().await;
		// A TCP door is forwarded to at the endpoint its link names: the relay
		// reads the target before it asks for an upgrade, so a plain request
		// from this server's own page is refused for the door it does not
		// forward to and asked to upgrade for the one it does.
		let mut command = Web::endpoint_command(0);
		command
			.arg("--no-browser-assets")
			.arg(format!("--session-state={}", state.display()))
			.arg("--session-transport=tcp");
		let mut web = Web::spawn(command);
		web.ready().await;
		let link = web.shared[0]
			.strip_prefix("ROOMS-SESSION-LISTENING ")
			.unwrap()
			.to_owned();
		let door = glowcap::parse_sturdyref(&link, glowcap::CaptpVersion::V1_0)
			.unwrap()
			.locator;
		assert_eq!(door.transport, glowcap::TRANSPORT_TCP);
		assert_offered(&web, &link);
		let origin = format!("Origin: http://127.0.0.1:{}\r\n", web.port);
		let forwarded = web
			.request("GET", &format!("/relay?target={}", door.designator), &origin)
			.await;
		assert!(forwarded.starts_with("HTTP/1.1 400"), "{forwarded}");
		let refused = web.request("GET", "/relay?target=127.0.0.1:1", &origin).await;
		assert!(refused.starts_with("HTTP/1.1 403"), "{refused}");
		web.stop().await;
	})
	.await
	.expect("shared session doors deadline");
}

/// The banner offers the page the session through a door a browser can open:
/// the link that opens the page with this server also attaches the session.
fn assert_offered(web: &Web, session: &str) {
	let attach = url::form_urlencoded::Serializer::new(String::new())
		.append_pair("attach", session)
		.finish();
	let offered = web.links.iter().any(|link| {
		link.starts_with("session https://glowcap.org/rooms/app/?server=") && link.ends_with(&format!("#{attach}"))
	});
	assert!(offered, "the banner offers no page the session: {:?}", web.links);
}

#[tokio::test(flavor = "current_thread")]
async fn web_can_serve_rooms_endpoints_without_loading_browser_assets() {
	tokio::time::timeout(Duration::from_secs(20), async {
		let mut command = Web::endpoint_command(0);
		command.arg("--no-browser-assets");
		let mut web = Web::spawn(command);
		web.ready().await;
		assert!(web.get("/locator").await.starts_with("HTTP/1.1 200"));
		let page = web.get("/").await;
		assert!(page.starts_with("HTTP/1.1 404"), "{page}");
		assert!(page.ends_with("rooms: browser assets disabled\n"), "{page}");
		web.stop().await;
	})
	.await
	.expect("endpoint-only web service deadline");
}
impl Drop for Web {
	fn drop(&mut self) {
		let _ = nix::sys::signal::killpg(
			nix::unistd::Pid::from_raw(self.group),
			nix::sys::signal::Signal::SIGKILL,
		);
		let _ = self.child.start_kill();
	}
}
fn refused(error: tokio_tungstenite::tungstenite::Error, code: u16) {
	match error {
		tokio_tungstenite::tungstenite::Error::Http(response) => assert_eq!(response.status().as_u16(), code),
		other => panic!("HTTP refusal expected: {other}"),
	}
}
#[tokio::test(flavor = "current_thread")]
async fn web_rendezvous_admission_early_bytes_and_shutdown() {
	tokio::time::timeout(Duration::from_secs(45), async {
		let mut web = Web::start(0).await;
		let timeline = web.get("/trace").await;
		assert!(timeline.starts_with("HTTP/1.1 200"), "{timeline}");
		let trace: u16 = timeline.split_once("\r\n\r\n").unwrap().1.trim().parse().unwrap();
		assert_ne!(trace, 0, "the supervisor reports the bound ephemeral timeline port");
		eprintln!("web ready");
		let locator = web.get("/locator").await;
		assert!(locator.starts_with("HTTP/1.1 200"), "{locator}");
		assert_eq!(web.status("check-ready").await, "rooms: ready");
		assert_eq!(
			web.status("locator").await,
			locator.split_once("\r\n\r\n").unwrap().1.trim()
		);
		let version = web.get("/ui-version").await;
		assert_eq!(
			web.status("ui-version").await,
			version.split_once("\r\n\r\n").unwrap().1.trim()
		);
		let ice = web.get("/ice").await;
		assert!(ice.contains("stun:stun.cloudflare.com:3478"), "{ice}");
		eprintln!("HTTP contracts answered");
		let page = web.get("/").await;
		let (headers, body) = page.split_once("\r\n\r\n").unwrap();
		assert!(headers.contains("content-security-policy:"), "{headers}");
		assert_eq!(
			headers.matches("'sha256-").count(),
			2,
			"both inline scripts have exact CSP hashes"
		);
		let etag = headers.lines().find_map(|line| line.strip_prefix("etag: ")).unwrap();
		let cached = web.request("GET", "/", &format!("If-None-Match: {etag}\r\n")).await;
		assert!(cached.starts_with("HTTP/1.1 304"), "{cached}");
		let head = web.request("HEAD", "/", "").await;
		assert!(head.contains(&format!("content-length: {}", body.len())), "{head}");
		assert!(head.ends_with("\r\n\r\n"));
		use sha2::Digest;
		let application = std::fs::read(
			Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../zig-out/wasm/rooms/rooms_browser_bg.wasm"),
		)
		.unwrap();
		let route = format!(
			"/rooms-{}.wasm",
			rooms_application::fields::lower_hex(&sha2::Sha256::digest(application))
		);
		let wasm = web.request("HEAD", &route, "").await;
		assert!(wasm.starts_with("HTTP/1.1 200"), "{wasm}");
		assert!(wasm.contains("content-type: application/wasm"), "{wasm}");
		let retired = web.request("HEAD", "/glowcap_host.wasm", "").await;
		assert!(retired.starts_with("HTTP/1.1 404"), "{retired}");
		for path in ["/trace?cap=0000", "/publish?cap=0000"] {
			let (mut refused_socket, _) = loop {
				match tokio_tungstenite::connect_async(web.url(path)).await {
					Ok(pair) => break pair,
					Err(error) => {
						refused(error, 503);
						tokio::time::sleep(Duration::from_millis(10)).await;
					}
				}
			};
			match refused_socket.next().await.unwrap().unwrap() {
				Message::Close(Some(frame)) => assert_eq!(u16::from(frame.code), 4403),
				other => panic!("timeline refusal code must survive proxying: {other:?}"),
			}
			let _ = refused_socket.flush().await;
		}

		let identity = "ab".repeat(32);
		let register = web.url(&format!("/register?id={identity}"));
		let dial = web.url(&format!("/relay?rendezvous={identity}"));
		let (mut absent, _) = tokio_tungstenite::connect_async(&dial).await.unwrap();
		match absent.next().await.unwrap().unwrap() {
			Message::Close(Some(frame)) => {
				assert_eq!(u16::from(frame.code), 1011);
				assert_eq!(frame.reason, "rendezvous peer is not registered");
			}
			other => panic!("failed dial must close with a reason: {other:?}"),
		}
		let _ = absent.flush().await;
		let (mut first, _) = tokio_tungstenite::connect_async(&register).await.unwrap();
		first
			.send(Message::Binary(b"early hello".to_vec().into()))
			.await
			.unwrap();
		let (mut second, _) = tokio_tungstenite::connect_async(&register).await.unwrap();
		second
			.send(Message::Binary(b"second hello".to_vec().into()))
			.await
			.unwrap();
		refused(tokio_tungstenite::connect_async(&register).await.unwrap_err(), 503);
		let mut request = dial.clone().into_client_request().unwrap();
		request
			.headers_mut()
			.insert("origin", "https://another-room.example".parse().unwrap());
		eprintln!("registrations held");
		let (mut caller, _) = tokio_tungstenite::connect_async(request).await.unwrap();
		eprintln!("caller upgraded");
		assert_eq!(caller.next().await.unwrap().unwrap().into_data(), &b"early hello"[..]);
		eprintln!("early bytes received");
		caller.send(Message::Binary(b"reply".to_vec().into())).await.unwrap();
		assert_eq!(first.next().await.unwrap().unwrap().into_data(), &b"reply"[..]);
		// Refusing this dial must leave the second registration intact.
		refused(tokio_tungstenite::connect_async(&dial).await.unwrap_err(), 503);
		eprintln!("capacity refusal preserved registration");
		caller.close(None).await.unwrap();
		let _ = first.next().await;
		eprintln!("first pair closed");
		let (mut next, _) = loop {
			match tokio_tungstenite::connect_async(&dial).await {
				Ok(pair) => break pair,
				Err(error) => {
					refused(error, 503);
					tokio::time::sleep(Duration::from_millis(10)).await;
				}
			}
		};
		assert_eq!(next.next().await.unwrap().unwrap().into_data(), &b"second hello"[..]);
		// Shutdown includes a live pair and a replenished held registration.
		let (_held, _) = tokio_tungstenite::connect_async(&register).await.unwrap();
		eprintln!("stopping web with held sockets");
		web.stop().await;
		assert!(TcpStream::connect(("127.0.0.1", web.port)).await.is_err());
		assert!(TcpStream::connect(("127.0.0.1", trace)).await.is_err());
	})
	.await
	.expect("web process scenario completes");
}

#[tokio::test(flavor = "current_thread")]
async fn web_relays_the_directory_through_tcp_and_iroh() {
	for (transport, option) in [("tcp", "--announce-host=127.0.0.2"), ("iroh", "--reachability=direct")] {
		tokio::time::timeout(Duration::from_secs(20), async {
			let mut options = Web::options(0);
			options.insert("transport", transport.to_owned());
			let mut command = Web::command_with(options);
			command.arg(option);
			let mut web = Web::spawn(command);
			web.ready().await;
			web.reach().await;
			web.stop().await;
		})
		.await
		.expect("directory transport scenario deadline");
	}
}
