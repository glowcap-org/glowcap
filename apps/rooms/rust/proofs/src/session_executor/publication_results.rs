//! Publication captures exact directory and shared room custody before waits.
use super::*;
use rooms_application::content::{permissions::Permission, session::results::Publication};
pub(super) const PEERING: Schema = Schema {
	id: 0x535055424c303031,
	version: 1,
	max_payload: 64,
	max_edges: 2,
};
struct Peering {
	calls: Rc<Cell<usize>>,
	revokes: Rc<Cell<usize>>,
	room: Rc<std::cell::RefCell<Option<Ref>>>,
	malformed: Rc<Cell<bool>>,
}
impl Content for Peering {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(if input.verb == "publishDurableRoom" {
			vec![loam::ReferenceRequest::Restore(0)]
		} else {
			Vec::new()
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		match input.verb {
			"dm" => {
				assert_eq!(input.payload, b"direct", "replacement cannot redirect a post");
				assert_eq!(input.args, &[Argument::from("a message")]);
				self.calls.set(self.calls.get() + 1);
				Ok(Argument::Void)
			}
			"handRoom" => {
				assert_eq!(input.payload, b"direct", "replacement cannot redirect sharing");
				let [name, room] = input.args else {
					panic!("exact sharing inputs")
				};
				assert_eq!(name.as_str(), Some("room"));
				assert_eq!(Ref::try_from(room).unwrap(), *self.room.borrow().as_ref().unwrap());
				self.calls.set(self.calls.get() + 1);
				Ok(if self.malformed.get() {
					true.into()
				} else {
					Argument::Void
				})
			}
			"configure" => {
				call.append_reference(&Ref::try_from(&input.args[0]).unwrap())?;
				Ok(Argument::Void)
			}
			"publishDurableRoom" => {
				assert_eq!(input.payload, b"peering", "replacement cannot redirect publication");
				let [name, room] = input.args else {
					panic!("exact publication inputs")
				};
				assert_eq!(name.as_str(), Some("Shared room"));
				assert_eq!(
					Ref::try_from(room).unwrap(),
					*self.room.borrow().as_ref().unwrap(),
					"direct sharing preserves exact authority"
				);
				self.calls.set(self.calls.get() + 1);
				if self.malformed.get() {
					Ok(true.into())
				} else {
					call.disclose(0, false)
				}
			}
			"ready" => {
				assert_eq!(input.payload, b"lease");
				assert!(input.args.is_empty());
				Ok(Argument::Void)
			}
			"describe" => {
				assert_eq!(input.payload, b"lease");
				assert!(input.args.is_empty());
				Ok(if self.revokes.get() == 0 { "live" } else { "failed" }.into())
			}
			"revoke" => {
				assert_eq!(input.payload, b"lease");
				assert!(input.args.is_empty());
				self.revokes.set(self.revokes.get() + 1);
				Ok(Argument::Void)
			}
			_ => Err(loam::refusal("unknown publication fixture method")),
		}
	}
}
pub(super) fn registration(
	calls: Rc<Cell<usize>>,
	revokes: Rc<Cell<usize>>,
	room: Rc<std::cell::RefCell<Option<Ref>>>,
	malformed: Rc<Cell<bool>>,
) -> Registration {
	Registration {
		schema: PEERING.id,
		version: 1,
		graph: None,
		methods: [
			"configure",
			"publishDurableRoom",
			"handRoom",
			"dm",
			"ready",
			"revoke",
			"describe",
		]
		.into_iter()
		.map(|verb| Method {
			verb: verb.into(),
			retry: Retry::Idempotent,
		})
		.collect(),
		content: Box::new(Peering {
			calls,
			revokes,
			room,
			malformed,
		}),
	}
}
pub(super) fn coordinate(role: custody::Role, slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
async fn command(host: &Host, source: &Ref, id: &str, slot: u64) -> (Vec<Argument>, String) {
	let base = host.send(source, "snapshot", &[]).await.unwrap().as_list().unwrap()[0]
		.as_i64()
		.unwrap();
	let room = serde_json::to_string(&coordinate(custody::Role::RoomAccess, slot).key).unwrap();
	let publisher = serde_json::to_string(&coordinate(custody::Role::Operations, 1)).unwrap();
	let rest = ["directory", "Shared room", room.as_str(), publisher.as_str()];
	let canonical = serde_json::to_string(&(id, base, "publishPeeredRoom", rest)).unwrap();
	let mut args = vec![id.into(), base.into(), "publishPeeredRoom".into()];
	args.extend(rest.into_iter().map(Argument::from));
	(args, canonical)
}
pub(super) async fn lifecycle(host: &Host, control: &Ref, verb: &str) {
	let revision = loam::control_revision(host, control).await.unwrap();
	host.send(control, verb, &[Argument::Bytes(revision.to_be_bytes().to_vec())])
		.await
		.unwrap();
}
async fn disclosed(host: &Host, source: &Ref, id: &str, intent: &str) -> Ref {
	let answer = host
		.send(source, "effect-result", &[id.into(), intent.into()])
		.await
		.unwrap();
	let [data, fields] = answer.as_list().unwrap() else {
		panic!("lease result")
	};
	let row: Publication = serde_json::from_str(data.as_str().unwrap()).unwrap();
	assert_eq!(row.lease, key());
	let [field] = fields.as_list().unwrap() else {
		panic!("one lease")
	};
	let [coordinate, reference] = field.as_list().unwrap() else {
		panic!("lease coordinate and authority")
	};
	assert_eq!(
		custody::Coordinate::decode(coordinate.as_str().unwrap()).unwrap().role,
		custody::Role::PublicationLease
	);
	Ref::try_from(reference).unwrap()
}
async fn acquire(
	host: &Host,
	source: &Ref,
	canonical: &str,
	destination: custody::Coordinate,
	intent: &Intent,
) -> Result<Argument> {
	let base = host.send(source, "snapshot", &[]).await?.as_list().unwrap()[0].clone();
	mutate(
		host,
		source,
		"acquire-result-workspace",
		&[
			"published".into(),
			canonical.into(),
			base,
			Argument::List(vec![Argument::List(vec![
				serde_json::to_string(&coordinate(custody::Role::PublicationLease, 1))
					.unwrap()
					.into(),
				serde_json::to_string(&destination).unwrap().into(),
			])]),
			Argument::List(vec![]),
			serde_json::to_string(intent).unwrap().into(),
			Argument::Void,
		],
	)
	.await
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn publication_retains_exact_shared_room_and_live_lease_through_replacement_refusal_and_restart() {
	run().await;
}
pub(super) async fn run() {
	for malformed in [false, true] {
		run_case(malformed).await;
	}
}
async fn run_case(invalid: bool) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new(if invalid {
					"malformed-publication"
				} else {
					"publication-acquisition"
				});
				let mut schemas = managed::schemas();
				schemas.push(PEERING);
				let mut limits = crate::session_storage::limits_for(
					24,
					8,
					loam::ValueBounds {
						values: 48,
						capabilities: 12,
						bytes: 4096,
						..Default::default()
					},
				);
				limits.pending_bytes = limits.call_bytes * limits.max_operations;
				limits.ingress_bytes = limits.pending_bytes;
				limits.max_leases *= limits.max_operations;
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource =
					environment::create(&store, &policy, schemas[0], &managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay).unwrap(), 3).await;
				let mut resources = Vec::new();
				for payload in [b"peering".as_slice(), b"room", b"lease", b"replacement"] {
					resources.push(environment::create(&store, &policy, PEERING, payload, 2).await);
				}
				let host = Host::from_seed([122; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let calls = Rc::new(Cell::new(0));
				let revokes = Rc::new(Cell::new(0));
				let room = Rc::new(std::cell::RefCell::new(None));
				let malformed = Rc::new(Cell::new(invalid));
				let refuse = Rc::new(Cell::new(true));
				let mut content = owner.registration();
				content.content = Box::new(AbortAfterAdmission {
					inner: content.content,
					refuse: Rc::new(Cell::new(false)),
					refuse_settlement: refuse.clone(),
				});
				let mut attachment = store
					.attach(
						&host,
						vec![
							content,
							registration(calls.clone(), revokes.clone(), room.clone(), malformed.clone()),
						],
					)
					.unwrap();
				environment::start_live(&attachment, None, 32).await;
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let mut held = Vec::new();
				let mut controls = Vec::new();
				for resource in resources {
					let (access, control) = environment::restore(&attachment, resource).await;
					held.push(access);
					controls.push(control);
				}
				*room.borrow_mut() = Some(held[1].clone());
				host.send(&held[0], "configure", &[Argument::Reference(held[2].clone())])
					.await
					.unwrap();
				for (role, slot, reference) in [
					(custody::Role::DirectoryAccess, 1, &held[0]),
					(custody::Role::Operations, 1, &held[0]),
					(custody::Role::Operations, 2, &held[3]),
					(custody::Role::DirectoryAccess, 2, &held[3]),
					(custody::Role::RoomAccess, 1, &held[1]),
				] {
					owner
						.import(coordinate(role, slot), reference.clone(), None)
						.await
						.unwrap();
				}
				let mut intent = Case::kick().workspace(1);
				intent.conversations = List::default();
				intent.active = None;
				intent.operations = List::new(vec![rooms_application::content::session::workspace::Operations { kind: rooms_application::session::operations::mutation::Kind::Peering, handle:coordinate(custody::Role::Operations,1), connection:None }]).unwrap();
				owner.replace_workspace(&intent).await.unwrap();
				let terms = policy
					.value_for_kind(
						session::KIND,
						&session::SUPPORTED.iter().map(|p| p.key()).collect::<Vec<_>>(),
						&[],
					)
					.unwrap();
				let (source, control) = owner
					.derive(
						terms,
						1,
						ControlPowers {
							policy_ceiling: Some(terms),
							pause: true,
							resume: true,
							revoke: true,
							..Default::default()
						},
					)
					.await
					.unwrap();
				let (missing, _) = command(&host, &source, "missing", 2).await;
				assert!(mutate(&host, &source, "command", &missing).await.is_err());
				assert_eq!(calls.get(), 0);
				platform.suspended.set(true);
				let (args, canonical) = command(&host, &source, "published", 1).await;
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("pending")
				);
				assert_eq!(calls.get(), 0);
				intent.operations.as_mut_slice()[0].handle = coordinate(custody::Role::Operations,2);
				intent.directories.as_mut_slice()[0].access =
					custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap());
				owner.replace_workspace(&intent).await.unwrap();
				mutate(
					&host,
					&root,
					"release",
					&[
						serde_json::to_string(&coordinate(custody::Role::RoomAccess, 1))
							.unwrap()
							.into(),
						serde_json::to_string(&intent).unwrap().into(),
					],
				)
				.await
				.unwrap();
				platform.suspended.set(false);
				assert_eq!(
					finished(&host, &root, "published", &source).await.as_str(),
					Some("unknown")
				);
				assert_eq!(calls.get(), 1);
				if invalid {
					malformed.set(false);
					refuse.set(false);
					owner.resume_pending().unwrap();
					assert_eq!(
						finished(&host, &root, "published", &source).await.as_str(),
						Some("unknown")
					);
					assert_eq!(calls.get(), 1);
					let value = host.send(&source, "effect-result", &["published".into(), canonical.into()]).await.unwrap();
					unknown_reason(&value);
					owner.close().await.unwrap();
				} else {
					lifecycle(&host, &control, "pause").await;
					refuse.set(false);
					owner.resume_pending().unwrap();
					assert_eq!(
						finished(&host, &root, "published", &source).await.as_str(),
						Some("committed")
					);
					assert!(
						host.send(
							&source,
							"effect-result",
							&["published".into(), canonical.clone().into()]
						)
						.await
						.is_err()
					);
					lifecycle(&host, &control, "resume").await;
					let lease = disclosed(&host, &source, "published", &canonical).await;
					assert_ne!(lease, held[2]);
					assert_eq!(disclosed(&host, &source, "published", &canonical).await, lease);
					host.send(&lease, "ready", &[]).await.unwrap();
					let selected_lease = coordinate(custody::Role::PublicationLease, 9);
					owner.import_result(&source, "published", &canonical, coordinate(custody::Role::PublicationLease, 1), selected_lease).await.unwrap();
					owner.import(coordinate(custody::Role::RoomAccess, 1), held[1].clone(), None).await.unwrap();
					intent.peering = List::new(vec![rooms_application::content::session::workspace::Peering {
						id: rooms_application::fields::Text::new("published".into()).unwrap(),
						directory: rooms_application::fields::Text::new("directory".into()).unwrap(),
						room: key(), lease: custody::FieldKey::new(selected_lease.key.slot(), selected_lease.key.generation()),
						name: rooms_application::fields::Text::new("Shared room".into()).unwrap(),
					}]).unwrap();
					for changed in ["id", "directory", "name", "room"] {
						let mut wrong = intent.clone();
						let row = &mut wrong.peering.as_mut_slice()[0];
						match changed {
							"id" => row.id = rooms_application::fields::Text::new("another-operation".into()).unwrap(),
							"directory" => row.directory = rooms_application::fields::Text::new("another-directory".into()).unwrap(),
							"name" => row.name = rooms_application::fields::Text::new("another name".into()).unwrap(),
							_ => row.room = custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap()),
						}
						assert!(acquire(&host, &source, &canonical, selected_lease, &wrong).await.is_err(), "publication acquisition cannot rewrite {changed}");
					}
					acquire(&host, &source, &canonical, selected_lease, &intent).await.unwrap();
					let mut wrong = intent.clone();
					wrong.peering.as_mut_slice()[0].name = rooms_application::fields::Text::new("rewritten name".into()).unwrap();
					assert!(owner.replace_workspace(&wrong).await.is_err(), "ordinary edits cannot rewrite a selected publication's origin");
					let workspace = rooms_glowcap::client::workspace::Workspace::local(host.clone(), platform.clone(), source.clone());
					let reader = workspace.operations_reader(selected_lease, Some(rooms_application::session::operations::mutation::Kind::Peering)).await.unwrap();
					assert!(matches!(reader.publication_phase().await.unwrap(), rooms_application::session::operations::Phase::Live));
					assert!(matches!(workspace.peering_snapshot().await.unwrap(), rooms_application::session::operations::Snapshot::Peering(rows) if rows.as_slice().len() == 1));
					lifecycle(&host, &control, "pause").await;
					assert!(reader.publication_phase().await.is_err(), "paused source cannot inspect its lent publication");
					assert!(host.send(&lease, "revoke", &[]).await.is_err());
					assert_eq!(revokes.get(), 0);
					lifecycle(&host, &control, "resume").await;
					lifecycle(&host, &controls[2], "pause").await;
					assert!(host.send(&lease, "ready", &[]).await.is_err());
					lifecycle(&host, &controls[2], "resume").await;
					host.send(&lease, "revoke", &[]).await.unwrap();
					assert_eq!(revokes.get(), 1);
					assert!(matches!(reader.publication_phase().await.unwrap(), rooms_application::session::operations::Phase::Failed));
					intent.peering = List::default();
					owner.replace_workspace(&intent).await.unwrap();
					assert!(workspace.operations_reader(selected_lease, Some(rooms_application::session::operations::mutation::Kind::Peering)).await.is_err(), "removed selection cannot lend the old publication again");
					let observer = policy
						.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
						.unwrap();
					let (wrong, _) = owner.derive(observer, 0, ControlPowers::default()).await.unwrap();
					assert!(
						host.send(&wrong, "effect-result", &["published".into(), canonical.clone().into()])
							.await
							.is_err()
					);
					lifecycle(&host, &control, "revoke").await;
					assert!(host.send(&lease, "ready", &[]).await.is_err());
					assert_eq!(
						mutate(&host, &root, "command", &args).await.unwrap_err().message(),
						Some("original source capability required")
					);
					assert_eq!(calls.get(), 1, "a different source cannot resume this receipt");
					// Root-owned replay is independently inspectable after physical close.
					intent.directories.as_mut_slice()[0].access = key();
					intent.operations.as_mut_slice()[0].handle = coordinate(custody::Role::Operations,1);
					owner.replace_workspace(&intent).await.unwrap();
					owner
						.import(coordinate(custody::Role::RoomAccess, 1), held[1].clone(), None)
						.await
						.unwrap();
					let (root_args, root_canonical) = command(&host, &root, "root-publication", 1).await;
					mutate(&host, &root, "command", &root_args).await.unwrap();
					assert_eq!(
						finished(&host, &root, "root-publication", &root).await.as_str(),
						Some("committed")
					);
					let marker = attachment.live_marker().unwrap().unwrap();
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					drop(store);
					let mut reopened = database.open(false, &schemas, limits).await;
					let cold_host = Host::from_seed([122; 32]).unwrap();
					let cold_owner = managed::Session::new(
						cold_host.clone(),
						Platform::default(),
						std::num::NonZeroUsize::new(4096).unwrap(),
					);
					let mut cold_attachment = reopened.attach(&cold_host, vec![cold_owner.registration()]).unwrap();
					environment::start_live(&cold_attachment, Some(marker), 32).await;
					let (cold_root, cold_root_control) = environment::restore(&cold_attachment, resource).await;
					cold_owner.bind(cold_root.clone(), cold_root_control.clone()).unwrap();
					assert_eq!(
						finished(&cold_host, &cold_root, "root-publication", &cold_root)
							.await
							.as_str(),
						Some("committed")
					);
					assert_eq!(
						cold_host
							.send(
								&cold_root,
								"effect-result",
								&["root-publication".into(), root_canonical.into()]
							)
							.await
							.unwrap_err()
							.message(),
						Some("LiveReferenceExpired")
					);
					assert_eq!(
						mutate(&cold_host, &cold_root, "command", &root_args)
							.await
							.unwrap()
							.as_str(),
						Some("committed")
					);
					assert_eq!(calls.get(), 2);
					cold_owner.close().await.unwrap();
					cold_attachment.close().await.unwrap();
					cold_host.close(PendingWork::Cancel).await.unwrap();
					environment::close(&mut reopened).await;
					drop(reopened);
					database.remove();
					return;
				}
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				database.remove();
			})
			.await
			.expect("publication custody has bounded progress");
		})
		.await;
}
