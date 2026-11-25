//! A call through an attached session that misses its deadline says the link
//! is lost only when the session misses one more request too. A reader that
//! waits on another peer, such as a room host, while the session still answers
//! says only that its request timed out. A call whose connection closes under
//! it names the session unreachable, and a retired workspace leaves no live
//! session for the next dial to reuse, even when its close outlasts the first
//! retire's bound.
use super::HostPlatform;
use glowcap::{ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::{content::session::custody, failure::FailureCode};
use rooms_glowcap::client::{Error, access::Control, workspace::Workspace};
use rooms_testing::{
	deadline::{Miss, Scripted},
	write_gate::{Gate, Stream},
};
use std::{num::NonZeroU64, rc::Rc, time::Duration};

/// Read the history through an attached session whose bounded waits, numbered
/// from zero, miss from wait 1 up to but not including `last`. Wait 0 asks for
/// the history reader, wait 1 is the reader's history call, and wait 2 is the
/// probe.
async fn history_missing(last: usize) -> Error {
	let host = glowcap::Host::from_seed([225; 32]).unwrap();
	let reader = host.spawn(|_, _| Ok(glowcap::Argument::Void)).unwrap();
	let workspace = host
		.spawn(move |verb, _| match verb {
			Some("history-reader") => Ok(reader.clone().into()),
			Some("describe-access") => Ok(glowcap::Argument::Void),
			_ => Err("unexpected method".into()),
		})
		.unwrap();
	let attached = Workspace::attached(host, Scripted::new(HostPlatform, 1..last, Miss::Unstarted), workspace);
	let key = custody::FieldKey::<()>::new(NonZeroU64::MIN, NonZeroU64::MIN);
	attached
		.history(custody::Coordinate::new(custody::Role::RoomSeat, key))
		.await
		.unwrap_err()
}

#[tokio::test]
async fn a_reader_the_session_still_answers_around_times_out_alone() {
	rooms_testing::local_set::run(async {
		let error = history_missing(2).await;
		assert!(matches!(error, Error::RequestTimedOut(_)), "{error:?}");
		assert_eq!(error.failure_code(), Some(FailureCode::SessionRequestTimedOut));
		assert!(!error.connection_failed(), "the link stands");
	})
	.await;
}

#[tokio::test]
async fn a_session_that_misses_the_probe_too_has_lost_its_link() {
	rooms_testing::local_set::run(async {
		let error = history_missing(usize::MAX).await;
		assert!(matches!(error, Error::Unreached { cause: None, .. }), "{error:?}");
		assert_eq!(error.failure_code(), Some(FailureCode::SessionUnreachable));
	})
	.await;
}

#[tokio::test]
async fn a_control_that_misses_a_call_is_asked_what_it_answers() {
	rooms_testing::local_set::run(async {
		let host = glowcap::Host::from_seed([228; 32]).unwrap();
		let asked = Rc::new(std::cell::RefCell::new(Vec::new()));
		let heard = asked.clone();
		let control = host
			.spawn(move |verb, _| {
				heard.borrow_mut().push(verb.unwrap_or_default().to_owned());
				match verb {
					Some("derivation-sequence") => Ok(glowcap::Argument::Integer(0)),
					_ => Err("unexpected method".into()),
				}
			})
			.unwrap();
		let attached = Control::attached(host, Scripted::new(HostPlatform, 0..1, Miss::Unstarted), control);
		let error = attached.durable_name().await.unwrap_err();
		assert!(matches!(error, Error::RequestTimedOut(_)), "{error:?}");
		assert_eq!(
			*asked.borrow(),
			["durable-name", "derivation-sequence"],
			"the probe is one the control answers"
		);
	})
	.await;
}

/// A workspace another process serves over TCP, attached through this
/// runtime's Host. The dialing session stays held, as the page holds it.
struct Served {
	runtime: Runtime,
	_server: tcp::Server,
	peer: Rc<glowcap::Session>,
	_dialed: glowcap::Session,
	workspace: Workspace<HostPlatform>,
}
async fn served() -> Served {
	let server = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(tcp::Config {
		profiles: tcp::Profiles::TCP,
		..Default::default()
	})]))
	.await
	.unwrap();
	let locator = server.locator().unwrap();
	let (dialed, peer) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let (dialed, peer) = (dialed.unwrap(), Rc::new(peer.unwrap()));
	let service = peer.clone();
	tokio::task::spawn_local(async move {
		// tolerant: the serving loop ends when either side closes the session.
		drop(service.serve().await);
	});
	peer.publish("workspace", |verb, _| match verb {
		Some("mutation-sequence") => Ok(glowcap::Argument::Integer(1)),
		_ => Err("unexpected method".into()),
	})
	.unwrap();
	let reference = dialed.fetch("workspace").await.unwrap();
	let workspace = Workspace::attached(runtime.host().clone(), HostPlatform, reference);
	Served {
		runtime,
		_server: server,
		peer,
		_dialed: dialed,
		workspace,
	}
}

