use super::*;
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_application::direct;
use std::time::Duration;
#[tokio::test]
async fn session_service_reads_a_received_live_archive_share() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(40), share())
				.await
				.expect("native session received-share deadline");
		})
		.await;
}
async fn share() {
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
	adopt_admin(&session, &root, "adopt-share").await;
	let (directory, connected) = join_directory(&session, &root, &peer, "join-dir", 1).await;
	session
		.send(
			&root,
			"command",
			&[
				"start-dm".into(),
				Argument::Integer(connected.revision.get() as i64),
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
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"say-dm".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"say".into(),
				"alice-bob".into(),
				"open the reciprocal inbox".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			if peer
				.received()
				.iter()
				.any(|text| text == "directReady" || text == "open the reciprocal inbox")
			{
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("directory peer received the reciprocal route or opening line");
	let (hosted, reply) = tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			if let Some(held) = peer.reciprocal() {
				return held;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("directory peer received the reciprocal inbox");
	let archive = hosted
		.spawn_owned(|verb, args| match (verb, args) {
			("read", _) => Ok(Argument::List(vec![
				Argument::Integer(0),
				false.into(),
				Argument::List(vec![]),
			])),
			_ => Err("unknown archive method".into()),
		})
		.unwrap();
	hosted
		.send(
			&reply,
			direct::HAND_ARCHIVE,
			&[
				directory.clone().into(),
				"direct".into(),
				"alice-bob".into(),
				archive.clone().into(),
			],
		)
		.await
		.unwrap();
	let id = tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			if let Some(share) = snapshot.archive_shares.as_slice().first() {
				if let Some(id) = share.id.text().as_str() {
					return id.to_owned();
				}
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("snapshot listed the received archive share");
	let page = session
		.send(&root, "readArchiveShare", &[id.clone().into()])
		.await
		.unwrap();
	let Argument::List(fields) = &page else {
		panic!("readArchiveShare answers a page, got {page:?}");
	};
	assert!(fields.len() >= 3, "readArchiveShare page {page:?}");
	assert!(
		matches!(&fields[0], Argument::String(text) if text.contains(&id)),
		"share view {page:?}"
	);
	drop(archive);
	stop_session(running, session).await;
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
