use super::*;
use glowcap::{ConnectOptions, Runtime, RuntimeConfig, iroh, tcp};
use rooms_application::archive::{Body, ConversationKind, Coordinates, Filter, LineState, Record, shares::Share};
use rooms_glowcap::client::{Client, archive::Archive as ClientArchive};
use rooms_platform::HostPlatform;
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
			"rooms-archive-peer-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}
#[tokio::test]
async fn archive_peer_tcp_identity_archive_shares_restart_and_active_shutdown() {
	check(false).await;
}
#[tokio::test]
async fn archive_peer_direct_iroh_identity_archive_shares_restart_and_active_shutdown() {
	check(true).await;
}
async fn check(iroh: bool) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario(iroh))
				.await
				.expect("host archive service deadline");
		})
		.await;
}
async fn scenario(use_iroh: bool) {
	let temp = Temp::new();
	let identity = rooms_application::archive::identity::Identity::new([202; 32], [17; 16]);
	std::fs::write(temp.0.join("peer.json"), identity.encode()).unwrap();
	let transport = || {
		if use_iroh {
			Transport::Iroh(iroh::Reachability::Direct)
		} else {
			Transport::Tcp {
				bind: "127.0.0.1".into(),
				port: 0,
				announce: None,
			}
		}
	};
	let provider = if use_iroh {
		iroh::provider(iroh::Config::new(iroh::Reachability::Direct))
	} else {
		tcp::provider(Default::default())
	};
	let runtime = Runtime::open(RuntimeConfig::providers([provider])).await.unwrap();
	let mut previous_swiss = None;
	let spec = Share::new(
		"12345678-1234-4234-8234-123456789abc".into(),
		"Garden".into(),
		Filter::default(),
	)
	.unwrap();
	for restart in 0..2 {
		let (stop, stopped) = tokio::sync::oneshot::channel();
		let (ready, link) = tokio::sync::oneshot::channel();
		let config = Config {
			state: temp.0.clone(),
			transport: transport(),
		};
		let task = tokio::task::spawn_local(run(
			config,
			async {
				let _ = stopped.await;
			},
			|link| {
				ready.send(link.to_owned()).unwrap();
			},
			Rc::new(|_| {}),
		));
		let link = link.await.unwrap();
		let parsed = glowcap::parse_sturdyref(&link, glowcap::CaptpVersion::V1_0).unwrap();
		if let Some(swiss) = &previous_swiss {
			assert_eq!(&parsed.swissnum, swiss);
		}
		previous_swiss = Some(parsed.swissnum.clone());
		let session = runtime
			.connect(&parsed.locator, ConnectOptions::default())
			.await
			.unwrap();
		let reference = session.enliven(&link).await.unwrap();
		let client = Client::new(session, HostPlatform);
		let archive = ClientArchive::new(client.clone(), reference);
		if restart == 0 {
			let record = Record::new(
				Coordinates {
					source: "source".into(),
					generation: "generation".into(),
					id: "one".into(),
				},
				"directory".into(),
				Body::Line {
					conversation_kind: ConversationKind::Room,
					conversation: "garden".into(),
					from: "alice".into(),
					text: "retained".into(),
					mine: false,
					at: 1,
					order: 1,
					state: LineState::Present,
					previews: Default::default(),
					attachments: vec![],
				},
			)
			.unwrap();
			assert_eq!(archive.put(&record).await.unwrap(), 1);
			archive.share(&spec).await.unwrap();
		} else {
			assert_eq!(archive.read_all(&Filter::default()).await.unwrap().len(), 1);
			assert_eq!(archive.shares().await.unwrap()[0].share, spec);
		}
		assert!(FileArchive::open(&temp.0, Options::default()).await.is_err());
		stop.send(()).unwrap();
		task.await.unwrap().unwrap();
		assert!(archive.read_all(&Filter::default()).await.is_err());
		// The peer was stopped first, so the dialer's transport may already be
		// gone by the time it says goodbye; that is the peer leaving, not a
		// failure to close.
		if let Err(error) = client.session().close(PendingWork::Cancel).await {
			assert!(
				rooms_platform::serving::left(&error),
				"closing the dialer failed: {error}"
			);
		}
	}
	runtime.close(PendingWork::Cancel).await.unwrap();
	assert_eq!(std::fs::read(temp.0.join("peer.json")).unwrap(), identity.encode());
}
#[test]
fn archive_peer_configuration_requires_state_and_resolves_explicit_transport_options() {
	let parse = |args: &[&str]| Config::parse(args.iter().map(|s| s.to_string()), |_| None);
	assert!(parse(&[]).is_err());
	assert!(parse(&["--help"]).unwrap().is_none());
	assert!(matches!(
		parse(&["--state=place"]).unwrap().unwrap().transport,
		Transport::Iroh(iroh::Reachability::Discovery)
	));
	for args in [
		vec!["--state=place", "--transport=no"],
		vec!["--state=place", "--state=again"],
		vec!["--state=place", "--wrong=x"],
		vec!["--state=place", "--transport=tcp", "--bind=0.0.0.0"],
		vec!["--state=place", "--transport=tcp", "--port=65536"],
	] {
		assert!(parse(&args).is_err());
	}
	let config = Config::parse(["--port=7".into()], |key| match key {
		"GLOWCAP_ARCHIVE_STATE" => Some(" place ".into()),
		"GLOWCAP_ARCHIVE_TRANSPORT" => Some("tcp".into()),
		"GLOWCAP_ARCHIVE_PORT" => Some("8".into()),
		_ => None,
	})
	.unwrap()
	.unwrap();
	assert_eq!(config.state, PathBuf::from("place"));
	assert!(matches!(config.transport, Transport::Tcp { port: 7, .. }));
}