#[tokio::test]
async fn a_call_whose_connection_the_session_closed_names_it_unreachable() {
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let served = served().await;
		let workspace = &served.workspace;
		assert_eq!(
			workspace.mutation_sequence().await.unwrap(),
			1,
			"the session answers before it closes"
		);
		served.peer.close(PendingWork::Cancel).await.unwrap();
		let error = workspace.mutation_sequence().await.unwrap_err();
		assert!(matches!(error, Error::Unreached { cause: Some(_), .. }), "{error:?}");
		assert_eq!(error.failure_code(), Some(FailureCode::SessionUnreachable));
	})
	.await;
}

#[tokio::test]
async fn a_retired_workspace_leaves_no_live_session() {
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let served = served().await;
		let (host, workspace) = (served.runtime.host(), &served.workspace);
		let live = host.reference_session(workspace.reference()).unwrap();
		assert!(
			live.is_some_and(|session| session.is_open()),
			"the dialed session is live"
		);
		workspace.retire().await.unwrap();
		let left = host.reference_session(workspace.reference()).unwrap();
		assert!(
			left.is_none_or(|session| !session.is_open()),
			"the retired session is closed"
		);
		workspace.retire().await.unwrap();
	})
	.await;
}

/// A session from `host` to a workspace `server` serves over an in-memory
/// stream, whose writes from `host` wait while `gate` holds them.
async fn gated(host: &glowcap::Host, server: &glowcap::Host, gate: Gate) -> (glowcap::Session, glowcap::Session) {
	let (left, right) = tokio::io::duplex(4096);
	let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9012");
	let budget = Some(Duration::from_secs(2));
	let (dialed, accepted) = tokio::join!(
		glowcap::Session::dial_over(host, &locator, Stream { inner: left, gate }, budget),
		glowcap::Session::accept_over(server, "tcp", "127.0.0.1:9012", "127.0.0.1:9012", right, budget)
	);
	(dialed.unwrap(), accepted.unwrap())
}

#[tokio::test]
async fn a_close_that_outlasts_the_first_retire_is_finished_by_the_next() {
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let host = glowcap::Host::from_seed([226; 32]).unwrap();
		let server = glowcap::Host::from_seed([227; 32]).unwrap();
		let gate = Gate::default();
		let (dialed, accepted) = gated(&host, &server, gate.clone()).await;
		accepted
			.publish("workspace", |verb, _| match verb {
				Some("mutation-sequence") => Ok(glowcap::Argument::Integer(1)),
				_ => Err("unexpected method".into()),
			})
			.unwrap();
		let reference = dialed.fetch("workspace").await.unwrap();
		// The host's own clock, except that the first bounded wait gives up.
		let clock = Scripted::new(HostPlatform, 0..1, Miss::Started);
		let workspace = Workspace::attached(host.clone(), clock.clone(), reference);
		// The far side stops reading, so the close cannot send its last frame.
		gate.block();
		let first = workspace.retire().await;
		assert_eq!(
			clock.gave_up(),
			1,
			"the first retire's close met the bound that gives up"
		);
		assert!(gate.observed(), "the close waits on its write");
		let error = first.unwrap_err();
		assert!(matches!(error, Error::Unreached { cause: None, .. }), "{error:?}");
		assert_eq!(error.failure_code(), Some(FailureCode::SessionUnreachable));
		gate.open();
		workspace.retire().await.unwrap();
		let finished = tokio::time::timeout(Duration::ZERO, dialed.closed()).await;
		assert!(
			finished.is_ok(),
			"the next retire returns once the same close has finished"
		);
	})
	.await;
}
