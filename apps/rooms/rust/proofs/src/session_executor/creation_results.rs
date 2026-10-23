//! Exact creation bootstrap and both durable roles survive interrupted recovery.
use super::*;
use rooms_application::{content::session::results::ManagedRoom, directory::creation};
mod adoption;

const CREATION: Schema = Schema {
	id: 0x5343524541544531,
	version: 1,
	max_payload: 64,
	max_edges: 3,
};
struct Directory {
	uris: [String; 2],
	calls: Rc<Cell<usize>>,
	bootstrap_calls: Rc<Cell<usize>>,
	malformed: Rc<Cell<bool>>,
}
impl Content for Directory {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(match input.verb {
			"configure" => input
				.args
				.iter()
				.map(|value| loam::ReferenceRequest::Save {
					reference: Ref::try_from(value).unwrap(),
					uri: None,
				})
				.collect(),
			creation::OPEN_MANAGED => vec![loam::ReferenceRequest::Restore(0), loam::ReferenceRequest::Restore(1)],
			_ => Vec::new(),
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		match input.verb {
			"configure" => {
				assert_eq!(input.args.len(), 2);
				for value in input.args {
					call.append_reference(&Ref::try_from(value).unwrap())?;
				}
				Ok(Argument::Void)
			}
			creation::OPEN_MANAGED => {
				assert_eq!(input.payload, b"directory", "replacement cannot redirect creation");
				assert_eq!(
					input
						.args
						.iter()
						.map(|value| value.as_str().unwrap())
						.collect::<Vec<_>>(),
					[
						"New room",
						"listed",
						"open",
						"moderated",
						"~11111111111111111111111111111111"
					]
				);
				self.calls.set(self.calls.get() + 1);
				Ok(Argument::List(vec![call.disclose(0, false)?, call.disclose(1, false)?]))
			}
			creation::AUTHORITIES => {
				assert_eq!(
					input.payload, b"bootstrap",
					"only the exact returned bootstrap may issue roles"
				);
				assert!(input.args.is_empty());
				self.bootstrap_calls.set(self.bootstrap_calls.get() + 1);
				if self.malformed.get() {
					return Ok(Argument::Boolean(true));
				}
				Ok(Argument::List(
					self.uris.iter().cloned().map(Argument::String).collect(),
				))
			}
			_ => panic!("unexpected creation method"),
		}
	}
}
fn registration(
	uris: &[String; 2],
	calls: &Rc<Cell<usize>>,
	bootstrap_calls: &Rc<Cell<usize>>,
	malformed: &Rc<Cell<bool>>,
) -> Registration {
	Registration {
		schema: CREATION.id,
		version: 1,
		graph: None,
		methods: ["configure", creation::OPEN_MANAGED, creation::AUTHORITIES]
			.into_iter()
			.map(|verb| Method {
				verb: verb.into(),
				retry: if verb == "configure" {
					Retry::Idempotent
				} else {
					Retry::ReadOnly
				},
			})
			.collect(),
		content: Box::new(Directory {
			uris: uris.clone(),
			calls: calls.clone(),
			bootstrap_calls: bootstrap_calls.clone(),
			malformed: malformed.clone(),
		}),
	}
}
fn coordinate(role: custody::Role) -> custody::Coordinate {
	custody::Coordinate { role, key: key() }
}
async fn disclosed(host: &Host, source: &Ref, intent: &str) -> (String, [Ref; 2]) {
	let reply = host
		.send(source, "effect-result", &["created".into(), intent.into()])
		.await
		.unwrap();
	let [data, fields] = reply.as_list().unwrap() else {
		panic!("typed creation result")
	};
	let data = data.as_str().unwrap();
	assert!(!data.contains("ocapn:"));
	let row: ManagedRoom = serde_json::from_str(data).unwrap();
	assert_eq!(row.room, key());
	assert_eq!(row.control, key());
	let fields = fields.as_list().unwrap();
	assert_eq!(fields.len(), 2);
	let refs = [custody::Role::RoomAccess, custody::Role::RoomControl].map(|role| {
		let value = fields
			.iter()
			.find(|field| {
				custody::Coordinate::decode(field.as_list().unwrap()[0].as_str().unwrap())
					.unwrap()
					.role == role
			})
			.unwrap();
		Ref::try_from(&value.as_list().unwrap()[1]).unwrap()
	});
	for (reference, expected) in refs.iter().zip(["room", "control"]) {
		assert_eq!(
			host.send(reference, "identity", &[]).await.unwrap().as_str(),
			Some(expected)
		);
	}
	(data.into(), refs)
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn creation_keeps_exact_bootstrap_and_both_roles_through_recovery() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("creation-results");
				let exporter = Host::from_seed([121; 32]).unwrap();
				let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9011");
				exporter.set_advertised_locator(&locator).unwrap();
				let uris = ["room", "control"].map(|identity| {
					let swiss = exporter
						.publish_durable(move || {
							Box::new(move |verb, _| match verb {
								"identity" => Ok(identity.into()),
								rooms_application::room::authority::MANAGED_IDENTITY if identity == "room" => {
									Ok("created-room".into())
								}
								rooms_application::room::authority::GOVERNS if identity == "control" => {
									Ok("created-room".into())
								}
								_ => panic!("unexpected creation authority method: {verb}"),
							})
						})
						.unwrap();
					glowcap::format_sturdyref(&locator, swiss.as_bytes(), glowcap::CaptpVersion::V1_0).unwrap()
				});
				let mut schemas = managed::schemas();
				schemas.push(CREATION);
				// Fixture topology and reply allowance do not establish production sizing.
				let mut limits = crate::session_storage::limits_for(
					32,
					16,
					loam::ValueBounds {
						values: 64,
						capabilities: 16,
						bytes: 8192,
						..Default::default()
					},
				);
				limits.pending_bytes = limits.call_bytes.checked_mul(limits.max_operations).unwrap();
				limits.ingress_bytes = limits.pending_bytes;
				limits.max_leases = limits.max_leases.checked_mul(limits.max_operations).unwrap();
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
				let mut upstream = Vec::new();
				for payload in [b"directory".as_slice(), b"room", b"bootstrap", b"replacement"] {
					upstream.push(environment::create(&store, &policy, CREATION, payload, 1).await);
				}
				let calls = Rc::new(Cell::new(0));
				let bootstrap_calls = Rc::new(Cell::new(0));
				let malformed = Rc::new(Cell::new(false));
				let host = Host::from_seed([122; 32]).unwrap();
				let gate = gate::Gate::default();
				let (dialed, accepted) = results::connect(&host, &exporter, &locator, gate.clone()).await;
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(8192).unwrap(),
				);
				let refuse = Rc::new(Cell::new(false));
				let refuse_settlement = Rc::new(Cell::new(true));
				let mut content = owner.registration();
				content.content = Box::new(AbortAfterAdmission {
					inner: content.content,
					refuse: refuse.clone(),
					refuse_settlement: refuse_settlement.clone(),
				});
				let mut attachment = store
					.attach(
						&host,
						vec![content, registration(&uris, &calls, &bootstrap_calls, &malformed)],
					)
					.unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let mut targets = Vec::new();
				for resource in upstream {
					targets.push(environment::restore(&attachment, resource).await.0);
				}
				host.send(
					&targets[0],
					"configure",
					&[targets[1].clone().into(), targets[2].clone().into()],
				)
				.await
				.unwrap();
				let original = coordinate(custody::Role::DirectoryAccess);
				owner.import(original, targets[0].clone(), None).await.unwrap();
				let replacement = custody::Coordinate {
					key: custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap()),
					..original
				};
				owner.import(replacement, targets[3].clone(), None).await.unwrap();
				let mut workspace = Intent::empty();
				workspace.directories = Case::policy(false).workspace(1).directories;
				owner.replace_workspace(&workspace).await.unwrap();
				let command = [
					"directory",
					"New room",
					"listed",
					"open",
					"moderated",
					"~11111111111111111111111111111111",
				];
				let before = host.send(&root, "snapshot", &[]).await.unwrap();
				let base = before.as_list().unwrap()[0].as_i64().unwrap();
				let mut args = vec!["created".into(), base.into(), "openManagedRoom".into()];
				args.extend(command.iter().map(|value| (*value).into()));
				let intent = serde_json::to_string(&("created", base, "openManagedRoom", command)).unwrap();
				refuse.set(true);
				assert!(mutate(&host, &root, "command", &args).await.is_err());
				assert_eq!(host.send(&root, "snapshot", &[]).await.unwrap(), before);
				assert_eq!((calls.get(), bootstrap_calls.get()), (0, 0));
				refuse.set(false);
				platform.suspended.set(true);
				mutate(&host, &root, "command", &args).await.unwrap();
				workspace.directories.as_mut_slice()[0].access =
					custody::FieldKey::new(replacement.key.slot(), replacement.key.generation());
				owner.replace_workspace(&workspace).await.unwrap();
				gate.block();
				platform.deadline_ms.set(Some(100));
				platform.deadline_after_parking.replace(Some(gate.clone()));
				platform.suspended.set(false);
				assert_eq!(finished(&host, &root, "created", &root).await.as_str(), Some("unknown"));
				assert!(gate.observed());
				assert_eq!((calls.get(), bootstrap_calls.get()), (1, 1));
				platform.deadline_ms.set(None);
				platform.deadline_after_parking.replace(None);
				gate.open();
				owner.resume_pending().unwrap();
				assert_eq!(finished(&host, &root, "created", &root).await.as_str(), Some("unknown"));
				assert_eq!((calls.get(), bootstrap_calls.get()), (1, 1));
				refuse_settlement.set(false);
				owner.resume_pending().unwrap();
				assert_eq!(
					finished(&host, &root, "created", &root).await.as_str(),
					Some("committed")
				);
				let (data, refs) = disclosed(&host, &root, &intent).await;
				for (reference, uri) in refs.iter().zip(&uris) {
					assert_eq!(*reference, host.enliven(uri).await.unwrap());
				}
				let outcome = |refs: &[Ref; 2]| {
					Argument::List(vec![
						data.clone().into(),
						Argument::List(
							[custody::Role::RoomAccess, custody::Role::RoomControl]
								.into_iter()
								.zip(refs)
								.zip(&uris)
								.map(|((role, reference), uri)| {
									Argument::List(vec![
										serde_json::to_string(&coordinate(role)).unwrap().into(),
										reference.clone().into(),
										uri.clone().into(),
									])
								})
								.collect(),
						),
					])
				};
				let settlement = |outcome| {
					vec![
						"created".into(),
						root.clone().into(),
						intent.clone().into(),
						outcome,
						Argument::Void,
					]
				};
				host.send(&root, "settle-effect", &settlement(outcome(&refs)))
					.await
					.unwrap();
				let mut swapped = refs.clone();
				swapped.swap(0, 1);
				assert!(
					host.send(&root, "settle-effect", &settlement(outcome(&swapped)))
						.await
						.is_err()
				);
				for role in [custody::Role::RoomAccess, custody::Role::RoomControl] {
					owner
						.import_result(&root, "created", &intent, coordinate(role), coordinate(role))
						.await
						.unwrap();
				}
				adoption::run(&host, &owner, &root, &intent, &mut workspace).await;
				// A malformed bootstrap acknowledgment remains the exact uncertain
				// result. Changing the exporter cannot authorize another bootstrap call.
				workspace.directories.as_mut_slice()[0].access = key();
				owner.replace_workspace(&workspace).await.unwrap();
				let base = host.send(&root, "snapshot", &[]).await.unwrap().as_list().unwrap()[0].clone();
				let mut unknown = args.clone();
				unknown[0] = "malformed".into();
				unknown[1] = base;
				malformed.set(true);
				mutate(&host, &root, "command", &unknown).await.unwrap();
				assert_eq!(
					finished(&host, &root, "malformed", &root).await.as_str(),
					Some("unknown")
				);
				assert_eq!((calls.get(), bootstrap_calls.get()), (2, 2));
				malformed.set(false);
				owner.resume_pending().unwrap();
				assert_eq!(
					finished(&host, &root, "malformed", &root).await.as_str(),
					Some("unknown")
				);
				assert_eq!(
					(calls.get(), bootstrap_calls.get()),
					(2, 2),
					"malformed observation never redispatches"
				);
				assert!(owner.close().await.is_err());
				drop(owner);
				attachment.close().await.unwrap();
				dialed.close(PendingWork::Cancel).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				environment::close(&mut store).await;
				drop(store);
				let mut store = database.open(false, &schemas, limits).await;
				let host = Host::from_seed([122; 32]).unwrap();
				let (dialed, accepted) = results::connect(&host, &exporter, &locator, gate::Gate::default()).await;
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(8192).unwrap(),
				);
				let mut attachment = store
					.attach(
						&host,
						vec![
							owner.registration(),
							registration(&uris, &calls, &bootstrap_calls, &malformed),
						],
					)
					.unwrap();
				let (root, root_control) =
					environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				let (cold, refs) = disclosed(&host, &root, &intent).await;
				assert_eq!(cold, data);
				for (reference, uri) in refs.iter().zip(&uris) {
					assert_eq!(*reference, host.enliven(uri).await.unwrap());
				}
				assert_eq!(
					mutate(&host, &root, "command", &args).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(
					mutate(&host, &root, "command", &unknown).await.unwrap().as_str(),
					Some("unknown")
				);
				assert_eq!(
					(calls.get(), bootstrap_calls.get()),
					(2, 2),
					"cold replay cannot recreate or rebootstrap"
				);
				for role in [custody::Role::RoomAccess, custody::Role::RoomControl] {
					owner
						.import_result(&root, "created", &intent, coordinate(role), coordinate(role))
						.await
						.unwrap();
				}
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				dialed.close(PendingWork::Cancel).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				exporter.close(PendingWork::Cancel).await.unwrap();
				database.remove();
			})
			.await
			.expect("creation recovery makes bounded progress");
		})
		.await;
}
