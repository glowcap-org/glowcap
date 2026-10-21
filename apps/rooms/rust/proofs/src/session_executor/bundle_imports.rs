//! Bundle acquisition saves every exact field in one content transaction.
use super::*;

fn coordinate(slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role: custody::Role::Operations,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
fn entry(coordinate: custody::Coordinate, target: &Ref) -> Argument {
	Argument::List(vec![
		serde_json::to_string(&coordinate).unwrap().into(),
		target.clone().into(),
		Argument::Void,
	])
}
async fn bundle(host: &Host, source: &Ref, entries: Vec<Argument>) -> Result<Argument> {
	host.send(source, "import-bundle", &[Argument::List(entries)]).await
}
async fn revision(host: &Host, source: &Ref) -> i64 {
	host.send(source, "snapshot", &[]).await.unwrap().as_list().unwrap()[0]
		.as_i64()
		.unwrap()
}
struct NoCalls;
impl Content for NoCalls {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn invoke(&self, _: &mut Call<'_>, _: Invocation<'_>) -> Result<Argument> {
		panic!("import must retain held authority without calling it")
	}
}
fn registration() -> Registration {
	Registration {
		schema: TARGET.id,
		version: 1,
		graph: None,
		methods: vec![Method {
			verb: "identity".into(),
			retry: Retry::ReadOnly,
		}],
		content: Box::new(NoCalls),
	}
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn bundle_import_is_atomic_bounded_exact_idempotent_and_cold_durable() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("bundle-import");
				let mut schemas = managed::schemas();
				schemas.push(TARGET);
				let fields = session::records::FIELDS_PER_PAGE;
				let mut limits = crate::session_storage::limits_for_input(
					fields + 4,
					fields,
					// Include the one-entry-over input and acquisition wrappers
					// independently of the complete shared graph allowance.
					loam::ValueBounds {
						values: (fields + 1) * 4 + fields + 4,
						capabilities: fields + 1,
						bytes: (fields + 1) * 256 + fields * 256 + 16384,
						..Default::default()
					},
					loam::ValueBounds {
						values: fields * 4 + 1,
						capabilities: fields,
						bytes: fields * 256,
						..Default::default()
					},
				);
				limits.max_leases *= limits.max_operations;
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					3,
				)
				.await;
				let first = environment::create(&store, &policy, TARGET, b"first", 1).await;
				let second = environment::create(&store, &policy, TARGET, b"second", 1).await;
				let host = Host::from_seed([118; 32]).unwrap();
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(16384).unwrap(),
				);
				let mut attachment = store.attach(&host, vec![owner.registration(), registration()]).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				// Record revisions use the Store revision. Derive both test
				// sources before measuring contiguous content transactions.
				use rooms_application::content::permissions::Permission;
				let observer_terms = policy
					.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
					.unwrap();
				let (observer, _) = owner.derive(observer_terms, 0, ControlPowers::default()).await.unwrap();
				let import_terms = policy
					.value_for_kind(
						session::KIND,
						&[Permission::ObserveWorkspace.key(), Permission::ManageCustody.key()],
						&[],
					)
					.unwrap();
				let (importer, _) = owner.derive(import_terms, 0, ControlPowers::default()).await.unwrap();
				let (one, _) = environment::restore(&attachment, first).await;
				let (two, _) = environment::restore(&attachment, second).await;
				owner.import(coordinate(1), one.clone(), None).await.unwrap();
				let before = revision(&host, &root).await;
				// The first entry is new; the second conflicts with committed custody.
				assert!(
					bundle(
						&host,
						&root,
						vec![entry(coordinate(2), &one), entry(coordinate(1), &two)]
					)
					.await
					.is_err()
				);
				assert_eq!(
					revision(&host, &root).await,
					before,
					"refusal commits neither the first entry nor a revision"
				);
				owner.import(coordinate(2), two.clone(), None).await.unwrap();
				let before = revision(&host, &root).await;
				let entries = vec![entry(coordinate(1), &one), entry(coordinate(2), &two)];
				bundle(&host, &root, entries.clone()).await.unwrap();
				assert_eq!(revision(&host, &root).await, before, "exact retry changes no content");
				assert!(
					bundle(
						&host,
						&root,
						vec![entry(coordinate(3), &one), entry(coordinate(3), &one)]
					)
					.await
					.is_err()
				);
				let mut changed_generation = coordinate(3);
				changed_generation.key =
					custody::FieldKey::new(changed_generation.key.slot(), NonZeroU64::new(2).unwrap());
				assert!(
					bundle(
						&host,
						&root,
						vec![entry(coordinate(3), &one), entry(changed_generation, &two)]
					)
					.await
					.is_err()
				);
				assert_eq!(revision(&host, &root).await, before);
				let before = revision(&host, &root).await;
				assert!(
					bundle(&host, &observer, vec![entry(coordinate(3), &one)])
						.await
						.is_err()
				);
				assert_eq!(
					revision(&host, &root).await,
					before,
					"ObserveWorkspace cannot import a bundle"
				);
				// One complete page is admitted; a one-entry-over bundle refuses before saving.
				let maximum: Vec<_> = (10..10 + fields as u64)
					.map(|slot| entry(coordinate(slot), &one))
					.collect();
				let mut over = maximum.clone();
				over.push(entry(coordinate(10 + fields as u64), &two));
				assert!(bundle(&host, &root, over).await.is_err());
				assert_eq!(revision(&host, &root).await, before);
				bundle(&host, &root, maximum.clone()).await.unwrap();
				let after = revision(&host, &root).await;
				assert_eq!(after, before + 1, "all imports produce one content revision");
				bundle(&host, &root, maximum).await.unwrap();
				bundle(&host, &root, Vec::new()).await.unwrap();
				assert_eq!(
					revision(&host, &root).await,
					after,
					"empty and exact retries do not commit"
				);
				// Selection, acquisition and release share one candidate. Missing
				// selection cannot strand an imported field or retire the old one. status-allow: replacement state identity
				let mut intent = Intent::empty();
				intent.operations = List::new(vec![session::workspace::Operations {
					connection: None,
					kind: rooms_application::session::operations::mutation::Kind::Listeners,
					handle: coordinate(100),
				}])
				.unwrap();
				let import = || managed::Import {
					coordinate: coordinate(100),
					reference: two.clone(),
					uri: None,
				};
				let mut invalid = intent.clone();
				invalid.operations.as_mut_slice()[0].handle = coordinate(101);
				assert!(
					owner
						.acquire_workspace(&root, after as u64, vec![import()], &[coordinate(1)], &invalid)
						.await
						.is_err()
				);
				assert_eq!(revision(&host, &root).await, after);
				bundle(&host, &root, vec![entry(coordinate(1), &one)]).await.unwrap();
				assert!(
					owner
						.acquire_workspace(&importer, after as u64, vec![import()], &[coordinate(1)], &intent)
						.await
						.is_err()
				);
				assert!(
					owner
						.acquire_workspace(&root, after as u64 - 1, vec![import()], &[coordinate(1)], &intent)
						.await
						.is_err()
				);
				let workspace =
					rooms_glowcap::client::workspace::Workspace::local(host.clone(), Platform::default(), root.clone());
				let stale = workspace
					.prepare_acquisition(after as u64 - 1, vec![import()], &[coordinate(1)], &intent)
					.unwrap();
				let stale_outcome = stale.submit().await;
				assert_eq!(
					revision(&host, &root).await,
					after,
					"conflict saves no fields or content"
				);
				let acquisition = workspace
					.prepare_acquisition(after as u64, vec![import()], &[coordinate(1)], &intent)
					.unwrap();
				assert_eq!(acquisition.source(), &root);
				acquisition.submit().await.unwrap();
				assert_eq!(
					revision(&host, &root).await,
					after + 1,
					"acquisition and retirement have one commit"
				);
				acquisition.submit().await.unwrap();
				assert_eq!(
					revision(&host, &root).await,
					after + 1,
					"exact acquisition replay keeps the original revision"
				);
				owner.import(coordinate(1), two.clone(), None).await.unwrap();
				assert!(acquisition.submit().await.is_err());
				let after = revision(&host, &root).await;
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				let mut store = database.open(false, &schemas, limits).await;
				let host = Host::from_seed([118; 32]).unwrap();
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(16384).unwrap(),
				);
				let mut attachment = store.attach(&host, vec![owner.registration(), registration()]).unwrap();
				let (root, root_control) =
					environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				let (one, _) = environment::restore(&attachment, loam::Resource::decode(first.encode())).await;
				let (two, _) = environment::restore(&attachment, loam::Resource::decode(second.encode())).await;
				bundle(
					&host,
					&root,
					vec![
						entry(coordinate(1), &two),
						entry(coordinate(2), &two),
						entry(coordinate(100), &two),
					],
				)
				.await
				.unwrap();
				assert!(
					bundle(
						&host,
						&root,
						vec![entry(coordinate(1), &one), entry(coordinate(2), &one)]
					)
					.await
					.is_err()
				);
				let maximum = (10..10 + fields as u64)
					.map(|slot| entry(coordinate(slot), &one))
					.collect();
				bundle(&host, &root, maximum).await.unwrap();
				assert_eq!(
					revision(&host, &root).await,
					after,
					"cold retries preserve every exact saved field"
				);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				database.remove();
				assert!(matches!(
					stale_outcome,
					Err(rooms_glowcap::client::Error::WorkspaceConflict)
				));
			})
			.await
			.expect("bundle import has bounded progress");
		})
		.await;
}
