//! Refuse browsers that ignore strict writes before any root becomes public.
use super::*;

#[wasm_bindgen::prelude::wasm_bindgen]
pub async fn rooms_session_bootstrap_durability_contract(metadata: bool) {
	tokio::task::LocalSet::new()
		.run_until(async {
			let database = rooms_browser::storage::Database::open().await.unwrap();
			let platform = rooms_browser::platform::Platform::new().unwrap();
			let tab = if metadata {
				"executor-bootstrap-metadata-durability"
			} else {
				"executor-bootstrap-store-durability"
			};
			let mut limits = crate::session_storage::limits_for(
				24,
				8,
				loam::ValueBounds {
					values: 512,
					capabilities: 8,
					bytes: 65536,
					..Default::default()
				},
			);
			// Prepared::start installs credential retention and its two change
			// feeds. Their parked receives must coexist with reconciliation and
			// cancellation, within the existing bounded operation inventory.
			limits.pending_bytes = limits.call_bytes * limits.max_operations;
			limits.ingress_bytes = limits.pending_bytes;
			limits.max_leases *= limits.max_operations;
			limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
			limits.resident_bytes = limits.cache_slots * limits.record_bytes;
			let prepared =
				rooms_browser::storage::session::Prepared::open(database.clone(), tab, platform.clone()).await;
			let (failure, seed) = if metadata {
				(
					prepared.err().expect("unsupported metadata durability must refuse"),
					None,
				)
			} else {
				let prepared = prepared.unwrap();
				let seed = prepared.seed();
				let host = Host::from_seed_with_options(seed, rooms_glowcap::host_options()).unwrap();
				let failure = prepared
					.start(
						host.clone(),
						platform.clone(),
						limits,
						128,
						rooms_application::admission::Settings::defaults(4096, 8),
						|_, _| {},
					)
					.await
					.err()
					.expect("unsupported Store durability must refuse");
				host.close(PendingWork::Cancel).await.unwrap();
				(failure, Some(seed))
			};
			assert!(failure.to_string().contains("strict"), "unexpected refusal: {failure}");
			// The harness ignores exactly the first selected write. The real
			// strict retry must preserve any already committed private identity,
			// and the failed claim must release its Web Lock and physical owner.
			let prepared = rooms_browser::storage::session::Prepared::open(database.clone(), tab, platform.clone())
				.await
				.unwrap();
			if let Some(seed) = seed {
				assert_eq!(prepared.seed(), seed);
			}
			let host = Host::from_seed_with_options(prepared.seed(), rooms_glowcap::host_options()).unwrap();
			let mut opened = prepared
				.start(
					host.clone(),
					platform,
					limits,
					128,
					rooms_application::admission::Settings::defaults(4096, 8),
					|_, _| {},
				)
				.await
				.unwrap();
			let mut expected = Intent::empty();
			expected.connection = session::workspace::Connection::Webrtc;
			assert_eq!(opened.workspace().unwrap().snapshot().await.unwrap().intent, expected);
			opened.close().await.unwrap();
			drop(opened);
			host.close(PendingWork::Cancel).await.unwrap();
			database.close().await;
		})
		.await;
}
