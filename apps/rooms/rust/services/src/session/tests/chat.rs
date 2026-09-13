use super::*;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::{grants::Access, session::checkpoint::Routes};
use rooms_glowcap::routes::CheckpointRoutes;
use std::{cell::RefCell, rc::Rc, time::Duration};
#[tokio::test]
async fn session_peer_joins_public_room_says_and_resubscribes_across_restart() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(40), chat())
				.await
				.expect("host session room deadline");
		})
		.await;
}
async fn chat() {
	let temp = Temp::new();
	let public_source = {
		let mut state = crate::documents::SessionDocuments::open(&temp.0)
			.await
			.unwrap()
			.into_owners()
			.state;
		assert!(matches!(
			state.load().await.unwrap(),
			crate::session_state::LoadStatus::Ready
		));
		let seed = *state.state().unwrap().identity_seed().unwrap();
		let host = glowcap::Host::from_seed(seed).unwrap();
		let public = host.designator().unwrap();
		host.close(PendingWork::Cancel).await.unwrap();
		public
	};
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let peer = DirectoryPeer::start().await;
	let directory = CheckpointRoutes.locator_authority(&peer.locator).unwrap();
	let mut previous_swiss = None;
	let heard = Rc::new(RefCell::new(Vec::<String>::new()));
	for restart in 0..2 {
		let running = start_session(temp.0.clone()).await;
		let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
		if let Some(swiss) = &previous_swiss {
			assert_eq!(&parsed.swissnum, swiss);
		}
		previous_swiss = Some(parsed.swissnum.clone());
		let session = runtime
			.connect(&parsed.locator, ConnectOptions::default())
			.await
			.unwrap()
			.with_gc();
		let root = session.enliven(&running.link).await.unwrap();
		if restart == 0 {
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			session
				.send(
					&root,
					"adoptWorkspace",
					&[
						"adopt-chat".into(),
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
						"join-room".into(),
						Argument::Integer(2),
						"joinRoom".into(),
						serde_json::json!({
							"locator": peer.locator,
							"nick": "alice",
							"conversation": {
								"kind": "room",
								"id": "garden-room",
								"directory": directory,
								"name": "garden",
								"held": false,
								"standing": null,
								"draft": ""
							}
						})
						.to_string()
						.into(),
					],
				)
				.await
				.unwrap();
		}
		wait_room(&session, &root, "garden-room").await;
		if restart == 0 {
			let collected = heard.clone();
			let observer = session
				.spawn(move |verb, args| {
					if verb == "event"
						&& let Some(text) = args.get(4).and_then(Argument::as_str)
						&& !text.is_empty()
					{
						// The change word is the attached view's vocabulary,
						// which its parser refuses the room wire's `line`.
						assert_eq!(
							args.get(7).and_then(Argument::as_str),
							Some("said"),
							"a fresh line's change word: {args:?}"
						);
						collected.borrow_mut().push(text.into());
					}
					Ok(Argument::Void)
				})
				.unwrap();
			session.send(&root, "watch", &[observer.into()]).await.unwrap();
			session
				.send(
					&root,
					"command",
					&[
						"say-garden".into(),
						Argument::Integer(3),
						"say".into(),
						"garden-room".into(),
						"hello from host session".into(),
					],
				)
				.await
				.unwrap();
			tokio::time::timeout(Duration::from_secs(8), async {
				while !heard.borrow().iter().any(|text| text == "hello from host session") {
					tokio::task::yield_now().await;
				}
			})
			.await
			.expect("session delivered the said line");
			tokio::time::timeout(Duration::from_secs(8), async {
				loop {
					let history = session
						.send(
							&root,
							"readHistory",
							&["room".into(), directory.clone().into(), "garden-room".into()],
						)
						.await
						.unwrap();
					if contains_text(&history, "hello from host session") {
						assert!(
							contains_text(&history, &public_source),
							"archive coordinates use the public identity"
						);
						break;
					}
					tokio::task::yield_now().await;
				}
			})
			.await
			.expect("session archived the said line");
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			session
				.send(
					&root,
					"replaceCheckpoint",
					&[
						"replace-chat".into(),
						Argument::Integer(snapshot.revision.get() as i64),
						snapshot.checkpoint.encode_for(Access::Admin).unwrap().into(),
					],
				)
				.await
				.unwrap();
		}
		stop_session(running, session).await;
	}
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
