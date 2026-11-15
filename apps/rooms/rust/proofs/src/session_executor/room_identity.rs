//! A room's identities are read through the exact seat the session holds
//! there: the facade reads over a seat on another Host, the wrong role refused
//! at the client and at the runtime, and a manager link taken with no seat and
//! no imported entrance refused. A seat the session does not select reads
//! two ways: the direct identity reads refuse it with their own sentence, and
//! the validation of a candidate that names it reports a workspace conflict.
//! An imported entrance whose manager identity the held seat answers folds onto
//! that seat's row, and one to another room keeps its own. The forwarded verbs'
//! admission through the facade (the runtime's dependent requirement) is not
//! reached here; the browser proofs take that path.
use super::*;
use rooms_glowcap::client::workspace::Workspace;
use std::cell::RefCell;

/// What the fixture's seat answers when it is asked as a moderator link. Only
/// a validation that read the held seat reaches that call.
const LINK_REFUSAL: &str = "the fixture link refuses to say what it governs";

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
			let reports = Rc::new(RefCell::new(Vec::<(String, String)>::new()));
			owner.on_trouble({
				let reports = reports.clone();
				move |operation, cause| reports.borrow_mut().push((operation.to_owned(), cause.to_string()))
			}).unwrap();
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
					"governs" => Err(LINK_REFUSAL.into()),
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
			// A link to the room the seat stands in is that room's way in, not a
			// second row: the standing row takes the import as its access.
			let entrance = |called: &'static str, identity: &'static str| {
				server.spawn(move |verb, args| {
					let verb = verb.ok_or("fixture requires a method")?;
					assert!(args.is_empty(), "entrance reads take no arguments");
					match verb {
						"called" => Ok(Argument::String(called.into())),
						"managedRoomIdentity" => Ok(Argument::String(identity.into())),
						_ => Err(format!("the entrance fixture has no method {verb}")),
					}
				}).unwrap()
			};
			let staged_access = requests::coordinate(custody::Role::RoomAccess, 2);
			let staged = serde_json::json!({"kind":"room", "id":"staged", "directory":"directory", "name":"shared room", "access":staged_access.key, "source":key::<custody::SessionAccess>(), "reconnect":"requested", "standing":null, "draft":""});
			let two_rows = || -> Intent {
				let mut intent = original.clone();
				intent.conversations = serde_json::from_str(&serde_json::json!([row, staged]).to_string()).unwrap();
				intent
			};
			let rooms = |intent: &Intent| -> Vec<rooms_application::content::session::workspace::Room> {
				intent.conversations.as_slice().iter().filter_map(|row| match row {
					rooms_application::content::session::workspace::Conversation::Room(room) => Some(room.as_ref().clone()),
					_ => None,
				}).collect()
			};
			// The entrance reaches this host as the seat did: handed over the session.
			let same_room = entrance("room", "manager-identity");
			client.session().send(&remote_sink, "seat", &[Argument::Reference(same_room.clone())]).await.unwrap();
			let same_room_here = handed.borrow().clone().expect("the server handed the entrance");
			let mut folded = two_rows();
			let staged_source = custody::Coordinate::new(custody::Role::SessionAccess, key::<custody::SessionAccess>());
			let mut imports = vec![
				rooms_glowcap::client::workspace::Import { coordinate: staged_access, reference: same_room_here.clone(), uri: None },
				rooms_glowcap::client::workspace::Import { coordinate: staged_source, reference: same_room_here, uri: None },
			];
			workspace.resolve_imported_rooms(&mut imports, &mut folded).await.unwrap();
			assert_eq!(
				imports.iter().map(|import| import.coordinate).collect::<Vec<_>>(),
				[staged_access],
				"the fold kept an import no row refers to"
			);
			let kept = rooms(&folded);
			assert_eq!(kept.len(), 1, "a link to the room stood in made a second row");
			assert_eq!(kept[0].id.text().as_str(), Some("conversation"), "the staged row survived instead of the seated one");
			assert_eq!(kept[0].access.map(|key| key.slot()), Some(staged_access.key.slot()), "the seated row did not take the link as its access");
			assert_eq!(kept[0].seat.map(|key| key.slot()), Some(seat.key.slot()), "the fold lost the seat");
			let other_room = entrance("garden", "other-identity");
			client.session().send(&remote_sink, "seat", &[Argument::Reference(other_room.clone())]).await.unwrap();
			let other_room_here = handed.borrow().clone().expect("the server handed the entrance");
			let mut apart = two_rows();
			let mut imports = vec![rooms_glowcap::client::workspace::Import { coordinate: staged_access, reference: other_room_here, uri: None }];
			workspace.resolve_imported_rooms(&mut imports, &mut apart).await.unwrap();
			assert_eq!(imports.len(), 1, "a row that stays keeps its import");
			let kept = rooms(&apart);
			assert_eq!(kept.len(), 2, "a link to another room was folded away");
			assert_eq!(kept[1].name.text().as_str(), Some("garden"), "the imported room did not take its name");
			drop((same_room, other_room));
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
			stale_candidate(&workspace, &owner, &original, &seat_target, &reports).await;
			let mut departed = original.clone();
			if let rooms_application::content::session::workspace::Conversation::Room(room) = &mut departed.conversations.as_mut_slice()[0] {
				room.seat = None;
			}
			owner.replace_workspace(&departed).await.unwrap();
			assert_not_held(&workspace, seat).await;
			drop((workspace, seat_target, remote_sink, sink, server_seat, client, accepted, source, control, root, root_control, owner));
			attachment.close().await.unwrap();
		}).await;
	}).await;
}

