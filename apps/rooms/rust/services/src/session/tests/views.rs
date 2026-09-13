//! Attached views follow the authority they attached through: a grant's
//! history right gates the archive, a revoked delegate stops receiving, and
//! one view's typing reaches the others without echoing to itself.
use super::*;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::grants::Access;
use std::{cell::Cell, rc::Rc, time::Duration};

#[tokio::test]
async fn session_peer_views_follow_their_authority() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(40), scenario())
				.await
				.expect("host session views deadline");
		})
		.await;
}

/// Counts of what one observer received.
#[derive(Default)]
struct Seen {
	changed: Cell<u32>,
	history: Cell<u32>,
	typing_from_another_view: Cell<u32>,
}

fn observer(session: &glowcap::Session) -> (glowcap::Ref, Rc<Seen>) {
	let seen = Rc::new(Seen::default());
	let counting = seen.clone();
	let observer = session
		.spawn(move |verb, args| {
			match verb {
				"changed" => counting.changed.set(counting.changed.get() + 1),
				"historyChanged" => {
					rooms_application::archive::change::Change::read(
						&args.iter().map(rooms_glowcap::Value).collect::<Vec<_>>(),
					)
					.unwrap();
					counting.history.set(counting.history.get() + 1);
				}
				"event" => {
					let from = args.get(3).and_then(Argument::as_str).unwrap_or("");
					let presence = args.get(13).and_then(Argument::as_str).unwrap_or("");
					if from == "Another attached view" && presence.contains("\"typing\"") {
						counting
							.typing_from_another_view
							.set(counting.typing_from_another_view.get() + 1);
					}
				}
				_ => {}
			}
			Ok(Argument::Void)
		})
		.unwrap();
	(observer, seen)
}

async fn until(what: &str, condition: impl Fn() -> bool) {
	tokio::time::timeout(Duration::from_secs(8), async {
		while !condition() {
			tokio::task::yield_now().await;
		}
	})
	.await
	.unwrap_or_else(|_| panic!("{what}"));
}

