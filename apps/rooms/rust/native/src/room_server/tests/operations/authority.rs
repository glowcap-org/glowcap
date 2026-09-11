//! An uncertain native authority write cannot be followed by another write
//! from the stale in-memory document. Restart reloads the disk authority.
use super::*;

#[tokio::test]
async fn native_authority_requires_reconciliation_after_uncertain_replacement() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), scenario())
				.await
				.expect("authority reconciliation deadline");
		})
		.await;
}
async fn scenario() {
	let temp = Temp::new();
	let asked = Asked {
		operator: true,
		..Default::default()
	};
	let running = start_with(temp.0.clone(), tcp(), asked.clone()).await;
	let runtime = runtime().await;
	let session = runtime
		.connect(
			&glowcap::parse_locator(&running.location).unwrap(),
			ConnectOptions::default(),
		)
		.await
		.unwrap()
		.with_gc();
	let token = running.capabilities[0].swiss.clone();
	let operator = session.fetch(&token).await.unwrap();
	let client = rooms_glowcap::client::Client::new(session.borrowed(), crate::client::Deadline);
	let directory = rooms_glowcap::client::directory::Directory::fetch(client)
		.await
		.unwrap();
	directory.open("garden").await.unwrap();
	session
		.send(&operator, "giveSteward", &["garden".into()])
		.await
		.unwrap();
	let document = temp.0.join(rooms_application::server::document::FILE);
	let saved = temp.0.join("rooms.saved");
	let before = std::fs::read(&document).unwrap();
	std::fs::rename(&document, &saved).unwrap();
	std::fs::create_dir(&document).unwrap();
	// Storage classifies an attempted replacement as uncertain even when
	// this local filesystem refused the rename without replacing anything.
	let failed = session.send(&operator, "resetOperatorScope", &["all".into()]).await;
	std::fs::remove_dir(&document).unwrap();
	std::fs::rename(&saved, &document).unwrap();
	assert!(failed.unwrap_err().to_string().contains("write is uncertain"));
	assert!(session
		.send(&operator, "resetOperatorScope", &["all".into()])
		.await
		.unwrap_err()
		.to_string()
		.contains("requires restart reconciliation"));
	assert!(session
		.send(&operator, "giveSteward", &["garden".into()])
		.await
		.unwrap_err()
		.to_string()
		.contains("requires restart reconciliation"));
	assert_eq!(std::fs::read(&document).unwrap(), before);
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	let running = start_with(temp.0.clone(), tcp(), asked).await;
	let session = runtime
		.connect(
			&glowcap::parse_locator(&running.location).unwrap(),
			ConnectOptions::default(),
		)
		.await
		.unwrap()
		.with_gc();
	let operator = session.fetch(&token).await.unwrap();
	session
		.send(&operator, "resetOperatorScope", &["all".into()])
		.await
		.unwrap();
	assert_ne!(std::fs::read(&document).unwrap(), before);
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
}