/// The direct identity reads refuse a seat the session does not select, with
/// the sentence the client owns for it.
async fn assert_not_held(workspace: &Workspace<Platform>, seat: custody::Coordinate) {
	let manager = workspace.room_management_identity(seat).await;
	let link = workspace.room_identity(seat).await;
	for (read, outcome) in [("manager identity", manager), ("room identity", link)] {
		let text = outcome.as_ref().err().map(ToString::to_string);
		assert!(
			text.as_deref()
				.is_some_and(|text| text.ends_with("the session does not hold that room seat")),
			"the {read} of an unselected seat read as {outcome:?}"
		);
	}
}

/// A moderator link prepared from a candidate that names a seat the session
/// replaced is validated as a workspace conflict. The direct read of that seat
/// refuses.
async fn stale_candidate(
	workspace: &Workspace<Platform>,
	owner: &managed::Session<Platform>,
	original: &Intent,
	seat_target: &Ref,
	reports: &RefCell<Vec<(String, String)>>,
) {
	use rooms_application::content::session::workspace::Conversation;
	let moderator_key = requests::coordinate(custody::Role::RoomAccess, 3).key.retag();
	let mut candidate = original.clone();
	let Conversation::Room(room) = &mut candidate.conversations.as_mut_slice()[0] else {
		panic!("the fixture holds one room")
	};
	room.moderator = Some(moderator_key);
	let moderator = || rooms_glowcap::client::workspace::Import {
		coordinate: custody::Coordinate::new(custody::Role::RoomAccess, moderator_key),
		reference: seat_target.clone(),
		uri: None,
	};
	let before = reports.borrow().len();
	let held = workspace
		.validate_room_authority_imports(&[moderator()], &candidate)
		.await;
	let reached = held.as_ref().err().map(ToString::to_string);
	assert!(
		reached.as_deref().is_some_and(|text| text.contains(LINK_REFUSAL)),
		"a held seat did not reach the link: {held:?}"
	);
	assert_eq!(
		reports.borrow().len(),
		before,
		"a held seat reported a refusal: {:?}",
		reports.borrow()
	);
	// The session replaces the room's seat.
	let replaced = requests::coordinate(custody::Role::RoomSeat, 1);
	let replacement = requests::coordinate(custody::Role::RoomSeat, 2);
	owner.import(replacement, seat_target.clone(), None).await.unwrap();
	let mut moved = original.clone();
	let Conversation::Room(room) = &mut moved.conversations.as_mut_slice()[0] else {
		panic!("the fixture holds one room")
	};
	room.seat = Some(replacement.key.retag());
	owner.replace_workspace(&moved).await.unwrap();
	let stale = workspace
		.validate_room_authority_imports(&[moderator()], &candidate)
		.await;
	assert!(
		matches!(stale, Err(rooms_glowcap::client::Error::WorkspaceConflict)),
		"a replaced seat validated as {stale:?}, reports {:?}",
		reports.borrow()
	);
	assert_not_held(workspace, replaced).await;
}