async fn scenario() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let peer = DirectoryPeer::start().await;
	let running = start_session(temp.0.clone()).await;
	let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
	let alice = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let root = alice.enliven(&running.link).await.unwrap();
	adopt_admin(&alice, &root, "adopt-views").await;

	// A grant that may interact but not read history is refused the archive
	// and still answers everything else with its own access.
	let grant_id = "00000000-0000-4000-8000-000000000007";
	alice
		.send(
			&root,
			"issueGrant",
			&[
				grant_id.into(),
				"interact".into(),
				"helper".into(),
				Argument::Boolean(false),
			],
		)
		.await
		.unwrap();
	let snapshot = parse_snapshot(&alice.send(&root, "snapshot", &[]).await.unwrap());
	let grant_link = snapshot.grants.as_slice()[0].sturdyref.clone();
	let granted = alice.enliven(&grant_link).await.unwrap();
	let refused = alice
		.send(
			&granted,
			"readHistory",
			&["room".into(), "directory".into(), "conversation".into()],
		)
		.await
		.unwrap_err();
	assert!(
		refused.to_string().contains("cannot read archived history"),
		"history right gates the archive: {refused}"
	);
	let through_grant = parse_snapshot(&alice.send(&granted, "snapshot", &[]).await.unwrap());
	assert_eq!(through_grant.access, Access::Interact);

	// A delegate minted on this session admits a view; revoking the delegate
	// retires that view while the administrator's own view keeps receiving.
	let (control, control_seen) = observer(&alice);
	alice.send(&root, "watch", &[control.into()]).await.unwrap();
	let pair = alice.send(&root, "facet", &["observe".into()]).await.unwrap();
	let [Argument::Reference(delegate), Argument::Reference(revoker)] = pair.as_list().unwrap() else {
		panic!("facet mints a delegate and its revoker: {pair:?}");
	};
	let (delegated, delegated_seen) = observer(&alice);
	let watched = parse_snapshot(&alice.send(delegate, "watch", &[delegated.into()]).await.unwrap());
	assert_eq!(watched.access, Access::Observe);
	let revision = |snapshot: &rooms_application::session::snapshot::Snapshot| snapshot.revision.get() as i64;
	let current = parse_snapshot(&alice.send(&root, "snapshot", &[]).await.unwrap());
	alice
		.send(
			&root,
			"command",
			&[
				"standing-1".into(),
				Argument::Integer(revision(&current)),
				"setStanding".into(),
				"away".into(),
			],
		)
		.await
		.unwrap();
	until("both views saw the standing change", || {
		control_seen.changed.get() >= 1 && delegated_seen.changed.get() >= 1
	})
	.await;
	alice.send(revoker, "revoke", &[]).await.unwrap();
	let refused = alice.send(delegate, "snapshot", &[]).await.unwrap_err();
	assert!(refused.to_string().contains("revoked"), "{refused}");
	let before = (control_seen.changed.get(), delegated_seen.changed.get());
	let current = parse_snapshot(&alice.send(&root, "snapshot", &[]).await.unwrap());
	alice
		.send(
			&root,
			"command",
			&[
				"standing-2".into(),
				Argument::Integer(revision(&current)),
				"setStanding".into(),
				"".into(),
			],
		)
		.await
		.unwrap();
	until("the administrator's view saw the second change", || {
		control_seen.changed.get() > before.0
	})
	.await;
	assert_eq!(
		delegated_seen.changed.get(),
		before.1,
		"a revoked delegate's view receives nothing more"
	);

	// Typing from one attached view reaches the session's other views as
	// another view's typing, and is not echoed to the view that sent it.
	let (directory, _) = join_directory(&alice, &root, &peer, "join-dir", 3).await;
	let current = parse_snapshot(&alice.send(&root, "snapshot", &[]).await.unwrap());
	alice
		.send(
			&root,
			"command",
			&[
				"join-room".into(),
				Argument::Integer(revision(&current)),
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
	wait_room(&alice, &root, "garden-room").await;
	// A second browser is a second Host: one Host holds one session per partner.
	let other_runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let other = other_runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let other_root = other.enliven(&running.link).await.unwrap();
	let (other_observer, other_seen) = observer(&other);
	other
		.send(&other_root, "watch", &[other_observer.into()])
		.await
		.unwrap();
	alice
		.send(&root, "typing", &["garden-room".into(), Argument::Boolean(true)])
		.await
		.unwrap();
	until("the other view learned another view is typing", || {
		other_seen.typing_from_another_view.get() == 1
	})
	.await;
	assert_eq!(
		control_seen.typing_from_another_view.get(),
		0,
		"typing is not echoed to the view that sent it"
	);

	// History invalidation obeys the same live rights as a history read.
	let (without_history, without_history_seen) = observer(&alice);
	alice.send(&granted, "watch", &[without_history.into()]).await.unwrap();
	let history_before = control_seen.history.get();
	for keep in ["true", "false"] {
		let current = parse_snapshot(&alice.send(&root, "snapshot", &[]).await.unwrap());
		alice
			.send(
				&root,
				"command",
				&[
					format!("history-{keep}").into(),
					Argument::Integer(revision(&current)),
					"chooseHistoryRetention".into(),
					keep.into(),
				],
			)
			.await
			.unwrap();
	}
	until("erasure invalidated the administrator's history", || {
		control_seen.history.get() > history_before
	})
	.await;
	assert_eq!(
		without_history_seen.history.get(),
		0,
		"a history-free grant receives no archive activity"
	);
	assert_eq!(
		delegated_seen.history.get(),
		0,
		"a revoked delegate receives no archive activity"
	);

	other.close(PendingWork::Cancel).await.unwrap();
	other_runtime.close(PendingWork::Cancel).await.unwrap();
	stop_session(running, alice).await;
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
