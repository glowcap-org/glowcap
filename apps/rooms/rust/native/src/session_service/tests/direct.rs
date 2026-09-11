use super::*;
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_application::{grants::Access, session::checkpoint::Routes};
use rooms_glowcap::routes::CheckpointRoutes;
use std::{cell::RefCell, rc::Rc, time::Duration};
#[tokio::test]
async fn session_service_starts_a_direct_conversation_and_delivers_a_said_line() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(25), direct())
				.await
				.expect("native session direct deadline");
		})
		.await;
}
async fn direct() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let peer = DirectoryPeer::start().await;
	let directory = CheckpointRoutes.locator_authority(&peer.locator).unwrap();
	let running = start_session(temp.0.clone()).await;
	let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
	let session = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let root = session.enliven(&running.link).await.unwrap();
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"adoptWorkspace",
			&[
				"adopt-direct".into(),
				Argument::Integer(0),
				snapshot.checkpoint.encode_for(Access::Admin).unwrap().into(),
			],
		)
		.await
		.unwrap();
	session
		.send(
			&root,
			"command",
			&[
				"join-dir".into(),
				Argument::Integer(1),
				"joinDirectory".into(),
				serde_json::json!({
					"id": directory,
					"locator": peer.locator,
					"home": true,
					"nick": "alice",
					"standing": null
				})
				.to_string()
				.into(),
			],
		)
		.await
		.unwrap();
	wait_directory(&session, &root, directory.as_str()).await;
	session
		.send(
			&root,
			"command",
			&[
				"start-dm".into(),
				Argument::Integer(2),
				"startDirect".into(),
				serde_json::json!({
					"kind": "direct",
					"id": "alice-bob",
					"directory": directory,
					"peer": "bob",
					"peerRegistrationId": super::peer::REGISTRATION,
					"closed": false,
					"draft": ""
				})
				.to_string()
				.into(),
			],
		)
		.await
		.unwrap();
	wait_direct(&session, &root, "alice-bob").await;
	let lines = Rc::new(RefCell::new(Vec::<u64>::new()));
	let observer = session
		.spawn({
			let lines = lines.clone();
			move |verb, args| {
				if verb == "event" && args.get(2).and_then(Argument::as_str) == Some("alice-bob") {
					if let Some(Argument::Integer(id)) = args.get(6) {
						if *id > 0 {
							lines.borrow_mut().push(*id as u64);
						}
					}
				}
				Ok(Argument::Void)
			}
		})
		.unwrap();
	session.send(&root, "watch", &[observer.into()]).await.unwrap();
	let said = session
		.send(
			&root,
			"command",
			&[
				"say-dm".into(),
				Argument::Integer(3),
				"say".into(),
				"alice-bob".into(),
				"hello over dm".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		while !peer.received().iter().any(|text| text == "hello over dm") {
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("directory peer received the direct line");
	let line = tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			if let Some(line) = lines.borrow().first().copied() {
				return line;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("session observed the posted direct line");
	let Argument::Integer(base) = said else {
		panic!("say answered a revision, got {said:?}");
	};
	let edited = session
		.send(
			&root,
			"command",
			&[
				"edit-dm".into(),
				Argument::Integer(base),
				"editLine".into(),
				"alice-bob".into(),
				line.to_string().into(),
				"hello edited".into(),
			],
		)
		.await
		.unwrap();
	let Argument::Integer(after_edit) = edited else {
		panic!("editLine answered a revision, got {edited:?}");
	};
	session
		.send(
			&root,
			"command",
			&[
				"withdraw-dm".into(),
				Argument::Integer(after_edit),
				"withdrawLine".into(),
				"alice-bob".into(),
				line.to_string().into(),
			],
		)
		.await
		.unwrap();
	stop_session(running, session).await;
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
