//! Production managed peer startup, TCP use, durable restart and retirement.
use super::*;
mod notices;
mod recovery;
use glowcap::PendingWork;
use std::{
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
	time::Duration,
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
	fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"rooms-session-peer-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}
fn tcp_config(state: PathBuf) -> Config {
	Config {
		admission: rooms_application::admission::Settings::defaults(4096, 8),
		state,
		transport: Transport::Tcp {
			bind: "127.0.0.1".into(),
			port: 0,
			announce: None,
		},
		checkpoint: None,
		readiness_file: None,
		relay_url: None,
		relay_alias_url: None,
		dial_transports: vec!["tcp".into()],
		ice_servers: vec![],
	}
}
struct Running {
	stop: tokio::sync::oneshot::Sender<()>,
	task: tokio::task::JoinHandle<Result<(), Error>>,
	link: String,
}
async fn start_session(state: PathBuf) -> Running {
	let (stop, stopped) = tokio::sync::oneshot::channel();
	let (ready, link) = tokio::sync::oneshot::channel();
	let mut task = tokio::task::spawn_local(run(
		tcp_config(state),
		async {
			let _ = stopped.await;
		},
		|link, _management| {
			ready.send(link.to_owned()).unwrap();
		},
		std::rc::Rc::new(|_| {}),
	));
	let link = tokio::select! {
		link = link => match link {
			Ok(link) => link,
			Err(_) => panic!("session startup failed: {:?}", task.await.unwrap()),
		},
		result = &mut task => panic!("session startup failed: {:?}", result.unwrap()),
	};
	Running { stop, task, link }
}
async fn stop_session(running: Running, session: glowcap::Session) {
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
}
#[test]
fn session_peer_configuration_requires_state_and_resolves_explicit_transport_options() {
	let parse = |args: &[&str]| Config::parse(args.iter().map(|s| s.to_string()), |_| None);
	assert!(parse(&[]).is_err());
	assert!(parse(&["--help"]).unwrap().is_none());
	assert!(matches!(
		parse(&["--state=place"]).unwrap().unwrap().transport,
		Transport::Iroh(glowcap::iroh::Reachability::Discovery)
	));
	let tcp = parse(&["--state=place", "--transport=tcp", "--port=9"])
		.unwrap()
		.unwrap();
	assert!(matches!(tcp.transport, Transport::Tcp { port: 9, .. }));
	assert_eq!(tcp.readiness_path(), PathBuf::from("place/workspace.sturdyref"));
	assert!(parse(&["--state=place", "--transport=no"]).is_err());
	assert!(parse(&["--state=place", "--state=again"]).is_err());
}

#[test]
fn session_relay_alias_requires_a_configured_registry_and_resolves_environment() {
	let config = Config::parse(["--state=place".into()], |key| match key {
		"GLOWCAP_ROOMS_SESSION_RELAY_URL" => Some("ws://directory:8080/relay".into()),
		"GLOWCAP_ROOMS_SESSION_RELAY_ALIAS_URL" => Some("wss://rooms.example/relay".into()),
		_ => None,
	})
	.unwrap()
	.unwrap();
	assert_eq!(config.relay_alias_url.as_deref(), Some("wss://rooms.example/relay"));
	assert!(transports::Needs::configured(&[], config.relay_url, config.relay_alias_url, vec![]).is_ok());
	assert!(transports::Needs::configured(&[], None, Some("wss://rooms.example/relay".into()), vec![]).is_err());
	let webrtc = Config::parse(
		[
			"--state=place".into(),
			"--dial-transports=tcp,webrtc".into(),
			"--ice-servers=".into(),
		],
		|_| None,
	)
	.unwrap()
	.unwrap();
	assert!(webrtc.ice_servers.is_empty());
	let needs = transports::Needs::configured(&webrtc.dial_transports, None, None, webrtc.ice_servers).unwrap();
	assert!(needs.dials(transports::Family::Webrtc));
	assert!(!needs.dials(transports::Family::Relay));
	assert!(
		Config::parse(["--state=place".into(), "--dial-transports=webrtc,quic".into()], |_| {
			None
		})
		.is_err()
	);
	assert!(
		Config::parse(
			["--state=place".into(), "--ice-servers=turn:relay.example".into()],
			|_| None
		)
		.is_err()
	);
}

#[tokio::test]
async fn readiness_retains_session_custody_until_its_owner_retires() {
	let temp = Temp::new();
	let custody = rooms_platform::storage::session::Custody::acquire(&temp.0).unwrap();
	let readiness = super::readiness::Readiness::clear(temp.0.join("ready"), custody.directory().clone())
		.await
		.unwrap();
	drop(custody);
	assert!(rooms_platform::storage::session::Custody::acquire(&temp.0).is_err());
	readiness.publish("one complete publication").await.unwrap();
	readiness.remove().await.unwrap();
	assert!(rooms_platform::storage::session::Custody::acquire(&temp.0).is_err());
	drop(readiness);
	let _next = rooms_platform::storage::session::Custody::acquire(&temp.0).unwrap();
}

#[tokio::test]
async fn refused_startup_clears_stale_readiness_after_acquiring_custody() {
	tokio::task::LocalSet::new()
		.run_until(async {
			for external in [false, true] {
				let temp = Temp::new();
				let state = temp.0.join("state");
				std::fs::create_dir(&state).unwrap();
				let mut config = tcp_config(state.clone());
				if external {
					config.readiness_file = Some(temp.0.join("ready.sturdyref"));
				}
				let ready = config.readiness_path();
				let management = state.join("control.sturdyref");
				std::fs::write(&ready, "stale use").unwrap();
				std::fs::write(&management, "stale management").unwrap();
				std::fs::write(state.join("rooms-bootstrap"), "invalid metadata").unwrap();
				assert!(Peer::open(config, std::rc::Rc::new(|_| {})).await.is_err());
				assert!(!ready.exists(), "refused startup advertised stale use");
				assert!(!management.exists(), "refused startup advertised stale management");
				assert_eq!(
					std::fs::read(state.join("rooms-bootstrap")).unwrap(),
					b"invalid metadata"
				);
				let _custody = rooms_platform::storage::session::Custody::acquire(&state).unwrap();
			}
		})
		.await;
}

#[tokio::test]
async fn managed_peer_tcp_use_and_restart_preserve_durable_identity() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), async {
				let temp = Temp::new();
				let runtime = glowcap::Runtime::open(glowcap::RuntimeConfig::providers([glowcap::tcp::provider(
					Default::default(),
				)]))
				.await
				.unwrap();
				let mut swiss = None;
				for restart in 0..2 {
					let running = start_session(temp.0.clone()).await;
					let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
					if let Some(prior) = &swiss {
						assert_eq!(&parsed.swissnum, prior);
					}
					swiss = Some(parsed.swissnum);
					assert_eq!(
						std::fs::read_to_string(temp.0.join("workspace.sturdyref"))
							.unwrap()
							.trim(),
						running.link
					);
					let session = runtime.connect(&parsed.locator, Default::default()).await.unwrap();
					let reference = session.enliven(&running.link).await.unwrap();
					let workspace = rooms_glowcap::client::workspace::Workspace::new(
						rooms_glowcap::client::Client::new(session.borrowed(), rooms_platform::HostPlatform),
						reference,
					);
					let snapshot = workspace.snapshot().await.unwrap();
					if restart == 0 {
						let command = workspace
							.prepare_command("standing", snapshot.revision, "setStanding", &["away".into()])
							.await
							.unwrap();
						assert_eq!(
							command.submit().await.unwrap(),
							rooms_glowcap::client::workspace::EffectStatus::Committed
						);
					} else {
						assert_eq!(snapshot.intent.standing.text().as_str(), Some("away"));
					}
					drop(workspace);
					stop_session(running, session).await;
					assert!(!temp.0.join("workspace.sturdyref").exists());
				}
				runtime.close(PendingWork::Cancel).await.unwrap();
			})
			.await
			.expect("managed peer startup/restart deadline");
		})
		.await;
}
