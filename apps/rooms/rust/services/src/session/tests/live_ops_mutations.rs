use super::*;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use std::time::Duration;
#[tokio::test]
async fn session_peer_relays_operator_listener_and_irc_mutations() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), mutations())
				.await
				.expect("host session ops mutation deadline");
		})
		.await;
}
async fn mutations() {
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
	adopt_admin(&session, &root, "adopt-mutations").await;
	let (directory, connected) = join_directory(&session, &root, &peer, "join-dir", 1).await;
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
	let connected = wait_directory(&session, &root, directory.as_str()).await;
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			match session
				.send(&root, "operatorSnapshot", &[directory.clone().into()])
				.await
			{
				Ok(Argument::String(text)) if text.contains("\"stewardships\"") => return,
				_ => tokio::task::yield_now().await,
			}
		}
	})
	.await
	.expect("operator capability became live");
	session
		.send(
			&root,
			"command",
			&[
				"op-nick".into(),
				Argument::Integer(connected.revision.get() as i64),
				"operator".into(),
				directory.clone().into(),
				"revokeNick".into(),
				"bob".into(),
				"session-1".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			if peer.published().iter().any(|row| row == "operator:revokeNick") {
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("operator revokeNick reached the live capability");
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"listener-up".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"operations".into(),
				directory.clone().into(),
				"listeners".into(),
				"up".into(),
				"tcp".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			if peer.published().iter().any(|row| row == "listeners:up:tcp") {
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("listener up reached the live capability");
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"irc-open".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"operations".into(),
				directory.clone().into(),
				"irc".into(),
				"openConnection".into(),
				"{}".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			if peer.published().iter().any(|row| row == "irc:openConnection") {
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("irc openConnection reached the live capability");
	stop_session(running, session).await;
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
