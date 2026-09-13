//! A live room's own notices reach the session: a policy change updates the
//! room view, and an ended membership retires the room under an issue and is
//! rejoined once the room lets the member back in.
use super::*;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::room::policy::RoomPolicy;
use std::time::Duration;

#[tokio::test]
async fn session_peer_follows_a_room_through_policy_change_and_ended_membership() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(40), scenario())
				.await
				.expect("host session room notices deadline");
		})
		.await;
}

async fn submit_bridge(
	session: &glowcap::Session,
	root: &glowcap::Ref,
	id: &str,
	action: &str,
	public: serde_json::Value,
	secrets: serde_json::Value,
) {
	let base = parse_snapshot(&session.send(root, "snapshot", &[]).await.unwrap())
		.revision
		.get();
	session
		.send(
			root,
			"command",
			&[
				id.into(),
				Argument::Integer(base as i64),
				"submitRoomBridgeForm".into(),
				"garden-room".into(),
				"network".into(),
				action.into(),
				public.to_string().into(),
				secrets.to_string().into(),
			],
		)
		.await
		.unwrap();
}

async fn submit_bridge_password(session: &glowcap::Session, root: &glowcap::Ref, id: &str, password: &str) {
	submit_bridge(
		session,
		root,
		id,
		"link",
		serde_json::json!({"nick":"alice"}),
		serde_json::json!({"password":password}),
	)
	.await;
}

async fn submit_bridge_disconnect(session: &glowcap::Session, root: &glowcap::Ref, id: &str) {
	submit_bridge(
		session,
		root,
		id,
		"unlink",
		serde_json::json!({}),
		serde_json::json!({}),
	)
	.await;
}

