use super::*;
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_application::{grants::Access, session::checkpoint::Routes};
use rooms_glowcap::routes::CheckpointRoutes;
use std::time::Duration;
#[tokio::test]
async fn session_service_relays_operator_snapshot_and_offers_over_live_direct() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(40), live_ops())
				.await
				.expect("native session live ops deadline");
		})
		.await;
}
async fn live_ops() {
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
	let attached = rooms_glowcap::client::session::Session::new(
		rooms_glowcap::client::Client::new(session.borrowed(), crate::client::Deadline),
		root.clone(),
	);
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"adoptWorkspace",
			&[
				"adopt-ops".into(),
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
	let connected = wait_directory(&session, &root, directory.as_str()).await;
	session
		.send(
			&root,
			"command",
			&[
				"ops-caps".into(),
				Argument::Integer(connected.revision.get() as i64),
				"replaceOperationsCapabilities".into(),
				serde_json::json!([
					{"capability":"operator","scope":directory,"swiss":"operator"},
					{"capability":"listeners","scope":directory,"swiss":"listeners"},
					{"capability":"diagnostics","scope":directory,"swiss":"diagnostics"},
					{"capability":"irc","scope":directory,"swiss":"irc"}
				])
				.to_string()
				.into(),
			],
		)
		.await
		.unwrap();
	let snapshot = tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			match attached.operator_snapshot(&directory, "", None).await {
				Ok(snapshot) => return snapshot,
				Err(_) => tokio::task::yield_now().await,
			}
		}
	})
	.await
	.expect("typed operator snapshot answered");
	assert_eq!(snapshot.revision.get(), 1);
	assert!(snapshot.rooms.as_slice().is_empty());
	let page = attached
		.operator_page(
			&directory,
			rooms_application::server::operations::operator::Category::Rooms,
			0,
			"",
			None,
		)
		.await
		.unwrap();
	assert_eq!(page.revision.get(), 1);
	assert_eq!(page.total.get(), 0);
	let retired = attached
		.operator_retire(
			&directory,
			rooms_application::server::operations::operator::Category::References,
			"",
			1,
			None,
		)
		.await
		.unwrap();
	assert_eq!(retired.retired.get(), 0);
	let listeners = attached
		.operations_snapshot(
			&directory,
			rooms_application::session::operations::Capability::Listeners,
		)
		.await
		.unwrap();
	assert!(
		matches!(listeners,rooms_application::session::operations::Snapshot::Listeners(rows) if rows.as_slice().is_empty())
	);
	session
		.send(
			&root,
			"command",
			&[
				"join-room".into(),
				Argument::Integer(3),
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
	session
		.send(
			&root,
			"command",
			&[
				"start-dm".into(),
				Argument::Integer(4),
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
	session
		.send(&root, "shareArchive", &["direct".into(), "alice-bob".into()])
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		while !peer.received().iter().any(|text| text == "handArchive") {
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("directory peer received the live archive share");
	let listed = session.send(&root, "listArchiveShares", &[]).await.unwrap();
	assert!(
		matches!(listed, Argument::List(ref rows) if rows.is_empty()),
		"local archive listed {listed:?}"
	);
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"offer-room".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"offerRoom".into(),
				"garden-room".into(),
				"alice-bob".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		while !peer.received().iter().any(|text| text == "handRoom") {
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("directory peer received the live room handoff");
	session
		.send(&root, "offerDurableArchive", &["direct".into(), "alice-bob".into()])
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		while !peer.received().iter().any(|text| text == "offerArchive") {
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("directory peer received the durable archive offer");
	let listed = session.send(&root, "listArchiveShares", &[]).await.unwrap();
	let Argument::List(rows) = &listed else {
		panic!("listArchiveShares answers share rows, got {listed:?}");
	};
	assert_eq!(rows.len(), 1, "local archive listed {listed:?}");
	let dest_peer = DirectoryPeer::start().await;
	let destination = CheckpointRoutes.locator_authority(&dest_peer.locator).unwrap();
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"join-dest".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"joinDirectory".into(),
				serde_json::json!({
					"id": destination,
					"locator": dest_peer.locator,
					"home": false,
					"nick": "alice",
					"standing": null
				})
				.to_string()
				.into(),
			],
		)
		.await
		.unwrap();
	let connected = wait_directory(&session, &root, destination.as_str()).await;
	session
		.send(
			&root,
			"command",
			&[
				"peer-caps".into(),
				Argument::Integer(connected.revision.get() as i64),
				"replaceOperationsCapabilities".into(),
				serde_json::json!([
					{"capability":"operator","scope":directory,"swiss":"operator"},
					{"capability":"listeners","scope":directory,"swiss":"listeners"},
					{"capability":"diagnostics","scope":directory,"swiss":"diagnostics"},
					{"capability":"irc","scope":directory,"swiss":"irc"},
					{"capability":"peering","scope":destination,"swiss":"peering"}
				])
				.to_string()
				.into(),
			],
		)
		.await
		.unwrap();
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"peer-room".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"publishPeeredRoom".into(),
				serde_json::json!({
					"id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
					"destination": destination,
					"source": "garden-room",
					"name": "garden"
				})
				.to_string()
				.into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			match session
				.send(
					&root,
					"operationsSnapshot",
					&[destination.clone().into(), "peering".into()],
				)
				.await
			{
				Ok(Argument::String(text)) if text.contains("\"phase\":\"live\"") => return text,
				_ => tokio::task::yield_now().await,
			}
		}
	})
	.await
	.expect("peering snapshot became live");
	assert!(
		dest_peer
			.published()
			.iter()
			.any(|text| text == "publishDurableRoom:garden"),
		"directory peering published {:?}",
		dest_peer.published()
	);
	stop_session(running, session).await;
	peer.close().await;
	dest_peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
