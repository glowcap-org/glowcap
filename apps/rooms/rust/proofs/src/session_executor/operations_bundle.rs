//! Pasted credentials acquire exact foreign custody, with atomic replacement.
use super::*;
use glowcap::{CaptpVersion, Locator};
use rooms_application::{content::permissions::Permission, server::operations::bundle::Draft};
use rooms_glowcap::client::{Client, directory::Directory};

async fn snapshot(host: &Host, source: &Ref) -> (u64, Intent) {
	let value = host.send(source, "snapshot", &[]).await.unwrap();
	let [revision, intent] = value.as_list().unwrap() else {
		panic!("workspace snapshot")
	};
	(
		revision.as_i64().unwrap() as u64,
		Intent::decode(intent.as_str().unwrap()).unwrap(),
	)
}
fn first(generation: u64) -> custody::FieldKey<()> {
	custody::FieldKey::new(NonZeroU64::new(10).unwrap(), NonZeroU64::new(generation).unwrap())
}
fn bundle<'a>(
	_directory: &'a Directory<Platform>,
	_locator: &'a Locator,
	draft: &'a Draft,
	generation: u64,
) -> managed::OperationsBundle<'a> {
	managed::OperationsBundle {
		draft,
		first: first(generation),
	}
}
async fn check_custody(
	owner: &managed::Session<Platform>,
	host: &Host,
	_locator: &Locator,
	draft: &Draft,
	generation: u64,
) {
	for (index, (label, uri)) in draft.entries().enumerate() {
		let coordinate = custody::Coordinate {
			role: if label == "operator" {
				custody::Role::Operator
			} else {
				custody::Role::Operations
			},
			key: custody::FieldKey::new(
				NonZeroU64::new(10 + index as u64).unwrap(),
				NonZeroU64::new(generation).unwrap(),
			),
		};
		let reference = host.enliven(uri).await.unwrap();
		// Occupied import comparison restores the saved field. Matching these
		// actual references proves exact acquisition, including after reopen.
		owner.import(coordinate, reference, Some(uri.into())).await.unwrap();
	}
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn operations_bundle_acquires_exact_peer_custody_and_replaces_atomically() {
	run().await;
}

pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("operations-bundle");
				let exporter = Host::from_seed([119; 32]).unwrap();
				let locator = Locator::bare("tcp", "127.0.0.1:9011");
				exporter.set_advertised_locator(&locator).unwrap();
				let lookups = Rc::new(Cell::new(0));
				let calls = Rc::new(Cell::new(0));
				let mut draft = Draft::default();
				for label in ["operator", "listeners", "diagnostics", "irc", "peering", "trace"] {
					let lookups = lookups.clone();
					let calls = calls.clone();
					let swiss = exporter
						.publish_durable(move || {
							lookups.set(lookups.get() + 1);
							let calls = calls.clone();
							Box::new(move |_, _| {
								calls.set(calls.get() + 1);
								Ok(label.into())
							})
						})
						.unwrap();
					draft
						.insert(
							label,
							&glowcap::format_sturdyref(&locator, swiss.as_bytes(), CaptpVersion::V1_0).unwrap(),
						)
						.unwrap();
				}
				let directory_name = exporter
					.publish_durable(|| Box::new(|_, _| panic!("boot lookup must not call the public directory")))
					.unwrap();
				let directory_uri =
					glowcap::format_sturdyref(&locator, directory_name.as_bytes(), CaptpVersion::V1_0).unwrap();
				let schemas = managed::schemas();
				// Abandoned observations and exact replay overlap, as they do in
				// the production front. Use its derived managed-call windows.
				let limits = managed::production_limits().unwrap();
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					2,
				)
				.await;
				let host = Host::from_seed([120; 32]).unwrap();
				let (dialed, accepted) = results::connect(&host, &exporter, &locator, gate::Gate::default()).await;
				let directory = Directory::new(
					Client::new(dialed, Platform::default()),
					host.enliven(&directory_uri).await.unwrap(),
				);
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(16384).unwrap(),
				);
				let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				let terms = policy
					.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
					.unwrap();
				let (observer, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
				// Derive sources before the first content transaction. Content
				// revisions use the Store revision, including grant transactions.
				owner.initialize().await.unwrap();
				let (base, empty) = snapshot(&host, &root).await;
				let before = lookups.get();
				let mut overflow = bundle(&directory, &locator, &draft, 1);
				overflow.first =
					custody::FieldKey::new(NonZeroU64::new(u64::MAX).unwrap(), NonZeroU64::new(1).unwrap());
				assert!(owner.acquire_operations(&root, base, &empty, overflow).await.is_err());
				assert_eq!(
					lookups.get(),
					before,
					"validate every coordinate before the first lookup"
				);
				let wrong_peer = Locator::bare("tcp", "127.0.0.1:9012");
				assert!(
					owner
						.acquire_operations(&root, u64::MAX, &empty, bundle(&directory, &locator, &draft, 1))
						.await
						.is_err()
				);
				let mut oversized = empty.clone();
				oversized.operators = List::new(
					(100..164)
						.map(|slot| custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()))
						.collect(),
				)
				.unwrap();
				oversized.operations = List::new(vec![session::workspace::Operations {
					connection: None,
					kind: rooms_application::session::operations::mutation::Kind::Trace,
					handle: custody::Coordinate {
						role: custody::Role::Operations,
						key: custody::FieldKey::new(NonZeroU64::new(200).unwrap(), NonZeroU64::new(1).unwrap()),
					},
				}])
				.unwrap();
				assert!(
					owner
						.acquire_operations(&root, base, &oversized, bundle(&directory, &locator, &draft, 1))
						.await
						.is_err()
				);
				assert_eq!(
					lookups.get(),
					before,
					"revision and retirement bounds refuse before lookup"
				);
				let mut foreign = Draft::default();
				foreign
					.insert(
						"operator",
						&glowcap::format_sturdyref(&wrong_peer, b"wrong-peer", CaptpVersion::V1_0).unwrap(),
					)
					.unwrap();
				assert!(
					owner
						.acquire_operations(&root, base, &empty, bundle(&directory, &locator, &foreign, 1))
						.await
						.is_err()
				);
				assert_eq!(
					lookups.get(),
					before,
					"only the exact recipe exporter may answer lookup"
				);
				assert!(
					owner
						.acquire_operations(&observer, base, &empty, bundle(&directory, &locator, &draft, 1))
						.await
						.is_err()
				);
				assert_eq!(
					snapshot(&host, &root).await,
					(base, empty.clone()),
					"boot credentials cannot replace session admission"
				);
				let mut partial = Draft::default();
				let (_, swiss) = draft.entries().next().unwrap();
				partial.insert("operator", swiss).unwrap();
				partial
					.insert(
						"listeners",
						&glowcap::format_sturdyref(&locator, b"missing-publication", CaptpVersion::V1_0).unwrap(),
					)
					.unwrap();
				assert!(
					owner
						.acquire_operations(&root, base, &empty, bundle(&directory, &locator, &partial, 1))
						.await
						.is_err()
				);
				assert_eq!(
					snapshot(&host, &root).await,
					(base, empty.clone()),
					"a later lookup refusal saves no earlier field"
				);
				let next = owner
					.acquire_operations(&root, base, &empty, bundle(&directory, &locator, &draft, 1))
					.await
					.unwrap();
				assert_eq!(next.operators.as_slice().len(), 1);
				assert_eq!(next.operations.as_slice().len(), 5);
				assert!(!serde_json::to_string(&next).unwrap().contains("ocapn:"));
				let (after, committed) = snapshot(&host, &root).await;
				assert_eq!(
					after,
					base + 1,
					"six acquisitions and their selection share one transaction"
				);
				assert_eq!(committed, next);
				check_custody(&owner, &host, &locator, &draft, 1).await;
				owner
					.acquire_operations(&root, base, &empty, bundle(&directory, &locator, &draft, 1))
					.await
					.unwrap();
				assert_eq!(
					snapshot(&host, &root).await,
					(after, next.clone()),
					"exact retry has no content revision"
				);
				assert_eq!(
					calls.get(),
					0,
					"acquisition retains authority without invoking its verbs"
				);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				directory.client().session().close(PendingWork::Cancel).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				drop(directory);
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				let mut store = database.open(false, &schemas, limits).await;
				let host = Host::from_seed([120; 32]).unwrap();
				let (dialed, accepted) = results::connect(&host, &exporter, &locator, gate::Gate::default()).await;
				let directory = Directory::new(
					Client::new(dialed, Platform::default()),
					host.enliven(&directory_uri).await.unwrap(),
				);
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(16384).unwrap(),
				);
				let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
				let (root, root_control) =
					environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				check_custody(&owner, &host, &locator, &draft, 1).await;
				owner
					.acquire_operations(&root, base, &empty, bundle(&directory, &locator, &draft, 1))
					.await
					.unwrap();
				assert_eq!(
					snapshot(&host, &root).await,
					(after, next.clone()),
					"cold retry restores each original foreign target"
				);
				let replacement = owner
					.acquire_operations(&root, after, &next, bundle(&directory, &locator, &draft, 2))
					.await
					.unwrap();
				assert_eq!(snapshot(&host, &root).await, (after + 1, replacement.clone()));
				assert!(
					owner
						.acquire_operations(&root, base, &empty, bundle(&directory, &locator, &draft, 1))
						.await
						.is_err(),
					"an old attempt cannot undo intervening generation replacement"
				);
				check_custody(&owner, &host, &locator, &draft, 2).await;
				assert!(
					owner
						.acquire_operations(
							&root,
							after + 1,
							&replacement,
							bundle(&directory, &locator, &partial, 3)
						)
						.await
						.is_err()
				);
				assert_eq!(
					snapshot(&host, &root).await,
					(after + 1, replacement.clone()),
					"replacement refusal preserves predecessor selection and custody"
				);
				check_custody(&owner, &host, &locator, &draft, 2).await;
				let removed = owner
					.acquire_operations(
						&root,
						after + 1,
						&replacement,
						bundle(&directory, &locator, &Draft::default(), 3),
					)
					.await
					.unwrap();
				assert_eq!(removed, empty);
				assert_eq!(snapshot(&host, &root).await, (after + 2, empty));
				assert_eq!(calls.get(), 0, "retirement never invokes predecessor authority");
				attachment.start_live(None, 32).unwrap();
				super::operations_selection::run(&owner, &host, &root).await;
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				directory.client().session().close(PendingWork::Cancel).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				drop(directory);
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				exporter.close(PendingWork::Cancel).await.unwrap();
				database.remove();
			})
			.await
			.expect("operations acquisition makes bounded progress");
		})
		.await;
}
