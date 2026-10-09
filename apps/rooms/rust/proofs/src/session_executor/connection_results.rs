//! Exact connection acquisition stays private across replacement and restart.
use super::*;
use rooms_application::{
	content::session::{results::Connection, workspace::Operations},
	session::operations::mutation::Kind,
};

// The gateway retains one returned connection beside its managed binding.
const GATEWAY: Schema = Schema {
	id: 0x53495243434f4e31,
	max_edges: 2,
	..TARGET
};

struct Gateway {
	acquisitions: Rc<Cell<usize>>,
	leases: Rc<Cell<usize>>,
	malformed: bool,
}
impl Content for Gateway {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(match input.verb {
			"configure" => vec![loam::ReferenceRequest::Save {
				reference: Ref::try_from(&input.args[0]).unwrap(),
				uri: None,
			}],
			"connection" => vec![loam::ReferenceRequest::Restore(0)],
			_ => Vec::new(),
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		match input.verb {
			"configure" => {
				call.append_reference(&Ref::try_from(&input.args[0]).unwrap())?;
				Ok(Argument::Void)
			}
			"connection" => {
				assert_eq!(input.payload, b"original");
				assert_eq!(input.args, &[Argument::from("network")]);
				self.acquisitions.set(self.acquisitions.get() + 1);
				if self.malformed {
					Ok(true.into())
				} else {
					call.disclose(0, false)
				}
			}
			"addLease" => {
				assert_eq!(input.payload, b"connection");
				assert_eq!(input.args, &[Argument::from("{}")]);
				self.leases.set(self.leases.get() + 1);
				Ok("network/#channel".into())
			}
			_ => Err(loam::refusal("unsupported gateway fixture method")),
		}
	}
}
fn registration(acquisitions: Rc<Cell<usize>>, leases: Rc<Cell<usize>>, malformed: bool) -> Registration {
	Registration {
		schema: GATEWAY.id,
		version: 1,
		graph: None,
		methods: ["configure", "connection", "addLease"]
			.into_iter()
			.map(|verb| Method {
				verb: verb.into(),
				retry: Retry::Idempotent,
			})
			.collect(),
		content: Box::new(Gateway {
			acquisitions,
			leases,
			malformed,
		}),
	}
}
fn coordinate(role: custody::Role, slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
async fn command(
	host: &Host,
	source: &Ref,
	id: &str,
	handle: custody::Coordinate,
	kind: &str,
	verb: &str,
	argument: &str,
) -> (Vec<Argument>, String) {
	let snapshot = host.send(source, "snapshot", &[]).await.unwrap();
	let base = snapshot.as_list().unwrap()[0].as_i64().unwrap();
	let rest = [
		serde_json::to_string(&handle).unwrap(),
		kind.into(),
		verb.into(),
		argument.into(),
	];
	let canonical = serde_json::to_string(&(id, base, "operations", &rest)).unwrap();
	let mut args = vec![id.into(), base.into(), "operations".into()];
	args.extend(rest.into_iter().map(Argument::from));
	(args, canonical)
}
async fn lifecycle(host: &Host, control: &Ref, verb: &str) {
	super::publication_results::lifecycle(host, control, verb).await;
}
async fn acquisition(
	host: &Host,
	source: &Ref,
	canonical: &str,
	result: custody::Coordinate,
	destination: custody::Coordinate,
	intent: &Intent,
) -> Result<Argument> {
	let base = host.send(source, "snapshot", &[]).await?.as_list().unwrap()[0].clone();
	mutate(
		host,
		source,
		"acquire-result-workspace",
		&[
			"acquire-live".into(),
			canonical.into(),
			base,
			Argument::List(vec![Argument::List(vec![
				serde_json::to_string(&result).unwrap().into(),
				serde_json::to_string(&destination).unwrap().into(),
			])]),
			Argument::List(vec![]),
			serde_json::to_string(intent).unwrap().into(),
			Argument::Void,
		],
	)
	.await
}
async fn edit_policy(host: &Host, control: &Ref, terms: loam::PolicyValue) {
	let sequence = host
		.send(control, "mutation-sequence", &[])
		.await
		.unwrap()
		.as_i64()
		.unwrap() as u32;
	let revision = loam::control_revision(host, control).await.unwrap();
	host.send(control, "mutate", &terms.set_policy_arguments(sequence, revision))
		.await
		.unwrap();
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn acquired_irc_connections_keep_exact_source_interface_and_live_custody() {
	run().await;
}
pub(super) async fn run() {
	for malformed in [false, true] {
		tokio::task::LocalSet::new()
			.run_until(async {
				environment::within(10_000, async {
					let database = Database::new("irc-connection-acquisition");
					let mut schemas = managed::schemas();
					schemas.push(GATEWAY);
					let mut limits = crate::session_storage::limits_for(
						24,
						8,
						loam::ValueBounds {
							values: 64,
							capabilities: 8,
							bytes: 8192,
							..Default::default()
						},
					);
					limits.max_leases *= limits.max_operations;
					limits.pending_bytes = limits.call_bytes * limits.max_operations;
					limits.ingress_bytes = limits.pending_bytes;
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
					let original = environment::create(&store, &policy, GATEWAY, b"original", 3).await;
					let replacement = environment::create(&store, &policy, GATEWAY, b"replacement", 3).await;
					let connection = environment::create(&store, &policy, GATEWAY, b"connection", 3).await;
					let host = Host::from_seed([114; 32]).unwrap();
					let platform = Platform::default();
					let owner = managed::Session::new(
						host.clone(),
						platform.clone(),
						std::num::NonZeroUsize::new(8192).unwrap(),
					);
					let acquisitions = Rc::new(Cell::new(0));
					let leases = Rc::new(Cell::new(0));
					let mut attachment = store
						.attach(
							&host,
							vec![
								owner.registration(),
								registration(acquisitions.clone(), leases.clone(), malformed),
							],
						)
						.unwrap();
					attachment.start_live(None, 32).unwrap();
					let (root, root_control) = environment::restore(&attachment, resource).await;
					owner.bind(root.clone(), root_control.clone()).unwrap();
					owner.initialize().await.unwrap();
					let (gateway, _) = environment::restore(&attachment, original).await;
					let (next_gateway, _) = environment::restore(&attachment, replacement).await;
					let (connection, _) = environment::restore(&attachment, connection).await;
					host.send(&gateway, "configure", &[connection.into()]).await.unwrap();
					let original_handle = coordinate(custody::Role::Operations, 1);
					let replacement_handle = coordinate(custody::Role::Operations, 2);
					owner.import(original_handle, gateway, None).await.unwrap();
					owner.import(replacement_handle, next_gateway, None).await.unwrap();
					let mut intent = Intent::empty();
					intent.operations = List::new(vec![Operations {
						connection: None,
						kind: Kind::IrcGateway,
						handle: original_handle,
					}])
					.unwrap();
					owner.replace_workspace(&intent).await.unwrap();
					let permissions: Vec<_> = session::SUPPORTED.iter().map(|permission| permission.key()).collect();
					let terms = policy.value_for_kind(session::KIND, &permissions, &[]).unwrap();
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
					let (other, _) = owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
					let (args, _) = command(
						&host,
						&source,
						"acquire",
						original_handle,
						"ircGateway",
						"connection",
						"network",
					)
					.await;
					platform.suspended.set(true);
					mutate(&host, &source, "command", &args).await.unwrap();
					intent.operations.as_mut_slice()[0].handle = replacement_handle;
					owner.replace_workspace(&intent).await.unwrap();
					lifecycle(&host, &control, "pause").await;
					platform.suspended.set(false);
					assert_eq!(
						finished(&host, &other, "acquire", &source).await.as_str(),
						Some("unsent")
					);
					assert_eq!(acquisitions.get(), 0, "paused source cannot dispatch");
					lifecycle(&host, &control, "resume").await;
					intent.operations.as_mut_slice()[0].handle = original_handle;
					owner.replace_workspace(&intent).await.unwrap();
					let (args, canonical) = command(
						&host,
						&source,
						"acquire-live",
						original_handle,
						"ircGateway",
						"connection",
						"network",
					)
					.await;
					platform.suspended.set(true);
					mutate(&host, &source, "command", &args).await.unwrap();
					intent.operations.as_mut_slice()[0].handle = replacement_handle;
					owner.replace_workspace(&intent).await.unwrap();
					platform.suspended.set(false);
					assert_eq!(
						finished(&host, &other, "acquire-live", &source).await.as_str(),
						Some(if malformed { "unknown" } else { "committed" })
					);
					assert_eq!(acquisitions.get(), 1);
					assert_eq!(
						mutate(&host, &source, "command", &args).await.unwrap().as_str(),
						Some(if malformed { "unknown" } else { "committed" })
					);
					assert_eq!(acquisitions.get(), 1, "receipt replay never repeats acquisition");
					let result_handle = coordinate(custody::Role::IrcConnection, 1);
					let selected_handle = coordinate(custody::Role::IrcConnection, 9);
					if !malformed {
						assert!(
							host.send(
								&other,
								"effect-result",
								&["acquire-live".into(), canonical.clone().into()]
							)
							.await
							.is_err()
						);
						let reply = host
							.send(
								&source,
								"effect-result",
								&["acquire-live".into(), canonical.clone().into()],
							)
							.await
							.unwrap();
						let [data, fields] = reply.as_list().unwrap() else {
							panic!("private connection result")
						};
						let row: Connection = serde_json::from_str(data.as_str().unwrap()).unwrap();
						assert_eq!(row.connection.slot(), result_handle.key.slot());
						assert!(
							fields.as_list().unwrap().is_empty(),
							"raw connections cannot bypass UseOperations"
						);
						assert!(
							owner
								.import_result(&other, "acquire-live", &canonical, result_handle, selected_handle)
								.await
								.is_err()
						);
						assert!(
							owner
								.import_result(
									&source,
									"acquire-live",
									&canonical,
									result_handle,
									coordinate(custody::Role::Operations, 9)
								)
								.await
								.is_err()
						);
						owner
							.import_result(&source, "acquire-live", &canonical, result_handle, selected_handle)
							.await
							.unwrap();
						owner
							.import_result(&source, "acquire-live", &canonical, result_handle, selected_handle)
							.await
							.unwrap();
						intent.operations = List::new(vec![Operations {
							connection: Some(rooms_application::content::session::workspace::ConnectionSelection {
								operation: rooms_application::fields::Text::new("acquire-live".into()).unwrap(),
								gateway: coordinate(custody::Role::Operations, 1),
								id: rooms_application::fields::Text::new("network".into()).unwrap(),
							}),
							kind: Kind::IrcConnection,
							handle: selected_handle,
						}])
						.unwrap();
						for mismatch in 0..3 {
							let mut invalid = intent.clone();
							let metadata = invalid.operations.as_mut_slice()[0].connection.as_mut().unwrap();
							match mismatch {
								0 => {
									metadata.operation =
										rooms_application::fields::Text::new("different-operation".into()).unwrap()
								}
								1 => metadata.gateway = coordinate(custody::Role::Operations, 2),
								_ => {
									metadata.id =
										rooms_application::fields::Text::new("different-network".into()).unwrap()
								}
							}
							assert!(
								acquisition(&host, &source, &canonical, result_handle, selected_handle, &invalid)
									.await
									.is_err()
							);
						}
						acquisition(&host, &source, &canonical, result_handle, selected_handle, &intent)
							.await
							.unwrap();
						let mut invalid = intent.clone();
						invalid.operations.as_mut_slice()[0].connection.as_mut().unwrap().id =
							rooms_application::fields::Text::new("renamed-origin".into()).unwrap();
						assert!(
							owner.replace_workspace(&invalid).await.is_err(),
							"ordinary workspace edits cannot rewrite connection origin"
						);
						let (lease, _) = command(
							&host,
							&source,
							"lease",
							selected_handle,
							"ircConnection",
							"addLease",
							"{}",
						)
						.await;
						mutate(&host, &source, "command", &lease).await.unwrap();
						assert_eq!(
							finished(&host, &other, "lease", &source).await.as_str(),
							Some("committed")
						);
						assert_eq!(leases.get(), 1);
						lifecycle(&host, &control, "pause").await;
						let (blocked, _) = command(
							&host,
							&root,
							"blocked-lease",
							selected_handle,
							"ircConnection",
							"addLease",
							"{}",
						)
						.await;
						if mutate(&host, &root, "command", &blocked).await.is_ok() {
							assert_ne!(
								finished(&host, &root, "blocked-lease", &root).await.as_str(),
								Some("committed")
							);
						}
						assert_eq!(
							leases.get(),
							1,
							"root cannot substitute for the acquired connection's source"
						);
						lifecycle(&host, &control, "resume").await;
						let permissions = [
							rooms_application::content::permissions::Permission::ObserveWorkspace.key(),
							rooms_application::content::permissions::Permission::UseOperations.key(),
						];
						let narrowed = policy.value_for_kind(session::KIND, &permissions, &[]).unwrap();
						edit_policy(&host, &control, narrowed).await;
						let (blocked, _) = command(
							&host,
							&root,
							"blocked-policy-lease",
							selected_handle,
							"ircConnection",
							"addLease",
							"{}",
						)
						.await;
						if mutate(&host, &root, "command", &blocked).await.is_ok() {
							assert_ne!(
								finished(&host, &root, "blocked-policy-lease", &root).await.as_str(),
								Some("committed")
							);
						}
						assert_eq!(
							leases.get(),
							1,
							"UseOperations alone cannot preserve mutation after InteractWorkspace loss"
						);
						edit_policy(&host, &control, terms).await;
						lifecycle(&host, &control, "revoke").await;
						assert!(
							host.send(
								&source,
								"effect-result",
								&["acquire-live".into(), canonical.clone().into()]
							)
							.await
							.is_err()
						);
					}
					let cold_canonical = if !malformed {
						intent.operations = List::new(vec![Operations {
							connection: None,
							kind: Kind::IrcGateway,
							handle: original_handle,
						}])
						.unwrap();
						owner.replace_workspace(&intent).await.unwrap();
						let (args, intent) = command(
							&host,
							&root,
							"acquire-cold",
							original_handle,
							"ircGateway",
							"connection",
							"network",
						)
						.await;
						mutate(&host, &root, "command", &args).await.unwrap();
						assert_eq!(
							finished(&host, &root, "acquire-cold", &root).await.as_str(),
							Some("committed")
						);
						owner
							.import_result(
								&root,
								"acquire-cold",
								&intent,
								result_handle,
								coordinate(custody::Role::IrcConnection, 10),
							)
							.await
							.unwrap();
						intent
					} else {
						String::new()
					};
					owner.close().await.unwrap();
					let marker = attachment.live_marker().unwrap().unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					drop(store);
					let mut store = database.open(false, &schemas, limits).await;
					let host = Host::from_seed([114; 32]).unwrap();
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
								registration(acquisitions.clone(), leases.clone(), malformed),
							],
						)
						.unwrap();
					attachment.start_live(Some(marker), 32).unwrap();
					let (root, root_control) =
						environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
					owner.bind(root.clone(), root_control.clone()).unwrap();
					if !malformed {
						assert!(
							host.send(
								&root,
								"effect-result",
								&["acquire-cold".into(), cold_canonical.clone().into()]
							)
							.await
							.is_err(),
							"original source cannot recover an expired live result"
						);
						assert!(
							owner
								.import_result(
									&root,
									"acquire-cold",
									&cold_canonical,
									result_handle,
									coordinate(custody::Role::IrcConnection, 11)
								)
								.await
								.is_err()
						);
						let mut intent = Intent::empty();
						intent.operations = List::new(vec![Operations {
							connection: Some(rooms_application::content::session::workspace::ConnectionSelection {
								operation: rooms_application::fields::Text::new("acquire-cold".into()).unwrap(),
								gateway: coordinate(custody::Role::Operations, 1),
								id: rooms_application::fields::Text::new("network".into()).unwrap(),
							}),
							kind: Kind::IrcConnection,
							handle: coordinate(custody::Role::IrcConnection, 10),
						}])
						.unwrap();
						owner.replace_workspace(&intent).await.unwrap();
						let (expired, _) = command(
							&host,
							&root,
							"expired-lease",
							coordinate(custody::Role::IrcConnection, 10),
							"ircConnection",
							"addLease",
							"{}",
						)
						.await;
						assert!(
							mutate(&host, &root, "command", &expired).await.is_err(),
							"cold selection cannot revive live connection custody"
						);
					}
					assert_eq!(acquisitions.get(), if malformed { 1 } else { 2 });
					assert_eq!(leases.get(), if malformed { 0 } else { 1 });
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					drop(store);
					database.remove();
				})
				.await
				.expect("connection acquisition has bounded progress");
			})
			.await;
	}
}
