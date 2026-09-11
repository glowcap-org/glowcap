use super::*;
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use std::time::Duration;
#[tokio::test]
async fn session_service_snapshot_lists_issued_grants() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), grants())
				.await
				.expect("native session grant snapshot deadline");
		})
		.await;
}
async fn grants() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let id = "00000000-0000-4000-8000-000000000002";
	let mut previous = None;
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
			session
				.send(
					&root,
					"issueGrant",
					&[id.into(), "interact".into(), "helper".into(), Argument::Boolean(false)],
				)
				.await
				.unwrap();
		}
		let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
		let listed = snapshot
			.grants
			.as_slice()
			.iter()
			.map(|grant| grant.id.as_str())
			.collect::<Vec<_>>();
		assert_eq!(listed, [id], "restart {restart}");
		let grant_link =
			glowcap::parse_sturdyref(&snapshot.grants.as_slice()[0].sturdyref, glowcap::CaptpVersion::V1_0).unwrap();
		if let Some(swiss) = &previous {
			assert_eq!(&grant_link.swissnum, swiss);
		}
		previous = Some(grant_link.swissnum);
		stop_session(running, session).await;
	}
	runtime.close(PendingWork::Cancel).await.unwrap();
}