async fn scenario() {
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
	adopt_admin(&session, &root, "adopt-rooms").await;
	let (directory, snapshot) = join_directory(&session, &root, &peer, "join-dir", 1).await;
	session
		.send(
			&root,
			"command",
			&[
				"join-room".into(),
				Argument::Integer(snapshot.revision.get() as i64),
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
	let bridge_base = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap())
		.revision
		.get();
	session
		.send(
			&root,
			"command",
			&[
				"bridge-login".into(),
				Argument::Integer(bridge_base as i64),
				"submitRoomBridgeForm".into(),
				"garden-room".into(),
				"network".into(),
				"link".into(),
				serde_json::json!({"nick":"alice"}).to_string().into(),
				serde_json::json!({"password":"correct horse"}).to_string().into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		while peer.bridge_calls().is_empty() {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("committed bridge intent reached the live room");
	assert_eq!(
		peer.bridge_calls(),
		vec![(
			"link".to_owned(),
			serde_json::json!({"nick":"alice","password":"correct horse"}).to_string()
		)]
	);
	let changed = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"command",
			&[
				"bridge-password-change".into(),
				Argument::Integer(changed.revision.get() as i64),
				"submitRoomBridgeForm".into(),
				"garden-room".into(),
				"network".into(),
				"link".into(),
				serde_json::json!({"nick":"alice"}).to_string().into(),
				serde_json::json!({"password":"new horse"}).to_string().into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		while peer.bridge_calls().len() < 2 {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("a secret-only bridge change reached the live room");
	assert_eq!(
		peer.bridge_calls()[1],
		(
			"link".to_owned(),
			serde_json::json!({"nick":"alice","password":"new horse"}).to_string()
		)
	);
	let public = session.send(&root, "snapshot", &[]).await.unwrap();
	assert!(
		!format!("{public:?}").contains("correct horse") && !format!("{public:?}").contains("new horse"),
		"session projection must not expose bridge credentials"
	);

	stop_session(running, session).await;
	let running = start_session(temp.0.clone()).await;
	let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
	let session = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let root = session.enliven(&running.link).await.unwrap();
	wait_room(&session, &root, "garden-room").await;
	tokio::time::timeout(Duration::from_secs(8), async {
		while peer.bridge_calls().len() < 3 {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("restart replayed bridge intent with separately held credentials");
	assert_eq!(peer.bridge_calls()[1], peer.bridge_calls()[2]);

	let room_policy = |snapshot: &rooms_application::session::snapshot::Snapshot| {
		snapshot
			.room_views
			.as_slice()
			.iter()
			.find(|view| view.conversation_id.text().as_str() == Some("garden-room"))
			.map(|view| view.policy)
	};
	let current = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	assert_eq!(room_policy(&current), Some(RoomPolicy::Open));
	// Recording the listing's publication id must not cost a second
	// membership: a session that leaves and rejoins on its own facts empties
	// a room it is alone in and never settles.
	tokio::time::sleep(Duration::from_millis(300)).await;
	assert_eq!(
		peer.room_subscriptions(),
		2,
		"one intended room is one membership on each session incarnation"
	);

	// The room announces a policy change; the view follows it.
	peer.change_room_policy(RoomPolicy::Moderated);
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			if room_policy(&snapshot) == Some(RoomPolicy::Moderated) {
				break;
			}
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("the room view followed the policy change");

	// Returning to an already applied disconnect while a login is pending still
	// needs a compensating remote call: the login may take effect before its stale
	// completion reaches this worker.
	submit_bridge_disconnect(&session, &root, "bridge-disconnect-before-slow").await;
	tokio::time::timeout(Duration::from_secs(2), async {
		while !peer.bridge_calls().last().is_some_and(|(action, _)| action == "unlink") {
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("the initial bridge disconnect was applied");
	let calls_before_slow = peer.bridge_calls().len();
	submit_bridge_password(&session, &root, "bridge-slow-change", "slow horse").await;
	tokio::time::timeout(Duration::from_secs(2), async {
		while peer.bridge_calls().len() == calls_before_slow {
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("the slow bridge submission started");
	peer.change_room_policy(RoomPolicy::Open);
	tokio::time::timeout(Duration::from_millis(500), async {
		loop {
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			if room_policy(&snapshot) == Some(RoomPolicy::Open) {
				break;
			}
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("a slow bridge call did not block room lifecycle notices");

	submit_bridge_disconnect(&session, &root, "bridge-disconnect-during-login").await;
	tokio::time::timeout(Duration::from_secs(5), async {
		while !peer.bridge_calls().last().is_some_and(|(action, _)| action == "unlink") {
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("disconnect compensated for the login that was already in flight");

	let calls_before_stale = peer.bridge_calls().len();
	submit_bridge_password(&session, &root, "bridge-second-slow-change", "slow horse again").await;
	tokio::time::timeout(Duration::from_secs(2), async {
		while peer.bridge_calls().len() == calls_before_stale {
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("the second slow bridge submission started");
	submit_bridge_password(&session, &root, "bridge-middle-change", "middle horse").await;
	submit_bridge_password(&session, &root, "bridge-final-change", "final horse").await;
	tokio::time::timeout(Duration::from_secs(5), async {
		loop {
			let calls = peer.bridge_calls();
			if calls.last().is_some_and(|(_, answers)| answers.contains("final horse")) {
				break;
			}
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("the latest serialized bridge change was applied");
	assert!(
		peer.bridge_calls()
			.iter()
			.all(|(_, answers)| !answers.contains("middle horse")),
		"a bridge change superseded while waiting must not reach the membership"
	);

	// The room ends the membership: the room leaves the live views under an
	// issue naming the reason, and the session rejoins on its own.
	peer.end_room_membership("kicked by the test");
	let subject = format!("room:{directory}:garden-room");
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			let issue = snapshot
				.issues
				.as_slice()
				.iter()
				.find(|(held, _)| held.text().as_str() == Some(subject.as_str()))
				.map(|(_, reason)| reason.text().as_str().unwrap_or("").to_owned());
			if room_policy(&snapshot).is_none() && issue.as_deref().is_some_and(|r| r.contains("kicked by the test")) {
				break;
			}
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("the ended membership retired the room under its reason");
	wait_room(&session, &root, "garden-room").await;
	let rejoined = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	assert!(
		!rejoined
			.issues
			.as_slice()
			.iter()
			.any(|(held, _)| held.text().as_str() == Some(subject.as_str())),
		"a rejoined room clears its issue"
	);

	let calls_before_disconnect = peer.bridge_calls().len();
	session
		.send(
			&root,
			"command",
			&[
				"bridge-disconnect".into(),
				Argument::Integer(rejoined.revision.get() as i64),
				"submitRoomBridgeForm".into(),
				"garden-room".into(),
				"network".into(),
				"disconnect".into(),
				"{}".into(),
				"{}".into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), async {
		while peer.bridge_calls().len() == calls_before_disconnect {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("disconnect intent reached the live room");
	assert_eq!(
		peer.bridge_calls().last(),
		Some(&("disconnect".to_owned(), "{}".to_owned()))
	);

	let subscriptions = peer.room_subscriptions();
	peer.end_room_membership("room-retired: removed by the directory operator");
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			let absent = snapshot
				.room_views
				.as_slice()
				.iter()
				.all(|room| room.conversation_id.text().as_str() != Some("garden-room"));
			let terminal = snapshot.issues.as_slice().iter().any(|(held, reason)| {
				held.text().as_str() == Some(subject.as_str())
					&& reason
						.text()
						.as_str()
						.is_some_and(|reason| reason.contains("room-retired"))
			});
			if absent && terminal {
				break;
			}
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("terminal room retirement became visible");
	tokio::time::sleep(Duration::from_millis(2300)).await;
	assert_eq!(
		peer.room_subscriptions(),
		subscriptions,
		"terminal retirement must not recreate a room by name"
	);

	stop_session(running, session).await;
	let custody = std::fs::read_to_string(temp.0.join("bridge-secrets.json")).unwrap();
	assert!(
		!custody.contains("correct horse")
			&& !custody.contains("new horse")
			&& !custody.contains("slow horse")
			&& !custody.contains("slow horse again")
			&& !custody.contains("middle horse")
			&& !custody.contains("final horse"),
		"disconnect prunes bridge credentials"
	);
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
