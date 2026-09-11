use super::*;
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_application::grants::Access;
use std::time::Duration;
#[tokio::test]
async fn session_service_answers_ops_verbs_without_retained_capabilities() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), ops())
				.await
				.expect("native session ops deadline");
		})
		.await;
}
async fn ops() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let running = start_session(temp.0.clone()).await;
	let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
	let session = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let root = session.enliven(&running.link).await.unwrap();
	let missing = session
		.send(&root, "operatorSnapshot", &["directory-1".into()])
		.await
		.unwrap_err()
		.to_string();
	assert!(
		missing.contains("no operator capability"),
		"operatorSnapshot should refuse a missing capability, got {missing}"
	);
	let missing = session
		.send(&root, "operationsSnapshot", &["directory-1".into(), "viz".into()])
		.await
		.unwrap_err()
		.to_string();
	assert!(
		missing.contains("no viz capability"),
		"operationsSnapshot should refuse a missing capability, got {missing}"
	);
	let pair = session.send(&root, "facet", &["observe".into()]).await.unwrap();
	let Argument::List(pair) = pair else {
		panic!("facet answers a facet and revoker, got {pair:?}");
	};
	assert_eq!(pair.len(), 2);
	let Argument::Reference(granted) = &pair[0] else {
		panic!("facet is a reference");
	};
	let Argument::Reference(revoker) = &pair[1] else {
		panic!("revoker is a reference");
	};
	let snapshot = parse_snapshot(&session.send(granted, "snapshot", &[]).await.unwrap());
	assert_eq!(snapshot.access, Access::Observe);
	session.send(revoker, "revoke", &[]).await.unwrap();
	let revoked = session.send(granted, "snapshot", &[]).await.unwrap_err().to_string();
	assert!(revoked.contains("revoked"), "revoked facet, got {revoked}");
	stop_session(running, session).await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
