//! A room's identities are read through the exact seat the session holds
//! there: the facade reads over a seat on another Host, the wrong role refused
//! at the client and at the runtime, a retired seat refused, and a manager link
//! taken with no seat and no imported entrance refused. The forwarded verbs'
//! admission through the facade (the runtime's dependent requirement) is not
//! reached here; the browser proofs take that path.
use super::*;
use rooms_glowcap::client::workspace::Workspace;
use std::cell::RefCell;

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn room_identities_come_from_the_exact_held_seat() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new().run_until(async {
		environment::within(10_000, async {
			let database = Database::new("room-identity");
			let schemas = managed::schemas();
			let mut limits = managed::reader_limits(crate::session_storage::limits_for(24, 8, loam::ValueBounds {
				values: 32, capabilities: 4, bytes: 8192, ..Default::default()
			})).unwrap();
			limits.max_leases *= limits.max_operations;
			limits.pending_bytes = limits.call_bytes * 2;
			limits.ingress_bytes = limits.pending_bytes;
			let store = database.open(true, &schemas, limits).await;
			let policy = rooms_glowcap::policy::descriptor().unwrap();
			let resource = environment::create(&store, &policy, schemas[0], &managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay).unwrap(), 3).await;
			let host = Host::from_seed([122; 32]).unwrap();
			let platform = Platform::default();
			let owner = managed::Session::new(host.clone(), platform.clone(), std::num::NonZeroUsize::new(8192).unwrap());
			// The seat lives on the server's host, as a member's does, so every
			// identity read forwards through the session's facade to a remote peer.
			let server = Host::from_seed([123; 32]).unwrap();
			let handed = Rc::new(RefCell::new(None));
			let sink = host.spawn({
				let handed = handed.clone();
				move |verb, args| {
					let (Some("seat"), [Argument::Reference(seat)]) = (verb, args) else {
						return Err("the sink takes one seat".into());
					};
					handed.replace(Some(seat.clone()));
					Ok(Argument::Void)
				}
			}).unwrap();
			let (client, accepted) = management::connect(&host, &server, &sink).await;
			let remote_sink = Ref::try_from(&client.session().send(&client.session().fetch("management-bootstrap").await.unwrap(), "get", &[]).await.unwrap()).unwrap();
			let server_seat = server.spawn(move |verb, args| {
				let verb = verb.ok_or("fixture requires a method")?;
				assert!(args.is_empty(), "identity reads take no arguments");
				match verb {
					"managedRoomIdentity" => Ok(Argument::String("manager-identity".into())),
					"roomIdentity" => Ok(Argument::String("room-identity".into())),
					_ => Err(format!("the seat fixture has no method {verb}")),
				}
			}).unwrap();
			client.session().send(&remote_sink, "seat", &[Argument::Reference(server_seat.clone())]).await.unwrap();
			let seat_target = handed.borrow().clone().expect("the server handed its seat");
			let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
			environment::start_live(&attachment, None, 32).await;
			let (root, root_control) = environment::restore(&attachment, resource).await;
			owner.bind(root.clone(), root_control.clone()).unwrap();
			owner.initialize().await.unwrap();
			let terms = policy.value_for_kind(session::KIND, &session::SUPPORTED.iter().map(|p| p.key()).collect::<Vec<_>>(), &[]).unwrap();
			let powers = ControlPowers { pause: true, resume: true, revoke: true, ..Default::default() };
			let (source, control) = owner.derive(terms, 1, powers).await.unwrap();
			let seat = requests::coordinate(custody::Role::RoomSeat, 1);
			let access = requests::coordinate(custody::Role::RoomAccess, 1);
			owner.import(seat, seat_target.clone(), None).await.unwrap();
			owner.import(access, source.clone(), None).await.unwrap();
			owner.import(requests::coordinate(custody::Role::SessionAccess, 1), source.clone(), None).await.unwrap();
			owner.import(requests::coordinate(custody::Role::DirectoryAccess, 1), source.clone(), None).await.unwrap();
			let row = serde_json::json!({"kind":"room", "id":"conversation", "directory":"directory", "name":"room", "access":access.key, "seat":seat.key, "source":key::<custody::SessionAccess>(), "reconnect":"requested", "standing":null, "draft":""});
			let mut original = Intent::empty();
			original.directories = serde_json::from_value(serde_json::json!([{"id":"directory", "access":key::<custody::DirectoryAccess>(), "home":true, "nick":"peer", "nickAllocation":"exact", "standing":null}])).unwrap();
			original.conversations = serde_json::from_str(&serde_json::json!([row]).to_string()).unwrap();
			owner.replace_workspace(&original).await.unwrap();
			let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
			assert_eq!(workspace.room_management_identity(seat).await.unwrap(), "manager-identity");
			assert_eq!(workspace.room_identity(seat).await.unwrap(), "room-identity");
			let wrong_role = workspace.room_management_identity(access).await.unwrap_err().to_string();
			assert!(wrong_role.contains("requires a room seat"), "the client took room access as a seat: {wrong_role}");
			let runtime_role = host
				.send(&source, "room-identity-reader", &[serde_json::to_string(&access).unwrap().into()])
				.await
				.unwrap_err()
				.to_string();
			// The runtime refuses the coordinate before the facade exists, and
			// that stage answers with the refusal code alone. The client's own
			// role check above is the sentence a person reads.
			assert!(runtime_role.contains("ApplicationRefused"), "the runtime took room access as a seat: {runtime_role}");
			// A manager link taken with no seat and no entrance in the same
			// acquisition has nothing to prove the link against.
			let mut unseated = original.clone();
			if let rooms_application::content::session::workspace::Conversation::Room(room) = &mut unseated.conversations.as_mut_slice()[0] {
				room.seat = None;
				room.access = None;
				room.control = Some(key::<custody::RoomControl>());
			}
			let manager = rooms_glowcap::client::workspace::Import {
				coordinate: requests::coordinate(custody::Role::RoomControl, 1),
				reference: server_seat.clone(),
				uri: None,
			};
			let unproven = workspace.validate_room_authority_imports(&[manager], &unseated).await.unwrap_err().to_string();
			assert!(unproven.contains("join the room before taking a link"), "an unseated manager import was not refused: {unproven}");
			let mut departed = original.clone();
			if let rooms_application::content::session::workspace::Conversation::Room(room) = &mut departed.conversations.as_mut_slice()[0] {
				room.seat = None;
			}
			owner.replace_workspace(&departed).await.unwrap();
			let retired = workspace.room_management_identity(seat).await.unwrap_err().to_string();
			assert!(retired.contains("ApplicationRefused"), "a retired seat was still answered: {retired}");
			drop((workspace, seat_target, remote_sink, sink, server_seat, client, accepted, source, control, root, root_control, owner));
			attachment.close().await.unwrap();
		}).await;
	}).await;
}
