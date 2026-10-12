//! Actual tab metadata and IndexedDB Store owners preserve one confirmed root
//! through reload and refuse a simultaneous owner of the same tab identity.
use super::*;
mod durability;
mod missing_metadata;
pub(super) async fn run(limits: loam::Limits) {
	let database = rooms_browser::storage::Database::open().await.unwrap();
	let platform = rooms_browser::platform::Platform::new().unwrap();
	let tab = "executor-bootstrap-proof";
	let mut seed = None;
	let mut publication = None;
	let mut anchor = None;
	for reopening in [false, true] {
		let prepared = rooms_browser::storage::session::Prepared::open(database.clone(), tab, platform.clone())
			.await
			.unwrap();
		let identity = prepared.seed();
		let delayed = if reopening {
			None
		} else {
			Some(
				rooms_browser::storage::session::Prepared::open(database.clone(), tab, platform.clone())
					.await
					.unwrap(),
			)
		};
		if let Some(seed) = seed {
			assert_eq!(identity, seed);
		} else {
			seed = Some(identity);
		}
		let host = Host::from_seed_with_options(identity, rooms_glowcap::host_options()).unwrap();
		let mut opened = prepared
			.start(
				host.clone(),
				platform.clone(),
				limits,
				128,
				rooms_application::admission::Settings::defaults(4096, 8),
				|_, _| {},
			)
			.await
			.unwrap();
		assert_eq!(
			opened.workspace().unwrap().snapshot().await.unwrap().intent.connection,
			session::workspace::Connection::Webrtc
		);
		if let Some(anchor) = anchor {
			assert_eq!(opened.anchor().encode(), anchor, "reload restores the confirmed root");
		} else {
			anchor = Some(opened.anchor().encode());
		}
		let link = opened
			.publish(&glowcap::Locator::bare("webrtc", "tab-bootstrap-proof"))
			.await
			.unwrap();
		if let Some(prior) = &publication {
			assert_eq!(&link, prior);
		} else {
			publication = Some(link);
		}
		let workspace = opened.workspace().unwrap();
		let snapshot = workspace.snapshot().await.unwrap();
		if reopening {
			assert_eq!(snapshot.intent.standing.text().as_str(), Some("browser retained"));
		} else {
			workspace
				.prepare_command(
					"browser-preserve",
					snapshot.revision,
					"setStanding",
					&["browser retained".into()],
				)
				.await
				.unwrap()
				.submit()
				.await
				.unwrap();
			let rival = rooms_browser::storage::session::Prepared::open(database.clone(), tab, platform.clone())
				.await
				.unwrap();
			assert_eq!(rival.seed(), identity);
			let rival_host = Host::from_seed(identity).unwrap();
			assert!(
				rival
					.start(
						rival_host.clone(),
						platform.clone(),
						limits,
						128,
						rooms_application::admission::Settings::defaults(4096, 8),
						|_, _| {}
					)
					.await
					.is_err(),
				"same-tab authority is exclusively held"
			);
			rival_host.close(PendingWork::Cancel).await.unwrap();
		}
		drop(workspace);
		opened.close().await.unwrap();
		drop(opened);
		host.close(PendingWork::Cancel).await.unwrap();
		if let Some(delayed) = delayed {
			let host = Host::from_seed_with_options(identity, rooms_glowcap::host_options()).unwrap();
			assert!(
				delayed
					.start(
						host.clone(),
						platform.clone(),
						limits,
						128,
						rooms_application::admission::Settings::defaults(4096, 8),
						|_, _| {}
					)
					.await
					.is_err(),
				"a preparation from before creation cannot replace the confirmed root"
			);
			host.close(PendingWork::Cancel).await.unwrap();
		}
	}
	database.close().await;
}
