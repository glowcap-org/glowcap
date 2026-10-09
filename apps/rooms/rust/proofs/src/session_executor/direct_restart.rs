//! Physical reopen preserves intent without claiming old Host callbacks work.
use super::*;
use managed::{Bootstrap, BootstrapOptions};
use rooms_application::content::session::workspace::{Connection, Conversation};

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn reopened_workspace_keeps_data_but_retires_host_registrations() {
	run().await;
}

pub(super) async fn run() {
	tokio::task::LocalSet::new().run_until(async {
		for witness in [false, true] {
			environment::within(10_000, async {
				let database = Database::new(if witness { "direct-restart-witness" } else { "direct-restart" });
				let schemas = managed::schemas();
				let mut limits = crate::session_storage::limits_for(24, 8, loam::ValueBounds {
					values: 512, capabilities: 8, bytes: 65536, ..Default::default()
				});
				limits.pending_bytes = limits.call_bytes * limits.max_operations;
				limits.ingress_bytes = limits.pending_bytes;
				limits.max_leases *= limits.max_operations;
				limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
				limits.resident_bytes = limits.cache_slots * limits.record_bytes;
				let persisted = Rc::new(Cell::new(Bootstrap {
					seed: [157; 32], store_identity: [158; 16], owner_identity: [159; 16], anchor: None,
				}));
				let mut history = None;
				for fresh in [true, false] {
					let store = database.open(fresh, &schemas, limits).await;
					let host = Host::from_seed(persisted.get().seed).unwrap();
					let mut opened = persisted.get().open(store, host.clone(), Platform::default(), BootstrapOptions {
						reply_bytes: std::num::NonZeroUsize::new(65536).unwrap(), live_capacity: 64,
						initial_connection: Connection::Relay,
					}, {
						let persisted = persisted.clone();
						move |next| { persisted.set(next); std::future::ready(Ok(())) }
					}).await.unwrap();
					let workspace = opened.workspace().unwrap();
					if fresh {
						let actor = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
						for (role, reference) in [
							(custody::Role::DirectoryAccess, opened.access().unwrap().clone()),
							(custody::Role::SessionAccess, opened.access().unwrap().clone()),
							(custody::Role::RoomAccess, opened.access().unwrap().clone()),
							(custody::Role::DirectAccess, actor.clone()),
							(custody::Role::DirectoryName, actor.clone()),
							(custody::Role::DirectoryInbox, actor.clone()),
							(custody::Role::PublicationLease, actor.clone()),
						] {
							opened.session().import(requests::coordinate(role, 1), reference, None).await.unwrap();
						}
						opened.session().import(requests::coordinate(custody::Role::DirectInbox, 2), actor.clone(), None).await.unwrap();
						opened.session().import(requests::coordinate(custody::Role::Line, 3), actor.clone(), None).await.unwrap();
						let introduction = witness.then(|| serde_json::json!({
							"access": key::<custody::DirectoryAccess>(),
							"name": key::<custody::DirectoryName>(),
							"callback": key::<custody::DirectoryInbox>(),
							"registration": "12345678-1234-4234-8234-123456789abc",
							"opening": "saved-opening",
						}));
						let mut intent = Intent::decode(&serde_json::json!({
							"version":1,
							"directories":[{"id":"directory","access":key::<custody::DirectoryAccess>(),"source":key::<custody::SessionAccess>(),"name":key::<custody::DirectoryName>(),"inbox":key::<custody::DirectoryInbox>(),"assignedNick":"ada","home":true,"nick":"ada","nickAllocation":"exact","standing":null}],
							"conversations":[{"kind":"direct","id":"conversation","directory":"directory","peer":"peer","source":key::<custody::SessionAccess>(),"access":key::<custody::DirectAccess>(),"inbox":requests::coordinate(custody::Role::DirectInbox, 2).key,"lines":[{"id":1,"handle":requests::coordinate(custody::Role::Line, 3).key}],"closed":false,"draft":"preserved draft","introduction":introduction}],
							"invitations":[],"active":"conversation","standing":"preserved standing","ignored":[],"keepHistory":true,"connection":"relay","archive":null,"archiveControl":null,"operators":[],"peering":[{"id":"publication","directory":"directory","name":"annex-here","room":key::<custody::RoomAccess>(),"lease":key::<custody::PublicationLease>()}]
						}).to_string()).unwrap();
						if witness {
							intent.conversations.try_push(serde_json::from_str(&serde_json::json!({
								"kind":"room", "id":"source-room", "directory":"directory", "name":"annex",
								"access":key::<custody::RoomAccess>(), "control":null,
								"reconnect":"manual", "standing":null, "draft":"",
							}).to_string()).unwrap()).unwrap();
						}
						opened.session().replace_workspace(&intent).await.unwrap();
						assert_eq!(opened.session().restore_custody(&[requests::coordinate(custody::Role::DirectAccess, 1)]).await.unwrap()[0], actor);
						let Conversation::Direct(row) = &intent.conversations.as_slice()[0] else { unreachable!() };
						history = Some(row.history_id());
					} else {
						let snapshot = workspace.snapshot().await.unwrap();
						assert!(snapshot.intent.peering.is_empty(), "a new Host cannot keep the previous publisher connection's lease");
						assert_eq!(opened.session().restore_custody(&[requests::coordinate(custody::Role::RoomAccess, 1)]).await.is_ok(), witness, "retirement preserves independently selected room custody");
						let directory = &snapshot.intent.directories.as_slice()[0];
						assert!(directory.name.is_none() && directory.inbox.is_none() && directory.assigned_nick.is_none(), "a saved registration cannot declare a fresh Host ready");
						assert_eq!(directory.nick.text().as_str(), Some("ada"));
						assert_eq!(directory.source, Some(key::<custody::SessionAccess>()));
						// An introduction may still retain its exact saved witness. That
						// occurrence cannot restore an actor owned by the previous Host.
						assert!(opened.session().restore_custody(&[requests::coordinate(custody::Role::DirectoryName, 1)]).await.is_err());
						assert!(opened.session().restore_custody(&[requests::coordinate(custody::Role::DirectoryInbox, 1)]).await.is_err());
						let Conversation::Direct(row) = &snapshot.intent.conversations.as_slice()[0] else { unreachable!() };
						assert!(row.closed, "a saved field cannot make a fresh Host's DM sendable");
						assert!(row.access.is_none() && row.inbox.is_none() && row.lines.is_empty());
						assert_eq!(&row.history_id(), history.as_ref().unwrap());
						assert_eq!(row.draft.text().as_str(), Some("preserved draft"));
						assert_eq!(row.source, Some(key::<custody::SessionAccess>()));
						assert_eq!(row.introduction.is_some(), witness);
						if let Some(introduction) = &row.introduction {
							assert_eq!(introduction.registration.text().as_str(), Some("12345678-1234-4234-8234-123456789abc"));
							assert_eq!(introduction.opening.text().as_str(), Some("saved-opening"));
						}
						assert_eq!(snapshot.intent.active.as_ref().unwrap().text().as_str(), Some("conversation"));
						assert_eq!(snapshot.intent.standing.text().as_str(), Some("preserved standing"));
						assert!(opened.session().restore_custody(&[requests::coordinate(custody::Role::DirectAccess, 1)]).await.is_err());
						assert!(opened.session().restore_custody(&[requests::coordinate(custody::Role::DirectInbox, 2)]).await.is_err());
						assert!(opened.session().restore_custody(&[requests::coordinate(custody::Role::Line, 3)]).await.is_err());
						assert_eq!(opened.session().restore_custody(&[requests::coordinate(custody::Role::SessionAccess, 1)]).await.unwrap()[0], *opened.access().unwrap());
						assert!(mutate(&host, opened.access().unwrap(), "retire-host-registrations", &[]).await.is_err(), "a public source cannot retire another owner's registrations or live routes");
					}
					opened.close().await.unwrap();
					drop(opened);
					host.close(PendingWork::Cancel).await.unwrap();
				}
				database.remove();
			}).await.expect("direct restart contract deadline");
		}
	}).await;
}
