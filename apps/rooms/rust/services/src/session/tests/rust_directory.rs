//! The session peer against the Rust directory peer: the two host sides
//! agree on registration, watching, and reconnecting across a restart.
use super::*;
use crate::server;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::{grants::Access, session::checkpoint::Routes};
use rooms_glowcap::routes::CheckpointRoutes;
use std::{rc::Rc, time::Duration};

#[tokio::test]
async fn session_peer_registers_with_the_rust_directory_across_restart() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), scenario())
				.await
				.expect("host session and directory deadline");
		})
		.await;
}

async fn scenario() {
	let temp = Temp::new();
	let directory_state = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let (stop_directory, stopped) = tokio::sync::oneshot::channel();
	let (ready, location) = tokio::sync::oneshot::channel();
	let directory = tokio::task::spawn_local(server::run(
		server::Config {
			state: Some(directory_state.0.clone()),
			transport: server::Transport::Tcp {
				bind: "127.0.0.1".into(),
				port: 0,
				announce: None,
			},
			history: false,
			storage: None,
			asked: Default::default(),
			trace_port: 0,
		},
		async {
			let _ = stopped.await;
		},
		|ready_now| ready.send(ready_now.location.clone()).unwrap(),
		Rc::new(|notice| panic!("the directory reported {notice}")),
	));
	let location = location.await.unwrap();
	let id = CheckpointRoutes.locator_authority(&location).unwrap();
	for restart in 0..2 {
		let running = start_session(temp.0.clone()).await;
		let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
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
						"adopt-dir".into(),
						Argument::Integer(0),
						snapshot.checkpoint.encode_for(Access::Admin).unwrap().into(),
					],
				)
				.await
				.unwrap();
			let joined = session
				.send(
					&root,
					"command",
					&[
						"join-dir".into(),
						Argument::Integer(1),
						"joinDirectory".into(),
						serde_json::json!({
							"id": id,
							"locator": location,
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
			assert_eq!(joined, Argument::Integer(2));
		}
		let snapshot = wait_directory(&session, &root, id.as_str()).await;
		let view = &snapshot.directory_views.as_slice()[0];
		let peers: Vec<&str> = view
			.peers
			.as_slice()
			.iter()
			.map(|peer| peer.name.text().as_str().unwrap())
			.collect();
		assert_eq!(peers, ["alice"], "restart {restart}");
		assert!(snapshot.issues.as_slice().is_empty(), "{:?}", snapshot.issues);
		if restart == 0 {
			// The session opens a room on the server, and the server lists it
			// back to the session's own directory view.
			session
				.send(
					&root,
					"command",
					&[
						"join-room".into(),
						Argument::Integer(snapshot.revision.get() as i64),
						"joinRoom".into(),
						serde_json::json!({
							"locator": location,
							"nick": "alice",
							"conversation": {
								"kind": "room",
								"id": "garden-room",
								"directory": id,
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
		let listed = tokio::time::timeout(Duration::from_secs(8), async {
			loop {
				let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
				let rooms = &snapshot.directory_views.as_slice()[0].rooms;
				if rooms
					.as_slice()
					.iter()
					.any(|room| room.name.text().as_str() == Some("garden"))
				{
					break snapshot;
				}
				tokio::time::sleep(Duration::from_millis(20)).await;
			}
		})
		.await
		.expect("the server lists the room the session opened");
		let room = &listed.room_views.as_slice()[0];
		assert_eq!(room.policy, rooms_application::room::policy::RoomPolicy::Open);
		stop_session(running, session).await;
	}
	runtime.close(PendingWork::Cancel).await.unwrap();
	stop_directory.send(()).unwrap();
	directory.await.unwrap().unwrap();
}
