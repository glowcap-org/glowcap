//! Direct sharing preserves exact held authority under a retained source receipt.
use super::publication_results::{PEERING, coordinate, lifecycle, registration};
use super::*;
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn direct_room_sharing_keeps_original_targets_and_settles_under_source_pause() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("direct-room-sharing");
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
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					3,
				)
				.await;
				let mut resources = Vec::new();
				for payload in [b"direct".as_slice(), b"room", b"replacement"] {
					resources.push(environment::create(&store, &policy, PEERING, payload, 2).await);
				}
				let host = Host::from_seed([123; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let calls = Rc::new(Cell::new(0));
				let room = Rc::new(std::cell::RefCell::new(None));
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
							registration(
								calls.clone(),
								Rc::new(Cell::new(0)),
								room.clone(),
								Rc::new(Cell::new(false)),
							),
						],
					)
					.unwrap();
				attachment.start_live(None, 32).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				owner
					.activity()
					.bind_incarnation(attachment.live_incarnation().unwrap().unwrap())
					.unwrap();
				let mut held = Vec::new();
				for resource in resources {
					held.push(environment::restore(&attachment, resource).await.0);
				}
				*room.borrow_mut() = Some(held[1].clone());
				for (role, slot, reference) in [
					(custody::Role::DirectoryAccess, 1, &held[0]),
					(custody::Role::DirectAccess, 1, &held[0]),
					(custody::Role::DirectAccess, 2, &held[2]),
					(custody::Role::RoomAccess, 1, &held[1]),
					(custody::Role::RoomAccess, 2, &held[2]),
				] {
					owner
						.import(coordinate(role, slot), reference.clone(), None)
						.await
						.unwrap();
				}
				let mut intent = Case::kick().workspace(1);
				let session::workspace::Conversation::Room(selected) = &mut intent.conversations.as_mut_slice()[0]
				else {
					panic!("room")
				};
				selected.moderator = None;
				selected.access = Some(key());
				let mut conversations = intent.conversations.as_slice().to_vec();
				conversations.push(session::workspace::Conversation::Direct(Box::new(
					session::workspace::Direct {
						introduction: None,
						inbox: None,
						source: None,
						kind: session::workspace::DirectKind::Direct,
						id: rooms_application::fields::Text::new("direct".into()).unwrap(),
						directory: rooms_application::fields::Text::new("directory".into()).unwrap(),
						peer: rooms_application::fields::Text::new("peer".into()).unwrap(),
						access: Some(key()),
						closed: false,
						lines: List::default(),
						draft: rooms_application::fields::Text::new("".into()).unwrap(),
					},
				)));
				intent.conversations = List::new(conversations).unwrap();
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
				let base = host.send(&source, "snapshot", &[]).await.unwrap().as_list().unwrap()[0]
					.as_i64()
					.unwrap();
				let args = vec![
					"shared".into(),
					base.into(),
					"offerRoom".into(),
					"conversation".into(),
					"direct".into(),
				];
				let canonical =
					serde_json::to_string(&("shared", base, "offerRoom", ["conversation", "direct"])).unwrap();
				platform.suspended.set(true);
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("pending")
				);
				assert_eq!(calls.get(), 0);
				let session::workspace::Conversation::Room(selected) = &mut intent.conversations.as_mut_slice()[0]
				else {
					panic!("room")
				};
				selected.access = Some(custody::FieldKey::new(
					NonZeroU64::new(2).unwrap(),
					NonZeroU64::new(1).unwrap(),
				));
				let session::workspace::Conversation::Direct(selected) = &mut intent.conversations.as_mut_slice()[1]
				else {
					panic!("direct")
				};
				selected.access = Some(custody::FieldKey::new(
					NonZeroU64::new(2).unwrap(),
					NonZeroU64::new(1).unwrap(),
				));
				owner.replace_workspace(&intent).await.unwrap();
				platform.suspended.set(false);
				assert_eq!(
					finished(&host, &root, "shared", &source).await.as_str(),
					Some("unknown")
				);
				assert_eq!(calls.get(), 1);
				lifecycle(&host, &control, "pause").await;
				refuse.set(false);
				owner.resume_pending().unwrap();
				assert_eq!(
					finished(&host, &root, "shared", &source).await.as_str(),
					Some("committed")
				);
				assert!(
					host.send(&source, "effect-result", &["shared".into(), canonical.clone().into()])
						.await
						.is_err()
				);
				lifecycle(&host, &control, "resume").await;
				assert_eq!(
					host.send(&source, "effect-result", &["shared".into(), canonical.into()])
						.await
						.unwrap()
						.as_str(),
					Some("null")
				);
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(calls.get(), 1);
				let session::workspace::Conversation::Direct(selected) = &mut intent.conversations.as_mut_slice()[1]
				else {
					panic!("direct")
				};
				selected.access = Some(key());
				owner.replace_workspace(&intent).await.unwrap();
				let base = host.send(&source, "snapshot", &[]).await.unwrap().as_list().unwrap()[0]
					.as_i64()
					.unwrap();
				let posted = vec![
					"posted".into(),
					base.into(),
					"say".into(),
					"direct".into(),
					"a message".into(),
				];
				let post_intent = serde_json::to_string(&("posted", base, "say", ["direct", "a message"])).unwrap();
				platform.suspended.set(true);
				mutate(&host, &source, "command", &posted).await.unwrap();
				let session::workspace::Conversation::Direct(selected) = &mut intent.conversations.as_mut_slice()[1]
				else {
					panic!("direct")
				};
				selected.access = Some(custody::FieldKey::new(
					NonZeroU64::new(2).unwrap(),
					NonZeroU64::new(1).unwrap(),
				));
				owner.replace_workspace(&intent).await.unwrap();
				platform.suspended.set(false);
				assert_eq!(
					finished(&host, &root, "posted", &source).await.as_str(),
					Some("committed")
				);
				assert_eq!(calls.get(), 2);
				let data = host
					.send(&source, "effect-result", &["posted".into(), post_intent.into()])
					.await
					.unwrap();
				let posted_line: rooms_application::content::session::results::PostedLine =
					serde_json::from_str(data.as_str().unwrap()).unwrap();
				assert!(posted_line.line.is_none());
				assert_eq!(
					mutate(&host, &source, "command", &posted).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(
					calls.get(),
					2,
					"direct posts use the original receipt, never a fresh recipient"
				);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				database.remove();
			})
			.await
			.expect("direct sharing has bounded progress");
		})
		.await;
}
