#![cfg(feature = "processes")]
//! Exercise the executable's HTTP/upgrade boundary and retirement together.
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
}
#[path = "web_process/ice.rs"]
mod ice;
#[path = "web_process/preparation.rs"]
mod preparation;
#[path = "web_process/startup.rs"]
mod startup;
#[path = "web_process/supervision.rs"]
mod supervision;
impl Web {
	fn binary() -> std::path::PathBuf {
		std::env::var_os("GLOWCAP_ROOMS_WEB_TEST_BIN")
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-web").into())
			.into()
	}
	fn command(trace: u16) -> Command {
		let installed = std::env::var_os("GLOWCAP_ROOMS_WEB_TEST_BIN");
		let mut command = Command::new(Self::binary());
		let server = std::env::var_os("GLOWCAP_ROOMS_SERVER_TEST_BIN")
			.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-server").into());
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
		let assets = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../web");
		command
			.args(["0", "0", "--transport=tcp", "--trace"])
			.arg(format!("--trace-port={trace}"))
			.arg(format!("--assets={}", assets.display()))
			.arg(format!("--server={}", Path::new(&server).display()))
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
		Self { child, group, port: 0 }
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
			if let Some(url) = line.trim().strip_prefix("web ui           http://localhost:") {
				web.port = url.parse().unwrap();
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
		let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/web/native_relay.ts");
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
				assert_eq!(frame.reason, "Rooms relay could not complete the connection");
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
	for options in [
		vec!["--transport=tcp", "--announce-host=127.0.0.2"],
		vec!["--transport=iroh", "--reachability=direct"],
	] {
		tokio::time::timeout(Duration::from_secs(20), async {
			let mut command = Web::command(0);
			command.args(options);
			let mut web = Web::spawn(command);
			web.ready().await;
			web.reach().await;
			web.stop().await;
		})
		.await
		.expect("directory transport scenario deadline");
	}
}
