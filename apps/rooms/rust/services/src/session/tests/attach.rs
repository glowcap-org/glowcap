use super::*;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::{grants::Access, session::snapshot::views::Adoption};
use std::{cell::RefCell, rc::Rc, time::Duration};
#[tokio::test]
async fn session_peer_tcp_attach_watch_adopt_and_restart_keeps_swiss() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario())
				.await
				.expect("host session service deadline");
		})
		.await;
}
async fn scenario() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let mut previous_swiss = None;
	for restart in 0..2 {
		let running = start_session(temp.0.clone()).await;
		let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
		if let Some(swiss) = &previous_swiss {
			assert_eq!(&parsed.swissnum, swiss);
		}
		previous_swiss = Some(parsed.swissnum.clone());
		let admin = std::fs::read_to_string(temp.0.join("admin.sturdyref")).unwrap();
		assert_eq!(admin.trim(), running.link);
		let session = runtime
			.connect(&parsed.locator, ConnectOptions::default())
			.await
			.unwrap()
			.with_gc();
		let root = session.enliven(&running.link).await.unwrap();
		let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
		assert_eq!(snapshot.access, Access::Admin);
		if restart == 0 {
			assert_eq!(snapshot.workspace_adoption, Adoption::Available);
			let seen = Rc::new(RefCell::new(0usize));
			let observer = session
				.spawn({
					let seen = seen.clone();
					move |verb, args| {
						if verb == "changed" {
							assert_eq!(args.len(), 12);
							*seen.borrow_mut() += 1;
						}
						Ok(Argument::Void)
					}
				})
				.unwrap();
			let watched = parse_snapshot(&session.send(&root, "watch", &[observer.into()]).await.unwrap());
			assert_eq!(watched.workspace_adoption, Adoption::Available);
			let empty = rooms_application::session::checkpoint::Checkpoint::empty()
				.encode_for(Access::Admin)
				.unwrap();
			let revision = session
				.send(
					&root,
					"adoptWorkspace",
					&["adopt-1".into(), Argument::Integer(0), empty.into()],
				)
				.await
				.unwrap();
			assert_eq!(revision, Argument::Integer(1));
			tokio::time::timeout(Duration::from_secs(3), async {
				while *seen.borrow() == 0 {
					tokio::task::yield_now().await;
				}
			})
			.await
			.expect("watch changed after adopt");
			let after = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
			assert_eq!(after.workspace_adoption, Adoption::Closed);
			assert_eq!(after.revision.get(), 1);
			let standing = session
				.send(
					&root,
					"command",
					&[
						"standing".into(),
						Argument::Integer(1),
						"setStanding".into(),
						"away".into(),
					],
				)
				.await
				.unwrap();
			assert_eq!(standing, Argument::Integer(2));
			let live = session
				.send(
					&root,
					"command",
					&[
						"say-1".into(),
						Argument::Integer(2),
						"say".into(),
						"room".into(),
						"hi".into(),
					],
				)
				.await
				.unwrap_err();
			assert!(live.to_string().contains("no longer part of this Rooms session"));
		} else {
			assert_eq!(snapshot.workspace_adoption, Adoption::Closed);
			assert_eq!(snapshot.revision.get(), 2);
		}
		stop_session(running, session).await;
		assert!(!temp.0.join("admin.sturdyref").exists());
	}
	runtime.close(PendingWork::Cancel).await.unwrap();
}
