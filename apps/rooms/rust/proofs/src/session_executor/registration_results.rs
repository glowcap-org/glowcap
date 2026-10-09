//! Registration identity and exact private name custody share one receipt.
use super::requests::{command, coordinate};
use super::*;
use rooms_application::{
	content::session::{results::Registration as Acquired, workspace},
	directory::registration::NicknameAllocation,
	fields::Text,
};

const ID: &str = "00000000-0000-4000-8000-000000000001";
const DIRECTORY: Schema = Schema {
	id: 0x5344495245473031,
	version: 1,
	max_payload: 64,
	max_edges: 3,
};
struct Directory {
	name: Ref,
	invocations: Rc<Cell<usize>>,
	wrong_nick: bool,
}
impl Content for Directory {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(if input.verb == "configure" {
			vec![loam::ReferenceRequest::SaveLive(self.name.clone())]
		} else if input.verb == "callback" {
			vec![loam::ReferenceRequest::Restore(1)]
		} else if matches!(
			input.verb,
			"listPublications" | "advertisedLocation" | "memberRegistration"
		) {
			Vec::new()
		} else {
			vec![
				loam::ReferenceRequest::Restore(0),
				loam::ReferenceRequest::SaveLive(Ref::try_from(&input.args[2]).unwrap()),
			]
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		if input.verb == "configure" {
			call.append_reference(&self.name)?;
			return Ok(Argument::Void);
		}
		if input.verb == "callback" {
			return call.disclose(1, false);
		}
		match input.verb {
			"listPublications" => {
				return Ok(Argument::List(if input.payload == b"replacement" {
					Vec::new()
				} else {
					vec![Argument::List(vec!["room".into(), 1.into()])]
				}));
			}
			"advertisedLocation" => return Ok("ocapn://member.id".into()),
			"memberRegistration" => {
				assert_eq!(input.args, &["peer".into()]);
				return Ok(ID.into());
			}
			_ => {}
		}
		assert_eq!(
			input.payload, b"original",
			"a replacement directory cannot redirect registration"
		);
		assert_eq!(input.verb, "register");
		let [nick, locator, Argument::Reference(inbox), allocation] = input.args else {
			panic!("registration shape")
		};
		assert!(matches!(nick.as_str(), Some("self" | "replacement")));
		assert_eq!(locator.as_str(), Some("ocapn://member.id"));
		assert!(matches!(allocation.as_str(), Some("exact" | "automatic")));
		if self.invocations.get() == 0 {
			call.append_reference(inbox)?;
		} else {
			call.replace_reference(1, inbox)?;
		}
		self.invocations.set(self.invocations.get() + 1);
		Ok(Argument::List(vec![
			if self.wrong_nick {
				"other"
			} else if allocation.as_str() == Some("automatic") {
				"self2"
			} else {
				nick.as_str().unwrap()
			}
			.into(),
			ID.into(),
			call.disclose(0, false)?,
		]))
	}
}
fn registration(name: &Ref, count: &Rc<Cell<usize>>, wrong_nick: bool) -> Registration {
	Registration {
		schema: DIRECTORY.id,
		version: 1,
		graph: None,
		methods: vec![
			Method {
				verb: "configure".into(),
				retry: Retry::Idempotent,
			},
			Method {
				verb: "register".into(),
				retry: Retry::Idempotent,
			},
			Method {
				verb: "callback".into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "listPublications".into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "advertisedLocation".into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "memberRegistration".into(),
				retry: Retry::ReadOnly,
			},
		],
		content: Box::new(Directory {
			name: name.clone(),
			invocations: count.clone(),
			wrong_nick,
		}),
	}
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn registration_retains_private_exact_name_checks_source_and_refuses_cold_vouchers() {
	run().await;
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn directory_realization_keeps_the_original_source_and_callback() {
	realization().await;
}

pub(super) async fn realization() {
	run_scenarios(&[Scenario::Realization]).await;
}
pub(super) async fn run() {
	run_scenarios(&[Scenario::Registration(false), Scenario::Registration(true)]).await;
}
enum Scenario {
	Realization,
	Registration(bool),
}
async fn run_scenarios(scenarios: &[Scenario]) {
	for scenario in scenarios {
		let wrong_nick = matches!(scenario, Scenario::Registration(true));
		tokio::task::LocalSet::new()
			.run_until(async {
				environment::within(10_000, async {
					let database = Database::new("registration-acquisition");
					let mut schemas = managed::schemas();
					schemas.push(DIRECTORY);
					let mut limits = managed::reader_limits(crate::session_storage::limits_for(
						24,
						8,
						loam::ValueBounds {
							values: 48,
							capabilities: 12,
							bytes: 8192,
							..Default::default()
						},
					))
					.unwrap();
					limits.pending_bytes = limits.call_bytes * limits.max_operations;
					limits.ingress_bytes = limits.pending_bytes;
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
					let directory = environment::create(&store, &policy, DIRECTORY, b"original", 3).await;
					let replacement = environment::create(&store, &policy, DIRECTORY, b"replacement", 3).await;
					let host = Host::from_seed([118; 32]).unwrap();
					let exporter = Host::from_seed([119; 32]).unwrap();
					exporter
						.publish("name", || {
							Box::new(|verb, args| {
								if verb == "leave" {
									assert!(args.is_empty());
									return Ok(Argument::Void);
								}
								assert_eq!(verb, "voucher");
								assert!(args.is_empty());
								Ok(Argument::Bytes(vec![7; 32]))
							})
						})
						.unwrap();
					let notifications = Rc::new(Cell::new(0));
					exporter
						.publish("inbox", {
							let count = notifications.clone();
							move || {
								Box::new(move |verb, _| {
									assert_eq!(verb, "notify");
									count.set(count.get() + 1);
									Ok(Argument::Void)
								})
							}
						})
						.unwrap();
					let (left, right) = tokio::io::duplex(4096);
					let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9149");
					let (importer, remote) = tokio::join!(
						glowcap::Session::dial_over(&host, &locator, left, Some(std::time::Duration::from_secs(2))),
						glowcap::Session::accept_over(
							&exporter,
							"tcp",
							"127.0.0.1:9149",
							"127.0.0.1:9148",
							right,
							Some(std::time::Duration::from_secs(2))
						)
					);
					let (importer, remote) = (importer.unwrap(), remote.unwrap());
					let name = importer.fetch("name").await.unwrap();
					let inbox = importer.fetch("inbox").await.unwrap();
					let platform = Platform::default();
					let owner = managed::Session::new(
						host.clone(),
						platform.clone(),
						std::num::NonZeroUsize::new(8192).unwrap(),
					);
					let count = Rc::new(Cell::new(0));
					let mut attachment = store
						.attach(
							&host,
							vec![owner.registration(), registration(&name, &count, wrong_nick)],
						)
						.unwrap();
					attachment.start_live(None, 64).unwrap();
					let (root, root_control) = environment::restore(&attachment, resource).await;
					owner.bind(root.clone(), root_control.clone()).unwrap();
					owner.initialize().await.unwrap();
					let (directory, _) = environment::restore(&attachment, directory).await;
					let (replacement, _) = environment::restore(&attachment, replacement).await;
					host.send(&directory, "configure", &[]).await.unwrap();
					owner
						.import(coordinate(custody::Role::DirectoryAccess, 1), directory.clone(), None)
						.await
						.unwrap();
					owner
						.import(coordinate(custody::Role::DirectoryInbox, 1), inbox.clone(), None)
						.await
						.unwrap();
					let mut intent = Intent::empty();
					intent.directories = List::new(vec![workspace::Directory {
						id: Text::new("directory".into()).unwrap(),
						access: key(),
						name: None,
						source: None,
						inbox: Some(key()),
						home: true,
						nick: Text::new("self".into()).unwrap(),
						assigned_nick: None,
						nick_allocation: NicknameAllocation::Exact,
						standing: None,
					}])
					.unwrap();
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
								pause: true,
								resume: true,
								revoke: true,
								..Default::default()
							},
						)
						.await
						.unwrap();
					let (other, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
					if matches!(scenario, Scenario::Realization) {
						super::realization::directory(
							&host,
							&importer,
							&owner,
							(&root, &source, &control, &replacement),
							&mut intent,
							&count,
							&platform,
						)
						.await;
						owner.close().await.unwrap();
						attachment.close().await.unwrap();
						host.close(PendingWork::Cancel).await.unwrap();
						drop((
							owner, root, source, other, control, directory, inbox, name, importer, remote,
						));
						environment::close(&mut store).await;
						exporter.close(PendingWork::Cancel).await.unwrap();
						database.remove();
						return;
					}
					let prior = count.get();
					let rest = vec![
						"directory".into(),
						"self".into(),
						"ocapn://member.id".into(),
						"exact".into(),
						serde_json::to_string(&key::<custody::DirectoryInbox>()).unwrap(),
					];
					let (args, canonical) = command(&host, &source, "registered", "joinDirectory", &rest).await;
					platform.suspended.set(true);
					assert_eq!(
						mutate(&host, &source, "command", &args).await.unwrap().as_str(),
						Some("pending")
					);
					intent.directories.as_mut_slice()[0].nick = Text::new("replacement".into()).unwrap();
					owner.replace_workspace(&intent).await.unwrap();
					platform.suspended.set(false);
					assert_eq!(
						finished(&host, &root, "registered", &source).await.as_str(),
						Some(if wrong_nick { "unknown" } else { "committed" })
					);
					assert_eq!(count.get(), prior + 1);
					assert!(mutate(&host, &other, "command", &args).await.is_err());
					let outcome = host
						.send(
							&source,
							"effect-result",
							&["registered".into(), canonical.clone().into()],
						)
						.await
						.unwrap();
					let result = coordinate(custody::Role::DirectoryName, 1);
					let destination = coordinate(custody::Role::DirectoryName, 9);
					if wrong_nick {
						unknown_reason(&outcome);
					} else {
						let Some([data, fields]) = outcome.as_list() else {
							panic!("private registration result")
						};
						assert_eq!(fields.as_list().unwrap(), &[]);
						let row: Acquired = serde_json::from_str(data.as_str().unwrap()).unwrap();
						assert_eq!(row.nick.text().as_str(), Some("self"));
						assert_eq!(row.id.text().as_str(), Some(ID));
						assert!(
							owner
								.import_result(&root, "registered", &canonical, result, destination)
								.await
								.is_err()
						);
						owner
							.import_result(&source, "registered", &canonical, result, destination)
							.await
							.unwrap();
						owner
							.import_result(&source, "registered", &canonical, result, destination)
							.await
							.unwrap();
						let replay = mutate(&host, &source, "command", &args).await.unwrap();
						assert_eq!(replay.as_str(), Some("committed"));
						assert_eq!(
							count.get(),
							prior + 1,
							"exact replay cannot allocate another registration"
						);
					}
					let callback = Ref::try_from(&host.send(&directory, "callback", &[]).await.unwrap()).unwrap();
					host.send(
						&callback,
						"notify",
						&["introducible".into(), "peer".into(), ID.into(), "opening".into()],
					)
					.await
					.unwrap();
					assert_eq!(notifications.get(), 1);
					super::publication_results::lifecycle(&host, &control, "pause").await;
					assert!(host.send(&callback, "notify", &[]).await.is_err());
					if !wrong_nick {
						assert!(
							owner
								.import_result(&source, "registered", &canonical, result, destination)
								.await
								.is_err()
						);
					}
					super::publication_results::lifecycle(&host, &control, "resume").await;
					host.send(&callback, "notify", &[]).await.unwrap();
					assert_eq!(notifications.get(), 2);
					// A root-source receipt gives cold restoration the same witness,
					// so refusal below isolates expired live custody.
					let (cold_args, cold_intent) = command(&host, &root, "cold", "joinDirectory", &rest).await;
					let cold_destination = coordinate(custody::Role::DirectoryName, 10);
					mutate(&host, &root, "command", &cold_args).await.unwrap();
					assert_eq!(
						finished(&host, &root, "cold", &root).await.as_str(),
						Some(if wrong_nick { "unknown" } else { "committed" })
					);
					if !wrong_nick {
						owner
							.import_result(&root, "cold", &cold_intent, result, cold_destination)
							.await
							.unwrap();
					}
					assert_eq!(count.get(), prior + 2);
					owner.close().await.unwrap();
					let marker = attachment.live_marker().unwrap().unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop((
						owner, root, source, other, control, directory, inbox, name, callback, importer, remote,
					));
					environment::close(&mut store).await;
					drop(store);
					let mut store = database.open(false, &schemas, limits).await;
					let host = Host::from_seed([118; 32]).unwrap();
					let owner = managed::Session::new(
						host.clone(),
						Platform::default(),
						std::num::NonZeroUsize::new(8192).unwrap(),
					);
					let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
					attachment.start_live(Some(marker), 64).unwrap();
					let (root, root_control) =
						environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
					owner.bind(root.clone(), root_control.clone()).unwrap();
					assert!(
						owner
							.import_result(&root, "cold", &cold_intent, result, cold_destination)
							.await
							.is_err(),
						"cold startup cannot recover live name authority or vouchers"
					);
					assert_eq!(count.get(), prior + 2);
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					exporter.close(PendingWork::Cancel).await.unwrap();
					database.remove();
				})
				.await
				.expect(match scenario {
					Scenario::Realization => "directory realization has bounded progress",
					Scenario::Registration(_) => "registration acquisition has bounded progress",
				});
			})
			.await;
	}
}
