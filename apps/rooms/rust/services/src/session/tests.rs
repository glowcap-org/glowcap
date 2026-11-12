//! Production managed peer startup, TCP use, durable restart and retirement.
use super::*;
use rooms_testing::scratch::Scratch;
mod notices;
mod recovery;
use glowcap::PendingWork;
use std::{path::PathBuf, time::Duration};
fn tcp_config(state: PathBuf) -> Config {
	Config {
		admission: rooms_application::admission::Settings::defaults(4096, 8),
		state,
		transport: Transport::Tcp {
			profile: rooms_platform::serving::TcpProfile::Plain,
			bind: "127.0.0.1".into(),
			port: 0,
			announce: None,
		},
		checkpoint: None,
		readiness_file: None,
		relay_url: None,
		relay_alias_url: None,
		dial_transports: vec![transports::Dial::Tcp],
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
	assert_eq!(tcp.readiness_path(), PathBuf::from("place/use.sturdyref"));
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
	// `tcp` is the cleartext transport here as it is for `--transport`.
	use glowcap::tcp::Profiles;
	assert_eq!(needs.tcp().profiles, Profiles::NOISE_TCP.with(Profiles::TCP));
	use transports::Dial;
	let named = |dials: &[Dial]| transports::Needs::configured(dials, None, None, vec![]).unwrap();
	assert_eq!(named(&[Dial::NoiseTcp]).tcp().profiles, Profiles::NOISE_TCP);
	assert!(named(&[Dial::NoiseTcp]).dials(transports::Family::Tcp));
	assert_eq!(
		named(&[Dial::KeyedTcp]).tcp().profiles,
		Profiles::NOISE_TCP.with(Profiles::KEYED_TCP)
	);
	assert!(
		Config::parse(
			["--state=place".into(), "--dial-transports=keyed-tcp,noise-tcp".into()],
			|_| None
		)
		.is_ok()
	);
	let unknown = Config::parse(["--state=place".into(), "--dial-transports=webrtc,quic".into()], |_| {
		None
	})
	.err()
	.expect("quic is not a transport a session dials");
	assert_eq!(
		unknown.to_string(),
		"--dial-transports takes noise-tcp, iroh, onion, webrtc, keyed-tcp, tcp, not \"quic\""
	);
	let offered = format!("before restoration: {} (", Dial::ALL.map(Dial::name).join(", "));
	assert!(
		super::config::HELP.contains(&offered),
		"the help names every dial transport"
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
	let temp = Scratch::create("session-peer");
	let custody = rooms_platform::storage::session::Custody::acquire(&temp).unwrap();
	let readiness = super::readiness::Readiness::clear(temp.join("ready"), custody.directory().clone())
		.await
		.unwrap();
	drop(custody);
	assert!(rooms_platform::storage::session::Custody::acquire(&temp).is_err());
	readiness.publish("one complete publication").await.unwrap();
	readiness.remove().await.unwrap();
	assert!(rooms_platform::storage::session::Custody::acquire(&temp).is_err());
	drop(readiness);
	let _next = rooms_platform::storage::session::Custody::acquire(&temp).unwrap();
}

#[tokio::test]
async fn refused_startup_clears_stale_readiness_after_acquiring_custody() {
	rooms_testing::local_set::run(async {
		for external in [false, true] {
			let temp = Scratch::create("session-peer");
			let state = temp.join("state");
			std::fs::create_dir(&state).unwrap();
			let mut config = tcp_config(state.clone());
			if external {
				config.readiness_file = Some(temp.join("ready.sturdyref"));
			}
			let ready = config.readiness_path();
			let management = state.join("management.sturdyref");
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
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let temp = Scratch::create("session-peer");
		// The fixture session listens on plain tcp, so its caller opts in.
		let runtime = glowcap::Runtime::open(glowcap::RuntimeConfig::providers([glowcap::tcp::provider(
			glowcap::tcp::Config {
				profiles: glowcap::tcp::Profiles::TCP,
				..Default::default()
			},
		)]))
		.await
		.unwrap();
		let mut swiss = None;
		for restart in 0..2 {
			let running = start_session(temp.to_path_buf()).await;
			let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
			if let Some(prior) = &swiss {
				assert_eq!(&parsed.swissnum, prior);
			}
			swiss = Some(parsed.swissnum);
			assert_eq!(
				std::fs::read_to_string(temp.join("use.sturdyref")).unwrap().trim(),
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
			assert!(!temp.join("use.sturdyref").exists());
		}
		runtime.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}

#[tokio::test]
async fn a_sealed_session_dials_keyed_tcp_once_its_operator_names_it() {
	rooms_testing::local_set::run_within(Duration::from_secs(10), async {
		use glowcap::{BreakCause, BreakReason, ConnectOptions, Host, tcp};
		let sealed = Transport::Tcp {
			profile: rooms_platform::serving::TcpProfile::Noise,
			bind: "127.0.0.1".into(),
			port: 0,
			announce: None,
		};
		let other = Host::from_seed([64; 32]).unwrap();
		let options = tcp::ListenOptions {
			identity: tcp::ListenerIdentity::Host(other.clone()),
			..Default::default()
		};
		let keyed = tcp::keyed::listen("127.0.0.1", 0, options).await.unwrap();
		let locator = keyed.locator().unwrap();
		for (seed, named) in [(65, false), (66, true)] {
			let host = Host::from_seed([seed; 32]).unwrap();
			let names: Vec<_> = named.then_some(transports::Dial::KeyedTcp).into_iter().collect();
			let needs = transports::Needs::configured(&names, None, None, vec![]).unwrap();
			let mut keys = rooms_platform::serving::onion::KeyFile(None);
			let opened = transports::Transports::open(&host, &sealed, &needs, &mut keys, None)
				.await
				.unwrap();
			let runtime = opened.runtime();
			let (dialed, _) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), async {
				// Bounded, so a dial that was refused fails on its own assertion below.
				if named {
					let _ = tokio::time::timeout(Duration::from_secs(3), keyed.accept()).await;
				}
			});
			match dialed {
				Ok(_) => assert!(named, "a session dialed keyed-tcp its operator did not name"),
				Err(error) => {
					assert!(
						!named,
						"a session could not dial the keyed-tcp its operator named: {error}"
					);
					assert_eq!(error.cause(), BreakCause::local(BreakReason::TransportUnavailable));
				}
			}
			opened.close().await.unwrap();
		}
		keyed.close().await.unwrap();
		other.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}
