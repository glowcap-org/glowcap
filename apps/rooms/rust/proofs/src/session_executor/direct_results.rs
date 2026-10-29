//! Directory introductions retain actual alias custody and its original source.
use super::requests::{command, coordinate};
use super::*;
use rooms_application::{
	content::permissions::Permission,
	content::session::{results::Direct, workspace},
	directory::registration::NicknameAllocation,
};
mod contact;
mod participation;
mod sender;
const REGISTRATION: &str = "00000000-0000-4000-8000-000000000001";
const DIRECTORY: Schema = Schema {
	id: 0x53444952303031,
	version: 1,
	max_payload: 64,
	// One application inbox field plus the managed resource binding.
	max_edges: 2,
};
struct Directory {
	inbox: Ref,
	acquisitions: Rc<Cell<usize>>,
	malformed: bool,
}
impl Content for Directory {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(if input.verb == "configure" {
			vec![loam::ReferenceRequest::SaveLive(self.inbox.clone())]
		} else {
			vec![loam::ReferenceRequest::Restore(0)]
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		if input.verb == "configure" {
			call.append_reference(&self.inbox)?;
			return Ok(Argument::Void);
		}
		assert_eq!(
			input.payload, b"original",
			"a changed directory cannot redirect acquisition"
		);
		assert_eq!(input.verb, "introduce");
		assert_eq!(input.args, &["peer".into(), REGISTRATION.into(), "opening".into()]);
		self.acquisitions.set(self.acquisitions.get() + 1);
		Ok(if self.malformed {
			true.into()
		} else {
			call.disclose(0, false)?
		})
	}
}
fn registration(inbox: &Ref, acquisitions: &Rc<Cell<usize>>, malformed: bool) -> Registration {
	Registration {
		schema: DIRECTORY.id,
		version: 1,
		graph: None,
		methods: vec![
			Method {
				verb: "introduce".into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "configure".into(),
				retry: Retry::Idempotent,
			},
		],
		content: Box::new(Directory {
			inbox: inbox.clone(),
			acquisitions: acquisitions.clone(),
			malformed,
		}),
	}
}
async fn lifecycle(host: &Host, control: &Ref, verb: &str) {
	super::publication_results::lifecycle(host, control, verb).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn introductions_keep_exact_live_aliases_private_and_refuse_cold_revival() {
	run().await;
}
pub(super) async fn run() {
	for (malformed, pending) in [(false, false), (true, false), (false, true)] {
		tokio::task::LocalSet::new()
			.run_until(async {
				environment::within(10_000, async {
					let database = Database::new("direct-acquisition");
					let mut schemas = managed::schemas();
					schemas.push(DIRECTORY);
					// Source admission, forwarded archive authority and private
					// settlement overlap. The production profile derives these
					// three managed windows; the codec trace admits only one.
					let limits = managed::production_limits().unwrap();
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
					let original = environment::create(&store, &policy, DIRECTORY, b"original", 2).await;
					let replacement = environment::create(&store, &policy, DIRECTORY, b"replacement", 2).await;
					let host = Host::from_seed([116; 32]).unwrap();
					let exporter = Host::from_seed([117; 32]).unwrap();
					let sent = Rc::new(Cell::new(0));
					let changed_lines = Rc::new(Cell::new(0));
					let line = exporter
						.spawn({
							let changes = changed_lines.clone();
							move |verb, args| {
								let verb = verb.ok_or("fixture requires a method")?;
								assert!(matches!(verb, "edit" | "withdraw" | "refile"));
								changes.set(changes.get() + 1);
								if verb == "edit" {
									assert_eq!(args, &["sender edit after receipt eviction".into()]);
								}
								Ok(Argument::Void)
							}
						})
						.unwrap();
					let reciprocal = Rc::new(std::cell::RefCell::new(None));
					let registration_live = Rc::new(Cell::new(true));
					exporter
						.publish("registration-inbox", {
							let sent = sent.clone();
							let live = registration_live.clone();
							let reciprocal = reciprocal.clone();
							let line = line.clone();
							move || {
								Box::new(move |verb, args| {
									let verb = verb.ok_or("fixture requires a method")?;
									if !live.get() {
										return Err("registration ended".into());
									}
									if verb == rooms_application::direct::READY {
										let [Argument::Reference(inbox)] = args else {
											panic!("exact reciprocal inbox");
										};
										*reciprocal.borrow_mut() = Some(inbox.clone());
										return Ok(Argument::Void);
									}
									assert_eq!(verb, "dm");
									assert_eq!(args, &["exact message".into()]);
									sent.set(sent.get() + 1);
									Ok(line.clone().into())
								})
							}
						})
						.unwrap();
					let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9147");
					let (left, right) = tokio::io::duplex(4096);
					let (importer, remote) = tokio::join!(
						glowcap::Session::dial_over(&host, &locator, left, Some(std::time::Duration::from_secs(2))),
						glowcap::Session::accept_over(
							&exporter,
							"tcp",
							"127.0.0.1:9147",
							"127.0.0.1:9146",
							right,
							Some(std::time::Duration::from_secs(2))
						),
					);
					let (importer, remote) = (importer.unwrap(), remote.unwrap());
					let inbox = importer.fetch("registration-inbox").await.unwrap();
					let platform = Platform::default();
					let owner = managed::Session::new(
						host.clone(),
						platform.clone(),
						std::num::NonZeroUsize::new(8192).unwrap(),
					);
					let acquisitions = Rc::new(Cell::new(0));
					let failures = Rc::new(Cell::new(0));
					owner
						.on_trouble({
							let failures = failures.clone();
							move |operation, _| {
								assert!(!operation.is_empty());
								failures.set(failures.get() + 1);
							}
						})
						.unwrap();
					let mut attachment = store
						.attach(
							&host,
							vec![owner.registration(), registration(&inbox, &acquisitions, malformed)],
						)
						.unwrap();
					environment::start_live(&attachment, None, 64).await;
					let (root, root_control) = environment::restore(&attachment, resource).await;
					owner.bind(root.clone(), root_control.clone()).unwrap();
					owner.initialize().await.unwrap();
					owner
						.activity()
						.bind_incarnation(attachment.live_incarnation().unwrap().unwrap())
						.unwrap();
					let (directory, _) = environment::restore(&attachment, original).await;
					let (next_directory, _) = environment::restore(&attachment, replacement).await;
					host.send(&directory, "configure", &[]).await.unwrap_or_else(|error| {
						panic!("directory inbox configuration: {error:?}; {:?}", host.take_failures())
					});
					host.send(&next_directory, "configure", &[]).await.unwrap();
					let directory = if pending {
						let acquisitions = acquisitions.clone();
						exporter
							.publish("pending-directory", move || {
								Box::new(move |verb, args| {
									let verb = verb.ok_or("fixture requires a method")?;
									assert_eq!(verb, "introduce");
									assert_eq!(args, &["peer".into(), REGISTRATION.into(), "opening".into()]);
									acquisitions.set(acquisitions.get() + 1);
									Err("introduction-pending: requested exact registration inbox".into())
								})
							})
							.unwrap();
						importer.fetch("pending-directory").await.unwrap()
					} else {
						directory
					};
					owner
						.import(
							coordinate(custody::Role::DirectoryAccess, 1),
							directory,
							if pending {
								Some(
									glowcap::format_sturdyref(
										&locator,
										b"pending-directory",
										glowcap::CaptpVersion::V1_0,
									)
									.unwrap(),
								)
							} else {
								None
							},
						)
						.await
						.unwrap();
					owner
						.import(coordinate(custody::Role::DirectoryAccess, 2), next_directory, None)
						.await
						.unwrap();
					let mut intent = Intent::empty();
					for role in [custody::Role::DirectoryName, custody::Role::DirectoryInbox] {
						owner.import(coordinate(role, 1), root.clone(), None).await.unwrap();
					}
					intent.directories = List::new(vec![workspace::Directory {
						id: rooms_application::fields::Text::new("directory".into()).unwrap(),
						access: key(),
						name: Some(key()),
						source: None,
						inbox: Some(key()),
						home: true,
						nick: rooms_application::fields::Text::new("self".into()).unwrap(),
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
					let (args, canonical) = command(
						&host,
						&source,
						"introduced",
						"startDirect",
						&["directory".into(), "peer".into(), REGISTRATION.into(), "opening".into()],
					)
					.await;
					platform.suspended.set(true);
					mutate(&host, &source, "command", &args).await.unwrap();
					intent.directories.as_mut_slice()[0].access =
						custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap());
					owner.replace_workspace(&intent).await.unwrap();
					platform.suspended.set(false);
					let status = if malformed { "unknown" } else { "committed" };
					let observed = finished(&host, &other, "introduced", &source).await;
					assert_eq!(observed.as_str(), Some(status));
					assert_eq!(acquisitions.get(), 1);
					assert_eq!(
						mutate(&host, &source, "command", &args).await.unwrap().as_str(),
						Some(status)
					);
					assert_eq!(acquisitions.get(), 1, "receipt replay cannot introduce again");
					assert_eq!(
						failures.get(),
						usize::from(malformed),
						"terminal malformed replies have one failure owner"
					);
					let result = coordinate(custody::Role::DirectAccess, 1);
					let destination = coordinate(custody::Role::DirectAccess, 9);
					if pending {
						let disclosed = host
							.send(
								&source,
								"effect-result",
								&["introduced".into(), canonical.clone().into()],
							)
							.await
							.unwrap();
						assert!(matches!(
							serde_json::from_str::<Direct>(
								disclosed
									.as_str()
									.expect("pending requests disclose data without authority")
							)
							.unwrap(),
							Direct::Pending
						));
						assert!(
							owner
								.import_result(&source, "introduced", &canonical, result, destination)
								.await
								.is_err(),
							"pending requests invent no inbox authority"
						);
					}
					if !malformed && !pending {
						contact::refuse_replacement(&host, &source, &platform).await;
						assert!(
							host.send(
								&other,
								"effect-result",
								&["introduced".into(), canonical.clone().into()]
							)
							.await
							.is_err()
						);
						let disclosed = host
							.send(
								&source,
								"effect-result",
								&["introduced".into(), canonical.clone().into()],
							)
							.await
							.unwrap();
						let [data, fields] = disclosed.as_list().unwrap() else {
							panic!("private direct result");
						};
						let row: Direct = serde_json::from_str(data.as_str().unwrap()).unwrap();
						let Direct::Ready { inbox } = row else {
							panic!("ready direct inbox")
						};
						assert_eq!(inbox.slot(), result.key.slot());
						assert!(
							fields.as_list().unwrap().is_empty(),
							"raw inbox authority must remain private"
						);
						assert!(
							owner
								.import_result(&other, "introduced", &canonical, result, destination)
								.await
								.is_err()
						);
						assert!(
							owner
								.import_result(&root, "introduced", &canonical, result, destination)
								.await
								.is_err()
						);
						assert!(
							owner
								.import_result(
									&source,
									"introduced",
									&canonical,
									result,
									coordinate(custody::Role::RoomAccess, 9)
								)
								.await
								.is_err()
						);
						owner
							.import_result(&source, "introduced", &canonical, result, destination)
							.await
							.unwrap();
						owner
							.import_result(&source, "introduced", &canonical, result, destination)
							.await
							.unwrap();
						let direct = workspace::Direct {
							introduction: None,
							inbox: None,
							source: None,
							kind: workspace::DirectKind::Direct,
							id: rooms_application::fields::Text::new("direct".into()).unwrap(),
							directory: rooms_application::fields::Text::new("directory".into()).unwrap(),
							peer: rooms_application::fields::Text::new("peer".into()).unwrap(),
							access: Some(custody::FieldKey::new(
								destination.key.slot(),
								destination.key.generation(),
							)),
							closed: false,
							lines: List::default(),
							draft: rooms_application::fields::Text::new("".into()).unwrap(),
						};
						let (open, _) = command(
							&host,
							&source,
							"opened",
							"openDirect",
							&[serde_json::to_string(&direct).unwrap()],
						)
						.await;
						assert_eq!(
							mutate(&host, &source, "command", &open).await.unwrap().as_str(),
							Some("committed")
						);
						let (post, _) = command(
							&host,
							&source,
							"posted",
							"say",
							&["direct".into(), "exact message".into()],
						)
						.await;
						mutate(&host, &source, "command", &post).await.unwrap();
						assert_eq!(
							finished(&host, &other, "posted", &source).await.as_str(),
							Some("committed")
						);
						assert_eq!(sent.get(), 1);
						sender::after_post(&host, &source, &other, &changed_lines, &platform).await;
						// This integration scenario nests the independent callback and
						// activity scenarios. Keep their debug future off the test stack.
						Box::pin(super::direct_callbacks::run(
							&host,
							&exporter,
							&owner,
							&source,
							&control,
							&reciprocal,
						))
						.await;
						registration_live.set(false);
						let (retired, _) = command(
							&host,
							&root,
							"retired",
							"say",
							&["direct".into(), "exact message".into()],
						)
						.await;
						mutate(&host, &root, "command", &retired).await.unwrap();
						assert_ne!(
							finished(&host, &root, "retired", &root).await.as_str(),
							Some("committed")
						);
						assert_eq!(sent.get(), 1, "upstream registration retirement blocks the saved inbox");
						registration_live.set(true);
						lifecycle(&host, &control, "pause").await;
						let (blocked, _) = command(
							&host,
							&root,
							"blocked",
							"say",
							&["direct".into(), "exact message".into()],
						)
						.await;
						if mutate(&host, &root, "command", &blocked).await.is_ok() {
							assert_ne!(
								finished(&host, &root, "blocked", &root).await.as_str(),
								Some("committed")
							);
						}
						assert_eq!(sent.get(), 1, "private root cannot bypass the original source");
						lifecycle(&host, &control, "resume").await;
						let narrowed = policy
							.value_for_kind(
								session::KIND,
								&[
									Permission::ObserveWorkspace.key(),
									Permission::ManageCustody.key(),
									Permission::ResolvePending.key(),
								],
								&[],
							)
							.unwrap();
						let sequence = host
							.send(&control, "mutation-sequence", &[])
							.await
							.unwrap()
							.as_i64()
							.unwrap() as u32;
						host.send(
							&control,
							"mutate",
							&narrowed
								.set_policy_arguments(sequence, loam::control_revision(&host, &control).await.unwrap()),
						)
						.await
						.unwrap();
						let (blocked, _) = command(
							&host,
							&root,
							"narrowed",
							"say",
							&["direct".into(), "exact message".into()],
						)
						.await;
						if mutate(&host, &root, "command", &blocked).await.is_ok() {
							assert_ne!(
								finished(&host, &root, "narrowed", &root).await.as_str(),
								Some("committed")
							);
						}
						assert_eq!(sent.get(), 1, "InteractWorkspace loss must block inbox calls");
						lifecycle(&host, &control, "revoke").await;
						assert!(
							host.send(
								&source,
								"effect-result",
								&["introduced".into(), canonical.clone().into()]
							)
							.await
							.is_err()
						);
						intent.directories.as_mut_slice()[0].access = key();
						owner.replace_workspace(&intent).await.unwrap();
						let (fresh, cold_canonical) = command(
							&host,
							&root,
							"cold-introduced",
							"startDirect",
							&["directory".into(), "peer".into(), REGISTRATION.into(), "opening".into()],
						)
						.await;
						mutate(&host, &root, "command", &fresh).await.unwrap();
						assert_eq!(
							finished(&host, &root, "cold-introduced", &root).await.as_str(),
							Some("committed")
						);
						owner
							.import_result(
								&root,
								"cold-introduced",
								&cold_canonical,
								result,
								coordinate(custody::Role::DirectAccess, 10),
							)
							.await
							.unwrap();
						let mut direct = direct;
						direct.access = Some(custody::FieldKey::new(
							NonZeroU64::new(10).unwrap(),
							NonZeroU64::new(1).unwrap(),
						));
						intent.conversations =
							List::new(vec![workspace::Conversation::Direct(Box::new(direct))]).unwrap();
						intent.active = Some(rooms_application::fields::Text::new("direct".into()).unwrap());
						owner.replace_workspace(&intent).await.unwrap();
						contact::adopt_exact(&host, &root, &platform).await;
						participation::run(&host, &owner, &platform).await;
					}
					owner.close().await.unwrap();
					let marker = attachment.live_marker().unwrap().unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop((owner, root, source, other, control, inbox, importer, remote));
					environment::close(&mut store).await;
					drop(store);
					let mut store = database.open(false, &schemas, limits).await;
					let host = Host::from_seed([116; 32]).unwrap();
					let owner = managed::Session::new(
						host.clone(),
						Platform::default(),
						std::num::NonZeroUsize::new(8192).unwrap(),
					);
					let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
					environment::start_live(&attachment, Some(marker), 64).await;
					let (root, root_control) =
						environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
					owner.bind(root.clone(), root_control.clone()).unwrap();
					assert_eq!(acquisitions.get(), if malformed || pending { 1 } else { 4 });
					if !malformed && !pending {
						// This inbox was imported through the unrevoked private root.
						// Expiry alone refuses its saved registration alias.
						let snapshot = host.send(&root, "snapshot", &[]).await.unwrap();
						let intent: Intent =
							serde_json::from_str(snapshot.as_list().unwrap()[1].as_str().unwrap()).unwrap();
						assert!(
							matches!(&intent.conversations.as_slice()[0], workspace::Conversation::Direct(row) if row.access.is_some())
						);
						let (post, _) = command(
							&host,
							&root,
							"cold-post",
							"say",
							&["direct".into(), "exact message".into()],
						)
						.await;
						assert!(
							mutate(&host, &root, "command", &post).await.is_err(),
							"cold startup cannot restore registration-scoped aliases"
						);
					}
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					exporter.close(PendingWork::Cancel).await.unwrap();
					database.remove();
				})
				.await
				.expect("direct acquisition has bounded progress");
			})
			.await;
	}
}
