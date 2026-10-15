//! Physical IndexedDB credentials recover from the physically saved Loam witness.
use super::*;
use rooms_application::{fields::Hex, text::DocumentText};
use rooms_browser::storage::{Credentials, Database as ArchiveDatabase};
use rooms_runtime::{
	documents::{Completion, Document as _},
	session::bridge_secrets::BridgeSecrets,
};
use std::{
	future::Future,
	task::{Context, Waker},
};

pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(15_000, async {
				let database = Database::new("bridge-physical-credentials");
				let mut schemas = managed::schemas();
				schemas.push(BRIDGE);
				let limits = managed::production_limits().unwrap();
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let mut resources = None;
				let mut identity = None;
				for phase in 0..3 {
					let mut store = database.open(phase == 0, &schemas, limits).await;
					let [root_resource, access_resource, seat_resource] = match resources {
						Some(resources) => resources,
						None => {
							let created = [
								environment::create(
									&store,
									&policy,
									schemas[0],
									&managed::initial_payload(
										rooms_application::content::session::workspace::Connection::Relay,
									)
									.unwrap(),
									3,
								)
								.await,
								environment::create(&store, &policy, BRIDGE, b"access", 3).await,
								environment::create(&store, &policy, BRIDGE, b"seat", 3).await,
							];
							resources = Some(created);
							created
						}
					};
					let host = Host::from_seed([161; 32]).unwrap();
					let platform = Platform::default();
					let owner = managed::Session::new(
						host.clone(),
						platform.clone(),
						std::num::NonZeroUsize::new(limits.forward_reply_bytes).unwrap(),
					);
					let calls = Rc::new(Cell::new(0));
					let registration = Registration {
						schema: BRIDGE.id,
						version: 1,
						graph: None,
						methods: [rooms_application::bridge::ASK, rooms_application::bridge::SUBMIT]
							.into_iter()
							.map(|verb| Method {
								verb: verb.into(),
								retry: Retry::Idempotent,
							})
							.collect(),
						content: Box::new(Bridge {
							form: Rc::new(RefCell::new(form())),
							calls: calls.clone(),
							unknown: Rc::new(Cell::new(false)),
						}),
					};
					let mut attachment = store.attach(&host, vec![owner.registration(), registration]).unwrap();
					attachment.start_live(None, 128).unwrap();
					let (root, control) = attachment.restore(root_resource).await.unwrap();
					owner.bind(root.clone(), control).unwrap();
					owner.initialize().await.unwrap();
					let snapshot = host.send(&root, "bridge-witnesses", &[]).await.unwrap();
					let snapshot: serde_json::Value = serde_json::from_str(snapshot.as_str().unwrap()).unwrap();
					let domain: Hex<16> = serde_json::from_value(snapshot["owner"].clone()).unwrap();
					assert!(
						identity.is_none_or(|prior| prior == *domain.bytes()),
						"physical reopen changed the owner namespace"
					);
					identity = Some(*domain.bytes());
					let archive_database = ArchiveDatabase::open().await.unwrap();
					if phase == 1 {
						// Lose observation after IndexedDB admits its read. The document
						// owns that operation until the actual completion is collected.
						let mut document = Credentials::new(archive_database.clone(), domain.bytes());
						let mut reading = Box::pin(document.read());
						assert!(
							reading
								.as_mut()
								.poll(&mut Context::from_waker(Waker::noop()))
								.is_pending()
						);
						drop(reading);
						assert!(document.has_pending());
						let Some(Completion::Read(result)) = document.finish_pending().await else {
							panic!("retained credential read")
						};
						let bytes = result.unwrap().unwrap();
						assert!(String::from_utf8(bytes).unwrap().contains("private credential"));
						let journal = BridgeSecrets::open(document).await.unwrap();
						let owner_name: DocumentText = snapshot["owner"].as_str().unwrap().into();
						journal
							.stage(
								owner_name.clone(),
								"ffffffffffffffff".into(),
								Answers::decode("{\"password\":\"orphan credential\"}").unwrap(),
								Some("fedcba9876543210fedcba9876543210".into()),
							)
							.await
							.unwrap();
						drop(journal);
					}
					owner
						.configure_credentials(Credentials::new(archive_database.clone(), domain.bytes()))
						.await
						.unwrap();
					let terms = policy
						.value_for_kind(
							session::KIND,
							&session::SUPPORTED.iter().map(|p| p.key()).collect::<Vec<_>>(),
							&[],
						)
						.unwrap();
					let pair = host
						.send(
							&root,
							"derive-managed",
							&terms.managed_derive_arguments(1, Scope::Object, 1, ControlPowers::default()),
						)
						.await
						.unwrap();
					let source = Ref::try_from(&pair.as_list().unwrap()[0]).unwrap();
					let workspace = Workspace::local(host.clone(), platform, source);
					if phase != 2 {
						let (access, _) = attachment.restore(access_resource).await.unwrap();
						let (seat, _) = attachment.restore(seat_resource).await.unwrap();
						if phase == 0 {
							for role in [custody::Role::DirectoryAccess, custody::Role::RoomAccess] {
								owner.import(coordinate(role, 1), access.clone(), None).await.unwrap();
							}
						}
						let slot = phase + 1;
						owner
							.import(coordinate(custody::Role::RoomSeat, slot), seat, None)
							.await
							.unwrap();
						let mut intent = if phase == 0 {
							Case::kick().workspace(1)
						} else {
							workspace.snapshot().await.unwrap().intent
						};
						let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
							panic!("room")
						};
						room.id = Text::new("room".into()).unwrap();
						room.moderator = None;
						room.access = Some(custody::FieldKey::new(
							NonZeroU64::new(1).unwrap(),
							NonZeroU64::new(1).unwrap(),
						));
						room.seat = Some(seat_key(slot));
						owner.replace_workspace(&intent).await.unwrap();
					}
					if phase == 0 {
						let request = bridge::Request {
							bridge: bridge::Intent {
								declaration: form(),
								action: rooms_application::bridge::Id::new("apply".into()).unwrap(),
								answers: Answers::decode("{\"name\":\"sender\"}").unwrap(),
							},
							operation: Text::new("physical-original".into()).unwrap(),
							base: SafeInteger::new(workspace.snapshot().await.unwrap().revision).unwrap(),
							room: Text::new("room".into()).unwrap(),
							seat: seat_key(1),
							access: Some(coordinate(custody::Role::RoomAccess, 1)),
							credentials: Some(serde_json::from_str("\"0123456789abcdef0123456789abcdef\"").unwrap()),
							reapply: None,
						};
						let command = workspace
							.prepare_bridge(
								&request,
								&Answers::decode("{\"password\":\"private credential\"}").unwrap(),
							)
							.unwrap();
						command.submit().await.unwrap();
						assert_eq!(terminal(&command).await, EffectStatus::Committed);
						assert_eq!(calls.get(), 1);
					} else if phase == 1 {
						assert_eq!(calls.get(), 0, "cold recovery cannot dispatch the original effect");
						let command = workspace
							.prepare_bridge_reapplication(
								"physical-reapply",
								workspace.snapshot().await.unwrap().revision,
								"room",
							)
							.await
							.unwrap();
						command.submit().await.unwrap();
						assert_eq!(terminal(&command).await, EffectStatus::Committed);
						assert_eq!(calls.get(), 1);
						let forgetting = workspace
							.prepare_forget_bridge(workspace.snapshot().await.unwrap().revision, "room")
							.await
							.unwrap();
						forgetting.submit().await.unwrap();
					} else {
						assert!(
							workspace
								.prepare_bridge_reapplication(
									"forgotten",
									workspace.snapshot().await.unwrap().revision,
									"room"
								)
								.await
								.is_err()
						);
						let mut document = Credentials::new(archive_database, domain.bytes());
						let bytes = document.read().await.unwrap().unwrap();
						let bytes = String::from_utf8(bytes).unwrap();
						assert!(!bytes.contains("private credential") && !bytes.contains("orphan credential"));
						assert_eq!(calls.get(), 0);
					}
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop((workspace, owner, attachment));
					store.close().await.unwrap();
				}
				database.remove();
			})
			.await
			.expect("IndexedDB credential recovery deadline");
		})
		.await;
}
