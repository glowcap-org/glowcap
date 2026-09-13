use super::*;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use std::time::Duration;
#[tokio::test]
async fn session_peer_opens_managed_rooms_and_resumes_their_pending_result() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(45), managed())
				.await
				.expect("host session managed-room deadline");
		})
		.await;
}
async fn managed() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let peer = DirectoryPeer::start().await;
	let running = start_session(temp.0.clone()).await;
	let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
	let session = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let root = session.enliven(&running.link).await.unwrap();
	adopt_admin(&session, &root, "adopt-managed").await;
	let (directory, connected) = join_directory(&session, &root, &peer, "join-dir", 1).await;
	session
		.send(
			&root,
			"command",
			&[
				"join-room".into(),
				Argument::Integer(connected.revision.get() as i64),
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
	wait_room(&session, &root, "garden-room").await;
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"ensure-link".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"ensureRoomLink".into(),
				"garden-room".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			if snapshot
				.checkpoint
				.rooms()
				.any(|room| room.id.text().as_str() == Some("garden-room") && room.link.is_some())
			{
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("ensureRoomLink retained the public room link");
	peer.allow_managed(false);
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	let refused = session
		.send(
			&root,
			"command",
			&[
				"open-managed".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"openManagedRoom".into(),
				serde_json::json!({
					"kind": "room",
					"id": "managed-garden",
					"directory": directory,
					"name": "managed",
					"held": true,
					"standing": null,
					"draft": ""
				})
				.to_string()
				.into(),
				"~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
				"secret".into(),
				"invite-only".into(),
				"moderated".into(),
			],
		)
		.await
		.unwrap_err()
		.to_string();
	assert!(
		refused.contains("resumed safely") || refused.contains("unavailable"),
		"openManagedRoom refused recovery, got {refused}"
	);
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			if snapshot
				.pending_effects
				.as_slice()
				.iter()
				.any(|id| id.text().as_str() == Some("open-managed"))
			{
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("failed openManagedRoom left a resumable pending result");
	peer.allow_managed(true);
	session
		.send(&root, "resumeEffect", &["open-managed".into()])
		.await
		.unwrap();
	wait_room(&session, &root, "managed-garden").await;
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	assert!(
		snapshot
			.checkpoint
			.rooms()
			.any(|room| room.id.text().as_str() == Some("managed-garden") && room.manager.is_some()),
		"openManagedRoom retained manager authority"
	);
	session
		.send(
			&root,
			"command",
			&[
				"set-policy".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"setManagedRoomPolicy".into(),
				"managed-garden".into(),
				"listed".into(),
				"open".into(),
				"open".into(),
			],
		)
		.await
		.unwrap();
	assert!(
		peer.published().iter().any(|row| row == "manager:setRoomPolicy"),
		"setManagedRoomPolicy reached the live manager {:?}",
		peer.published()
	);
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"take-mod".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"takeRoomModerator".into(),
				"managed-garden".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			if peer.published().iter().any(|row| row == "manager:giveSteward") {
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("takeRoomModerator claimed steward from the manager");
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"kick-bob".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"kickRoomMember".into(),
				"managed-garden".into(),
				"bob".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			if peer.kicked().iter().any(|nick| nick == "bob") {
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("kickRoomMember reached the live steward");
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"unregister".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"unregisterManagedRoom".into(),
				"managed-garden".into(),
			],
		)
		.await
		.unwrap();
	assert!(
		peer.published().iter().any(|row| row == "manager:unregisterRoom"),
		"unregisterManagedRoom reached the live manager {:?}",
		peer.published()
	);
	stop_session(running, session).await;
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
