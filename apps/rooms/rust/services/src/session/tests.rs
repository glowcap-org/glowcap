//! Production managed peer startup, TCP use, durable restart and retirement.
use super::*;
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
		state,
		transport: Transport::Tcp {
			bind: "127.0.0.1".into(),
			port: 0,
			announce: None,
		},
		checkpoint: None,
		readiness_file: None,
		relay_url: None,
		dial_transports: vec!["tcp".into()],
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
		|link| {
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
