//! Physical bootstrap boundaries: prepared absence, confirmed identity and
//! exclusive metadata custody are exercised through the process storage owner.
use super::*;
use glowcap::{
	ErrorKind, PendingWork,
	loam::{OpenMode, Sqlite, ValueBounds},
};
use rooms_runtime::session::managed::{self, StartupAnchor};

fn limits() -> Limits {
	let mut limits = managed::storage_limits(
		24,
		24,
		8,
		32,
		ValueBounds::default(),
		ValueBounds {
			values: 512,
			capabilities: 8,
			bytes: 65536,
			..Default::default()
		},
	)
	.unwrap();
	limits.forward_reply_bytes = 65536;
	limits.pending_bytes = limits.call_bytes * limits.max_operations;
	limits.ingress_bytes = limits.pending_bytes;
	limits.max_leases *= limits.max_operations;
	limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
	limits.resident_bytes = limits.cache_slots * limits.record_bytes;
	limits
}
fn path(label: &str) -> std::path::PathBuf {
	let nonce = std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.unwrap()
		.as_nanos();
	std::env::temp_dir().join(format!("rooms-bootstrap-{label}-{}-{nonce:x}", std::process::id()))
}

#[tokio::test]
async fn session_bootstrap_preserves_private_identity_and_content_across_physical_restart() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let path = path("restart");
			let prepared = Prepared::open(&path).unwrap();
			let seed = prepared.seed();
			assert!(Prepared::open(&path).is_err(), "private metadata has one writer");
			// Crash after metadata and Store opening, before committing a root.
			let store_path = path.join(STORE);
			std::fs::create_dir(&store_path).unwrap();
			let mut store = Store::open(
				Sqlite {
					path: store_path,
					identity: prepared.bootstrap.store_identity,
					mode: OpenMode::Bootstrap,
					capacity_bytes: 32 * 1024 * 1024,
				},
				&schemas(),
				limits(),
			)
			.unwrap();
			let policy = rooms_glowcap::policy::descriptor().unwrap();
			let mut staged = store
				.stage_resource(
					&policy,
					schemas()[0],
					rooms_application::content::session::KIND,
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					4,
					prepared.bootstrap.owner_identity,
				)
				.unwrap();
			let abandoned = staged.resource().encode();
			persist(
				&prepared.directory,
				Bootstrap {
					anchor: Some(StartupAnchor {
						resource: staged.resource(),
						marker: None,
					}),
					..prepared.bootstrap
				},
			)
			.unwrap();
			staged.abort().unwrap();
			store.close().unwrap();
			drop((staged, store, prepared));
			let mut original = None;
			let mut committed_anchor = None;
			for reopening in [false, true] {
				let prepared = Prepared::open(&path).unwrap();
				assert_eq!(prepared.seed(), seed);
				let host = Host::from_seed_with_options(seed, rooms_glowcap::host_options()).unwrap();
				let mut session = prepared
					.start(host.clone(), limits(), 32 * 1024 * 1024, 128)
					.await
					.unwrap();
				let anchor = session.opened.anchor();
				assert_ne!(
					anchor.resource.encode(),
					abandoned,
					"aborted names cannot alias a fresh incarnation"
				);
				if let Some(prior) = committed_anchor {
					assert_eq!(anchor.encode(), prior, "confirmed private root is restored exactly");
				} else {
					committed_anchor = Some(anchor.encode());
				}
				let link = session
					.opened
					.publish(&glowcap::Locator::bare("iroh", "bootstrap-test"))
					.await
					.unwrap();
				if let Some(prior) = &original {
					assert_eq!(&link, prior);
				} else {
					original = Some(link);
				}
				let workspace = session.opened.workspace().unwrap();
				let snapshot = workspace.snapshot().await.unwrap();
				if reopening {
					assert_eq!(snapshot.intent.standing.text().as_str(), Some("still here"));
				} else {
					workspace
						.prepare_command("preserve", snapshot.revision, "setStanding", &["still here".into()])
						.await
						.unwrap()
						.submit()
						.await
						.unwrap();
				}
				drop(workspace);
				session.opened.close().await.unwrap();
				drop(session);
				host.close(PendingWork::Cancel).await.unwrap();
			}
			// Known absence after a confirmed live marker must never create another
			// owner. Preserve the exact failed metadata for the operator to inspect.
			let prepared = Prepared::open(&path).unwrap();
			let broken = Bootstrap {
				anchor: Some(StartupAnchor {
					resource: loam::Resource::decode(abandoned),
					marker: prepared.bootstrap.anchor.unwrap().marker,
				}),
				..prepared.bootstrap
			};
			persist(&prepared.directory, broken).unwrap();
			drop(prepared);
			let prepared = Prepared::open(&path).unwrap();
			let host = Host::from_seed(seed).unwrap();
			let error = prepared
				.start(host.clone(), limits(), 32 * 1024 * 1024, 128)
				.await
				.err()
				.expect("confirmed absence refuses");
			assert_eq!(error.kind(), ErrorKind::NotFound);
			assert_eq!(
				read(&path.join(METADATA), Bootstrap::BYTES).unwrap().unwrap(),
				broken.encode()
			);
			host.close(PendingWork::Cancel).await.unwrap();
			std::fs::remove_dir_all(path).unwrap();
		})
		.await;
}

#[test]
fn session_bootstrap_refuses_retired_documents_and_an_orphan_store() {
	let path = path("refusal");
	std::fs::create_dir_all(&path).unwrap();
	std::fs::write(path.join("grants.json"), b"{}").unwrap();
	assert!(Prepared::open(&path).is_err());
	assert!(!path.join(METADATA).exists());
	std::fs::remove_file(path.join("grants.json")).unwrap();
	std::fs::create_dir(path.join(STORE)).unwrap();
	assert!(Prepared::open(&path).is_err());
	assert!(!path.join(METADATA).exists());
	std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn session_bootstrap_refuses_lmdb_without_changing_private_metadata_or_store() {
	for name in ["data.mdb", "lock.mdb"] {
		let path = path(name);
		let prepared = Prepared::open(&path).unwrap();
		let metadata = std::fs::read(path.join(METADATA)).unwrap();
		drop(prepared);
		std::fs::create_dir(path.join(STORE)).unwrap();
		let database = path.join(STORE).join(name);
		std::fs::write(&database, b"existing LMDB bytes").unwrap();
		let error = match Prepared::open(&path) {
			Ok(_) => panic!("retired LMDB storage must be refused before opening SQLite"),
			Err(error) => error.to_string(),
		};
		assert!(error.contains("retired storage"), "{error}");
		assert!(error.contains(&path.display().to_string()), "{error}");
		assert!(error.contains("back up the entire session directory"), "{error}");
		assert_eq!(std::fs::read(path.join(METADATA)).unwrap(), metadata);
		assert_eq!(std::fs::read(database).unwrap(), b"existing LMDB bytes");
		assert!(!path.join(STORE).join("loam.sqlite").exists());
		std::fs::remove_dir_all(path).unwrap();
	}
}
