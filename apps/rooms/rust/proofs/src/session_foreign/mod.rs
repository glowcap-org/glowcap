//! Accepted maximum foreign recipe capacity, with real source owner restarts.
mod content;
#[cfg(target_arch = "wasm32")]
mod reload;
mod targets;
use crate::{session_capacity, session_storage};
#[cfg(not(target_arch = "wasm32"))]
use glowcap::loam::OpenMode;
use glowcap::{
	Argument, Host, PendingWork, Ref, Session,
	loam::{Limits, Policy, Resource, Store, ValueBounds},
};
use rooms_application::content::session::{self, records};
use std::{cell::Cell, rc::Rc};

const FIELDS: usize = session_capacity::FIELDS;
fn limits(capacity: usize) -> Limits {
	let mut limits = session_storage::limits_for(
		FIELDS,
		FIELDS,
		ValueBounds {
			values: FIELDS + 4,
			capabilities: FIELDS,
			..ValueBounds::default()
		},
	);
	assert_eq!(limits.max_changes, 3662);
	limits.max_changes = capacity;
	limits
}
struct Database {
	#[cfg(not(target_arch = "wasm32"))]
	path: std::path::PathBuf,
	#[cfg(not(target_arch = "wasm32"))]
	disk: crate::disk::Disk,
}
impl Database {
	#[cfg(not(target_arch = "wasm32"))]
	fn new(disk: crate::disk::Disk) -> Self {
		let nonce = std::time::SystemTime::now()
			.duration_since(std::time::UNIX_EPOCH)
			.unwrap()
			.as_nanos();
		let path = std::env::temp_dir().join(format!(
			"rooms-session-foreign-{disk:?}-{}-{nonce:x}",
			std::process::id()
		));
		std::fs::create_dir(&path).unwrap();
		Self { path, disk }
	}
	#[cfg(target_arch = "wasm32")]
	fn new() -> Self {
		Self {}
	}
	async fn open(&self, create: bool, capacity: usize) -> Store {
		#[cfg(not(target_arch = "wasm32"))]
		{
			let mode = if create { OpenMode::Create } else { OpenMode::Open };
			self.disk
				.open(
					self.path.clone(),
					[92; 16],
					mode,
					&session_storage::schemas(),
					limits(capacity),
				)
				.unwrap()
		}
		#[cfg(target_arch = "wasm32")]
		{
			Store::open(
				"rooms-session-foreign",
				[92; 16],
				create,
				&session_storage::schemas(),
				limits(capacity),
			)
			.await
			.unwrap()
		}
	}
	fn remove(self) {
		#[cfg(not(target_arch = "wasm32"))]
		std::fs::remove_dir_all(self.path).unwrap();
	}
}
async fn close(store: &mut Store) {
	#[cfg(not(target_arch = "wasm32"))]
	store.close().unwrap();
	#[cfg(target_arch = "wasm32")]
	store.close().await.unwrap();
}
async fn inspect(targets: &targets::Targets, session: &Session, root: &Ref, revision: u64) -> (i64, i64) {
	inspect_uris(&targets.uris[revision as usize - 1], session, root, revision).await
}
async fn inspect_uris(uris: &[String], session: &Session, root: &Ref, revision: u64) -> (i64, i64) {
	let result = session
		.send(root, "read", &[Argument::Integer(revision as i64)])
		.await
		.unwrap();
	let values = result.as_list().unwrap();
	assert_eq!(values.len(), 3);
	let fields = values[2].as_list().unwrap();
	assert_eq!(fields.len(), FIELDS);
	// Actual Loam restoration completes before any expected field is enlivened.
	// Compare every coordinate's exact authority, not just a distinct population.
	let expected = targets::references(session, uris).await;
	assert_eq!(expected.len(), fields.len());
	for (field, expected) in fields.iter().zip(expected) {
		assert_eq!(Ref::try_from(field).unwrap(), expected);
	}
	for index in [0, FIELDS / 2, FIELDS - 1] {
		let reference = Ref::try_from(&fields[index]).unwrap();
		let expected = (revision as usize - 1) * FIELDS + index;
		assert_eq!(
			session.send(&reference, "identity", &[]).await.unwrap().as_i64(),
			Some(expected as i64)
		);
	}
	(values[0].as_i64().unwrap(), values[1].as_i64().unwrap())
}
async fn sequence(session: &Session, root: &Ref) -> i64 {
	session
		.send(root, "mutation-sequence", &[])
		.await
		.unwrap()
		.as_i64()
		.unwrap()
}
async fn stamp(session: &Session, root: &Ref) -> (i64, i64) {
	let result = session.send(root, "stamp", &[]).await.unwrap();
	let values = result.as_list().unwrap();
	(values[0].as_i64().unwrap(), values[1].as_i64().unwrap())
}
async fn run(database: Database, phases: &[usize], inspect_baseline: bool) {
	let targets = targets::Targets::new();
	let mut resource = None;
	let mut original_stamp = None;
	for &phase in phases {
		let capacity = if phase == 1 { 3661 } else { 3662 };
		let mut store = database.open(phase == 0, capacity).await;
		let source = Host::from_seed([93; 32]).unwrap();
		let (mut session, mut accepted) = targets.connect(&source).await;
		// Only the fresh replacement population is imported before a call.
		// Old graph fields must restore from their actual persisted recipes.
		let population = if phase == 3 {
			Vec::new()
		} else {
			targets.population(&session, usize::from(phase != 0)).await
		};
		if resource.is_none() {
			let policy = Policy::new([94; 16], &[10, 20], &[]).unwrap();
			let payload = records::encode_workspace(&session_capacity::intent(), Default::default())
				.unwrap()
				.remove(0);
			#[cfg(not(target_arch = "wasm32"))]
			let created = store
				.create_resource(&policy, session_storage::schemas()[0], session::KIND, &payload, 2)
				.unwrap();
			#[cfg(target_arch = "wasm32")]
			let created = store
				.create_resource(&policy, session_storage::schemas()[0], session::KIND, &payload, 2)
				.await
				.unwrap();
			resource = Some(created.encode());
		}
		let invocations = Rc::new(Cell::new(0));
		let wrong_uri = Rc::new(Cell::new(false));
		let application = content::Application {
			targets: population,
			invocations: Rc::clone(&invocations),
			wrong_uri: Rc::clone(&wrong_uri),
		};
		let mut attachment = store.attach(&source, vec![content::registration(application)]).unwrap();
		#[cfg(not(target_arch = "wasm32"))]
		let (root, control) = attachment.restore(Resource::decode(resource.unwrap())).await.unwrap();
		#[cfg(target_arch = "wasm32")]
		let (root, control) = attachment.restore(Resource::decode(resource.unwrap())).await.unwrap();
		let revision = if phase == 0 { 1 } else { 2 };
		let mutation = [
			Argument::Integer(revision),
			Argument::String("write".into()),
			Argument::Integer(revision),
		];
		if phase == 0 {
			wrong_uri.set(true);
			let failure = session.send(&root, "mutate", &mutation).await.unwrap_err();
			assert_eq!(failure.message(), Some("DurableReferenceMismatch"));
			assert_eq!(invocations.get(), 0);
			assert_eq!(sequence(&session, &root).await, 1);
			wrong_uri.set(false);
		}
		if phase == 1 {
			let failure = session.send(&root, "mutate", &mutation).await.unwrap_err();
			assert_eq!(failure.message(), Some("ChangeCapacity"));
			assert_eq!(invocations.get(), 1);
			assert_eq!(sequence(&session, &root).await, 2);
			assert_eq!(inspect(&targets, &session, &root, 1).await, original_stamp.unwrap());
		} else if phase < 3 {
			assert_eq!(
				session.send(&root, "mutate", &mutation).await.unwrap().as_i64(),
				Some((records::MAX_PAGES - 1) as i64)
			);
			assert_eq!(invocations.get(), 1);
			if phase == 0 {
				original_stamp = Some(if inspect_baseline {
					inspect(&targets, &session, &root, revision as u64).await
				} else {
					// Refusal/replacement traces verify every restored field after
					// the cold operation. Capture their initial revision separately.
					stamp(&session, &root).await
				});
			}
			assert_eq!(sequence(&session, &root).await, revision + 1);
		} else {
			// The cold source has restored no foreign field. Disconnect the
			// exporter before copying every exact recipe through graph staging.
			session.close(PendingWork::Cancel).await.unwrap();
			accepted.close(PendingWork::Cancel).await.unwrap();
			let sequence = source.send(&root, "mutation-sequence", &[]).await.unwrap();
			source
				.send(&root, "mutate", &[sequence, "retain".into()])
				.await
				.unwrap();
			(session, accepted) = targets.connect(&source).await;
			inspect(&targets, &session, &root, 2).await;
			assert_eq!(invocations.get(), 0);
		}
		if phase != 1 {
			// Recover the first exact result even after graph replacement and
			// source restart. This has no graph/reference-declaration dependency.
			let first = [
				Argument::Integer(1),
				Argument::String("write".into()),
				Argument::Integer(1),
			];
			let before = invocations.get();
			assert_eq!(
				session.send(&root, "mutate", &first).await.unwrap().as_i64(),
				Some((records::MAX_PAGES - 1) as i64)
			);
			assert_eq!(invocations.get(), before);
		}
		drop((root, control));
		attachment.close().await.unwrap();
		drop(attachment);
		session.close(PendingWork::Cancel).await.unwrap();
		accepted.close(PendingWork::Cancel).await.unwrap();
		drop((session, accepted));
		source.close(PendingWork::Cancel).await.unwrap();
		drop(source);
		close(&mut store).await;
		drop(store);
	}
	targets.close().await;
	database.remove();
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn maximum_session_foreign_admission_preserves_every_exact_identity_on_sqlite() {
	let database = Database::new(crate::disk::Disk::Sqlite);
	tokio::task::LocalSet::new().run_until(run(database, &[0], true)).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn maximum_session_foreign_admission_preserves_every_exact_identity_on_lmdb() {
	let database = Database::new(crate::disk::Disk::Lmdb);
	tokio::task::LocalSet::new().run_until(run(database, &[0], true)).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn maximum_session_foreign_capacity_refusal_preserves_the_cold_graph_on_sqlite() {
	let database = Database::new(crate::disk::Disk::Sqlite);
	tokio::task::LocalSet::new()
		.run_until(run(database, &[0, 1], false))
		.await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn maximum_session_foreign_capacity_refusal_preserves_the_cold_graph_on_lmdb() {
	let database = Database::new(crate::disk::Disk::Lmdb);
	tokio::task::LocalSet::new()
		.run_until(run(database, &[0, 1], false))
		.await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn maximum_session_foreign_replacement_and_cold_copy_preserve_receipt_replay_on_sqlite() {
	let database = Database::new(crate::disk::Disk::Sqlite);
	tokio::task::LocalSet::new()
		.run_until(run(database, &[0, 2, 3], false))
		.await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn maximum_session_foreign_replacement_and_cold_copy_preserve_receipt_replay_on_lmdb() {
	let database = Database::new(crate::disk::Disk::Lmdb);
	tokio::task::LocalSet::new()
		.run_until(run(database, &[0, 2, 3], false))
		.await;
}
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub async fn rooms_session_foreign_contract() {
	tokio::task::LocalSet::new()
		.run_until(run(Database::new(), &[0, 1, 2, 3], true))
		.await;
}
