//! Typing uses the original source and exact room/direct selection on every send.
use super::*;
use rooms_glowcap::client::workspace::Workspace;

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn typing_preserves_source_target_and_selection_for_rooms_and_directs() {
	run().await;
}
pub(super) async fn run() {
	for role in [custody::Role::RoomSeat, custody::Role::DirectAccess] {
		tokio::task::LocalSet::new().run_until(async {
			environment::within(10_000, async {
				let database = Database::new("typing-source");
				let schemas = managed::schemas();
				let mut limits = managed::reader_limits(crate::session_storage::limits_for(24, 8, loam::ValueBounds {
					values: 32, capabilities: 4, bytes: 8192, ..Default::default()
				})).unwrap();
				limits.max_leases *= limits.max_operations;
				limits.pending_bytes = limits.call_bytes * 2;
				limits.ingress_bytes = limits.pending_bytes;
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(&store, &policy, schemas[0], &managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay).unwrap(), 3).await;
				let host = Host::from_seed([121; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(host.clone(), platform.clone(), std::num::NonZeroUsize::new(8192).unwrap());
				let calls = Rc::new(Cell::new(0));
				let target = host.spawn({
					let calls = calls.clone();
					move |verb, args| {
						assert_eq!(verb, "typing");
						assert!(matches!(args, [Argument::Boolean(_)]));
						calls.set(calls.get() + 1);
						Ok(Argument::Void)
					}
				}).unwrap();
				let replacement_calls = Rc::new(Cell::new(0));
				let replacement = host.spawn({
					let calls = replacement_calls.clone();
					move |_, _| { calls.set(calls.get() + 1); Ok(Argument::Void) }
				}).unwrap();
				let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
				attachment.start_live(None, 32).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let terms = policy.value_for_kind(session::KIND, &session::SUPPORTED.iter().map(|p| p.key()).collect::<Vec<_>>(), &[]).unwrap();
				let powers = ControlPowers { pause: true, resume: true, revoke: true, ..Default::default() };
				let (source, control) = owner.derive(terms, 1, powers).await.unwrap();
				let (sibling, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
				let selected = requests::coordinate(role, 1);
				let next = requests::coordinate(role, 2);
				owner.import(selected, target.clone(), None).await.unwrap();
				owner.import(next, replacement.clone(), None).await.unwrap();
				owner.import(requests::coordinate(custody::Role::SessionAccess, 1), source.clone(), None).await.unwrap();
				owner.import(requests::coordinate(custody::Role::SessionAccess, 2), source.clone(), None).await.unwrap();
				owner.import(requests::coordinate(custody::Role::DirectoryAccess, 1), source.clone(), None).await.unwrap();
				if role == custody::Role::RoomSeat {
					owner.import(requests::coordinate(custody::Role::RoomAccess, 1), source.clone(), None).await.unwrap();
				}
				let row = if role == custody::Role::RoomSeat {
					serde_json::json!({"kind":"room", "id":"conversation", "directory":"directory", "name":"room", "access":key::<custody::RoomAccess>(), "seat":selected.key, "source":key::<custody::SessionAccess>(), "reconnect":"requested", "standing":null, "draft":""})
				} else {
					serde_json::json!({"kind":"direct", "id":"conversation", "directory":"directory", "peer":"peer", "access":selected.key, "source":key::<custody::SessionAccess>(), "closed":false, "draft":""})
				};
				let mut original = Intent::empty();
				original.directories = serde_json::from_value(serde_json::json!([{"id":"directory", "access":key::<custody::DirectoryAccess>(), "home":true, "nick":"peer", "nickAllocation":"exact", "standing":null}])).unwrap();
				original.conversations = serde_json::from_str(&serde_json::json!([row]).to_string()).unwrap();
				owner.replace_workspace(&original).await.unwrap();
				let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
				let sender = workspace.typing_sender("conversation", selected).await.unwrap();
				sender.set(true).await.unwrap();
				assert_eq!(calls.get(), 1);
				assert!(Workspace::local(host.clone(), platform.clone(), sibling.clone()).typing_sender("conversation", selected).await.is_err(), "equal permission cannot substitute for the initiating source");
				let raw = Ref::try_from(&host.send(&source, "typing-sender", &["conversation".into(), serde_json::to_string(&selected).unwrap().into(), serde_json::to_string(&requests::coordinate(custody::Role::SessionAccess, 1)).unwrap().into()]).await.unwrap()).unwrap();
				assert!(host.send(&raw, "post", &["forbidden".into()]).await.is_err());
				publication_results::lifecycle(&host, &control, "pause").await;
				assert!(sender.set(false).await.is_err());
				assert_eq!(calls.get(), 1);
				publication_results::lifecycle(&host, &control, "resume").await;
				sender.set(false).await.unwrap();
				assert_eq!(calls.get(), 2);
				let mut replaced_source = original.clone();
				let new_source = custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap());
				match &mut replaced_source.conversations.as_mut_slice()[0] {
					session::workspace::Conversation::Room(row) => row.source = Some(new_source),
					session::workspace::Conversation::Direct(row) => row.source = Some(new_source),
				}
				owner.replace_workspace(&replaced_source).await.unwrap();
				assert!(sender.set(true).await.is_err(), "source selection stays exact even when another field aliases the held grant");
				assert_eq!(calls.get(), 2);
				owner.replace_workspace(&original).await.unwrap();
				let mut changed = original.clone();
				match &mut changed.conversations.as_mut_slice()[0] {
					session::workspace::Conversation::Room(row) => row.seat = Some(custody::FieldKey::new(next.key.slot(), next.key.generation())),
					session::workspace::Conversation::Direct(row) => row.access = Some(custody::FieldKey::new(next.key.slot(), next.key.generation())),
				}
				owner.replace_workspace(&changed).await.unwrap();
				assert!(sender.set(true).await.is_err(), "retained sender cannot follow a replacement selection");
				assert!(workspace.typing_sender("conversation", selected).await.is_err());
				assert_eq!(calls.get(), 2);
				assert_eq!(replacement_calls.get(), 0);
				let next_sender = workspace.typing_sender("conversation", next).await.unwrap();
				next_sender.set(true).await.unwrap();
				assert_eq!(replacement_calls.get(), 1);
				match &mut changed.conversations.as_mut_slice()[0] {
					session::workspace::Conversation::Room(row) => {
						row.reconnect = session::workspace::Reconnect::Manual;
						row.seat = None;
					},
					session::workspace::Conversation::Direct(row) => row.closed = true,
				}
				owner.replace_workspace(&changed).await.unwrap();
				assert!(next_sender.set(false).await.is_err(), "retired selections cannot send typing");
					assert_eq!(replacement_calls.get(), 1);
					owner.replace_workspace(&original).await.unwrap();
					let tasks = platform.tasks.borrow().len();
					let mut entropy = realization::Entropy::new();
					platform.observation_suspended.set(true);
					let mut startup = Box::pin(async {
						match &original.conversations.as_slice()[0] {
							session::workspace::Conversation::Room(row) => owner.supervise_room(row, &original, &mut entropy, |_, _| Ok(())).await,
							session::workspace::Conversation::Direct(row) => owner.supervise_direct(row, &mut entropy, |_, _, _, _| Ok(Argument::Void)).await,
						}
					});
					std::future::poll_fn(|cx| {
						assert!(core::future::Future::poll(startup.as_mut(), cx).is_pending());
						core::task::Poll::Ready(())
					}).await;
					assert!(owner.close().await.is_err(), "an unspawned source restoration keeps the session open");
					platform.observation_suspended.set(false);
					assert!(startup.await.is_err(), "startup cannot create consumers after close begins");
					assert_eq!(platform.tasks.borrow().len(), tasks, "no change feed or membership is spawned during close");
					owner.close().await.unwrap();
				drop((sender, next_sender, raw, workspace, target, replacement, root, source, control, sibling, owner));
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				environment::close(&mut store).await;
				database.remove();
			}).await.expect("typing source proof deadline");
		}).await;
	}
}
