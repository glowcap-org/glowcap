//! A fetch of a durable name the Host does not publish is a question for the
//! Store, whether it arrives after the session is served or is read first
//! and held until then.
use super::*;

/// Fetch an unpublished durable name over a new session. With `held`, the
/// listener reads the fetch before the embedder serves the session.
async fn fetch_unpublished_durable_name(held: bool) {
	let mut store = Store::open(
		Volatile {
			identity: [3; 16],
			capacity_bytes: 8 * 1024 * 1024,
		},
		&[SCHEMA],
		Limits::default(),
	)
	.unwrap();
	let host = Host::from_seed([8; 32]).unwrap();
	let mut attachment = store.attach(&host, vec![registration()]).unwrap();
	let server = crate::tcp::listen(
		"127.0.0.1",
		0,
		crate::tcp::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let runtime = crate::Runtime::open(crate::RuntimeConfig::providers([crate::tcp::provider(
		crate::tcp::Config {
			profiles: crate::tcp::Profiles::TCP,
			..Default::default()
		},
	)]))
	.await
	.unwrap();
	let locator = server.locator().unwrap();
	let (client, accepted) = tokio::join!(
		runtime.connect(&locator, crate::ConnectOptions::default()),
		server.accept()
	);
	let (client, accepted) = (client.unwrap(), accepted.unwrap());
	let name = format!("glowcap-durable-1-{}", "5a".repeat(16));
	let fetch = tokio::task::spawn_local(async move {
		let fetched = client.fetch(&name).await;
		(client, fetched)
	});
	if held {
		// The listener's loop reads the fetch while the session is unserved.
		tokio::time::sleep(std::time::Duration::from_millis(50)).await;
	}
	let serving = tokio::task::spawn_local(async move { accepted.serve().await });
	let (client, fetched) = fetch.await.unwrap();
	let refusal = fetched.expect_err("the Store holds no such name");
	assert!(refusal.is_publication_not_found(), "{refusal}");
	server.close().await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
	drop(client);
	attachment.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	store.close().unwrap();
}

#[tokio::test]
async fn a_fetch_held_until_serve_settles_through_durable_lookup() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), fetch_unpublished_durable_name(true))
				.await
				.expect("a held fetch and its teardown have a finite CapTP budget");
		})
		.await;
}

#[tokio::test]
async fn a_fetch_on_a_served_session_settles_through_durable_lookup() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), fetch_unpublished_durable_name(false))
				.await
				.expect("a fetch and its teardown have a finite CapTP budget");
		})
		.await;
}
