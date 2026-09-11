use super::*;
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_application::{grants::Access, session::checkpoint::Routes};
use rooms_glowcap::routes::CheckpointRoutes;
use std::time::Duration;
#[tokio::test]
async fn session_service_reconnects_live_directories_across_restart() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), directories())
				.await
				.expect("native session directory deadline");
		})
		.await;
}
async fn directories() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let peer = DirectoryPeer::start().await;
	let id = CheckpointRoutes.locator_authority(&peer.locator).unwrap();
	let mut previous_swiss = None;
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
			assert_eq!(joined, Argument::Integer(2));
		}
		let snapshot = wait_directory(&session, &root, id.as_str()).await;
		assert_eq!(
			snapshot.directory_views.as_slice()[0].rooms.as_slice()[0]
				.name
				.text()
				.as_str(),
			Some("garden")
		);
		stop_session(running, session).await;
	}
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
