//! Callback retirement authenticates its source and removes only matching recipes.
use super::*;
use rooms_application::content::session::workspace::{self, Conversation, InboxSelection};
use rooms_glowcap::client::workspace::Workspace;

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn authority_notices_preserve_replacements_and_seats_without_restoring_withdrawn_exports() {
	run().await;
}
pub(super) async fn run() {
	for role in ["room", "steward", "manager"] {
		run_case(role).await;
	}
}
fn coordinate(role: custody::Role, slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
async fn run_case(role: &str) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new(&format!("authority-{role}"));
				let schemas = managed::schemas();
				let limits = crate::session_storage::limits_for(
					16,
					8,
					loam::ValueBounds {
						values: 32,
						capabilities: 8,
						bytes: 8192,
						..Default::default()
					},
				);
				let mut store = database.open(true, &schemas, limits).await;
				let descriptor = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&descriptor,
					schemas[0],
					&managed::initial_payload(workspace::Connection::Relay).unwrap(),
					3,
				)
				.await;
				let host = Host::from_seed([211; 32]).unwrap();
				let exporter = Host::from_seed([212; 32]).unwrap();
				let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9011");
				exporter.set_advertised_locator(&locator).unwrap();
				let token = exporter
					.publish_durable(|| Box::new(|_, _| Ok(Argument::Void)))
					.unwrap();
				let uri = glowcap::format_sturdyref(&locator, token.as_bytes(), glowcap::CaptpVersion::V1_0).unwrap();
				let (dialed, accepted) = results::connect(&host, &exporter, &locator, gate::Gate::default()).await;
				let target = host.enliven(&uri).await.unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
				environment::start_live(&attachment, None, 32).await;
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control).unwrap();
				owner.initialize().await.unwrap();
				let terms = descriptor
					.value_for_kind(
						session::KIND,
						&session::SUPPORTED
							.iter()
							.map(|permission| permission.key())
							.collect::<Vec<_>>(),
						&[],
					)
					.unwrap();
				let (source, control) = owner
					.derive(
						terms,
						1,
						ControlPowers {
							revoke: true,
							..Default::default()
						},
					)
					.await
					.unwrap();
				let (sibling, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
				for kind in [
					custody::Role::DirectoryAccess,
					custody::Role::RoomAccess,
					custody::Role::RoomControl,
					custody::Role::RoomSeat,
				] {
					owner
						.import(coordinate(kind, 1), target.clone(), (!kind.live()).then(|| uri.clone()))
						.await
						.unwrap();
				}
				owner
					.import(coordinate(custody::Role::SessionAccess, 1), source.clone(), None)
					.await
					.unwrap();
				let mut intent = Case::away().workspace(1);
				let Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.access = Some(key());
				room.control = Some(key());
				room.moderator = Some(key());
				room.source = Some(key());
				room.inbox = Some(key());
				room.reconnect = workspace::Reconnect::Requested;
				let mut alias = room.clone();
				alias.id = rooms_application::fields::Text::new("alias".into()).unwrap();
				intent.conversations.try_push(Conversation::Room(alias)).unwrap();
				let Conversation::Room(room) = &intent.conversations.as_slice()[0] else {
					panic!("room")
				};
				let selection = InboxSelection::room(room, &intent).unwrap();
				let mut inbox = owner.inbox(selection.clone(), |_| Ok(())).await.unwrap();
				owner
					.import(coordinate(custody::Role::RoomInbox, 1), inbox.reference().clone(), None)
					.await
					.unwrap();
				owner.replace_workspace(&intent).await.unwrap();
				let encoded = serde_json::to_string(&selection).unwrap();
				let args = |callback: &Ref, token: &str| {
					vec![
						root.clone().into(),
						encoded.clone().into(),
						callback.clone().into(),
						role.into(),
						token.into(),
					]
				};
				let before = host.send(&source, "snapshot", &[]).await.unwrap();
				let fake = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
				assert!(
					host.send(&source, "retire-room-authority", &args(&fake, &token))
						.await
						.is_err()
				);
				assert!(
					host.send(&sibling, "retire-room-authority", &args(inbox.reference(), &token))
						.await
						.is_err()
				);
				let mut no_owner = args(inbox.reference(), &token);
				no_owner[0] = source.clone().into();
				assert!(host.send(&source, "retire-room-authority", &no_owner).await.is_err());
				assert_eq!(
					host.send(
						&source,
						"retire-room-authority",
						&args(inbox.reference(), "wrong-token")
					)
					.await
					.unwrap(),
					Argument::Void
				);
				assert_eq!(host.send(&source, "snapshot", &[]).await.unwrap(), before);
				// A newly installed generation has a different canonical recipe. A late
				// notice for the prior publication cannot erase it, even at the same slot.
				let replacement = exporter
					.publish_durable(|| Box::new(|_, _| Ok(Argument::Void)))
					.unwrap();
				let replacement_uri =
					glowcap::format_sturdyref(&locator, replacement.as_bytes(), glowcap::CaptpVersion::V1_0).unwrap();
				let replacement_ref = host.enliven(&replacement_uri).await.unwrap();
				let selected_role = if role == "manager" {
					custody::Role::RoomControl
				} else {
					custody::Role::RoomAccess
				};
				let replacement_key = custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(2).unwrap());
				let mut replaced = intent.clone();
				for row in replaced.conversations.as_mut_slice() {
					let Conversation::Room(room) = row else { panic!("room") };
					if selected_role == custody::Role::RoomAccess {
						room.access = Some(custody::FieldKey::new(
							replacement_key.slot(),
							replacement_key.generation(),
						));
						room.moderator = Some(custody::FieldKey::new(
							replacement_key.slot(),
							replacement_key.generation(),
						));
					} else {
						room.control = Some(custody::FieldKey::new(
							replacement_key.slot(),
							replacement_key.generation(),
						));
					}
				}
				let replacement_coordinate = custody::Coordinate {
					role: selected_role,
					key: replacement_key,
				};
				let original_coordinate = coordinate(selected_role, 1);
				let workspace = Workspace::local(host.clone(), platform.clone(), root.clone());
				owner
					.acquire_workspace(
						&root,
						workspace.snapshot().await.unwrap().revision,
						vec![managed::Import {
							coordinate: replacement_coordinate,
							reference: replacement_ref,
							uri: Some(replacement_uri),
						}],
						&[original_coordinate],
						&replaced,
					)
					.await
					.unwrap();
				if selected_role == custody::Role::RoomAccess {
					assert!(
						host.send(&source, "retire-room-authority", &args(inbox.reference(), &token))
							.await
							.is_err(),
						"replacement entrance fences its old callback"
					);
				} else {
					assert_eq!(
						host.send(&source, "retire-room-authority", &args(inbox.reference(), &token))
							.await
							.unwrap(),
						Argument::Void
					);
				}
				assert_eq!(
					Workspace::local(host.clone(), platform.clone(), root.clone())
						.snapshot()
						.await
						.unwrap()
						.intent,
					replaced
				);
				owner
					.acquire_workspace(
						&root,
						workspace.snapshot().await.unwrap().revision,
						vec![managed::Import {
							coordinate: original_coordinate,
							reference: target,
							uri: Some(uri),
						}],
						&[replacement_coordinate],
						&intent,
					)
					.await
					.unwrap();
				// End the actual exporter connection. Retirement inspects retained
				// recipes and must not restore authority from this unavailable peer.
				dialed.close(PendingWork::Cancel).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				exporter.close(PendingWork::Cancel).await.unwrap();
				assert_eq!(
					host.send(&source, "retire-room-authority", &args(inbox.reference(), &token))
						.await
						.unwrap(),
					Argument::Void
				);
				let retired = Workspace::local(host.clone(), platform.clone(), root.clone())
					.snapshot()
					.await
					.unwrap()
					.intent;
				for row in retired.conversations.as_slice() {
					let Conversation::Room(room) = row else { panic!("room") };
					assert_eq!(room.seat, Some(key()), "independent seats survive authority retirement");
					if role == "manager" {
						assert_eq!(room.control, None);
						assert_eq!(room.access, Some(key()));
					} else {
						assert_eq!(room.access, None);
						assert_eq!(room.moderator, None);
						assert_eq!(room.control, Some(key()));
					}
				}
				publication_results::lifecycle(&host, &control, "revoke").await;
				assert!(
					host.send(&source, "retire-room-authority", &args(inbox.reference(), &token))
						.await
						.is_err()
				);
				inbox.close().await.unwrap();
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				environment::close(&mut store).await;
				database.remove();
			})
			.await
			.expect("authority retirement deadline");
		})
		.await;
}
