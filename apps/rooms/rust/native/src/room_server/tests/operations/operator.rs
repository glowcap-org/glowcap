//! The operator capability under real CapTP: the inventories whole and
//! paged under one revision, search and retirement, stewardship and
//! manager issue, exact room removal, disconnection, resets, and the watch
//! that hears every change.
use super::*;

#[tokio::test]
async fn room_server_operator_reads_inventories_and_acts_on_exact_rows() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(60), operator())
				.await
				.expect("operator scenario deadline");
		})
		.await;
}

async fn operator() {
	use rooms_glowcap::client::{
		directory::Directory,
		room::{Room, SubscribeOptions},
		Client,
	};
	use std::{cell::RefCell, rc::Rc};
	let temp = Temp::new();
	let running = start_with(
		temp.0.clone(),
		tcp(),
		Asked {
			operator: true,
			..Default::default()
		},
	)
	.await;
	let swiss = running.capabilities[0].swiss.clone();
	let runtime = runtime().await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	let session = runtime
		.connect(&dial, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let op = session.fetch(&swiss).await.unwrap();

	// A watcher hears the revision at admission and on every change.
	let heard = Rc::new(RefCell::new(Vec::<i64>::new()));
	let sink = heard.clone();
	let observer = session
		.spawn_owned(move |verb, args| {
			match (verb, args.first()) {
				("changed", Some(Argument::Integer(revision))) => sink.borrow_mut().push(*revision),
				other => sink.borrow_mut().push(-(other.1.map_or(1, |_| 2))),
			}
			Ok(Argument::Void)
		})
		.unwrap();
	let admitted = session
		.send(&op, "watch", &[Argument::Reference(observer)])
		.await
		.unwrap();
	let Argument::Integer(admitted) = admitted else {
		panic!("a revision, not {admitted:?}");
	};

	// A member in a room fills the inventories. Its own runtime, because one
	// Host keeps one session per partner.
	let member_runtime = super::runtime().await;
	let member_session = member_runtime
		.connect(&dial, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let client = Client::new(member_session.borrowed(), crate::client::Deadline);
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let garden = directory.open("garden").await.unwrap();
	let events = Rc::new(RefCell::new(Vec::<String>::new()));
	let noted = events.clone();
	let (room, mut messages) = Room::subscribe(
		client.clone(),
		garden,
		"alice",
		SubscribeOptions {
			voucher: None,
			on_event: Box::new(move |event| {
				if let rooms_glowcap::client::room::Event::Ended(reason) = event {
					noted.borrow_mut().push(reason.to_string());
				}
			}),
		},
	)
	.await
	.unwrap();
	assert!(room.bridge_form().await.unwrap().is_none());
	tokio::time::timeout(Duration::from_secs(5), messages.next())
		.await
		.expect("the roster in time")
		.expect("the room stayed open")
		.expect("the roster line");
	tokio::time::timeout(Duration::from_secs(5), async {
		while heard.borrow().last().is_none_or(|last| *last <= admitted) {
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("the watcher heard the room change");

	// The whole inventory, every category in order under one revision.
	let (revision, pages) = whole(&session.send(&op, "operatorSnapshot", &[]).await.unwrap());
	assert_eq!(
		pages.keys().cloned().collect::<Vec<_>>(),
		[
			"links",
			"references",
			"registrations",
			"rooms",
			"sessions",
			"stewardships",
			"trouble"
		]
	);
	let (_, rooms_rows, rooms_total) = &pages["rooms"];
	assert_eq!(*rooms_total, 1);
	let garden_row = &rooms_rows[0];
	assert_eq!(text(garden_row, 1), "local");
	assert_eq!(text(garden_row, 2), "garden");
	let members = rows(&garden_row[6]);
	assert_eq!(text(&members[0], 0), "alice");
	let garden_id = text(garden_row, 0).to_string();
	let (_, session_rows, session_total) = &pages["sessions"];
	assert_eq!(*session_total, 2);
	assert_eq!(session_rows.iter().filter(|row| boolean(row, 3)).count(), 1);
	let member_id = session_rows
		.iter()
		.find(|row| !boolean(row, 3))
		.map(|row| text(row, 0).to_string())
		.unwrap();
	let (_, reference_rows, _) = &pages["references"];
	assert!(reference_rows
		.iter()
		.any(|row| text(row, 1) == "membership" && text(row, 4) == "alice"));
	assert_eq!(pages["stewardships"].2, 1, "the live room is a stewardship row");
	assert!(!boolean(&pages["stewardships"].1[0], 4));

	// One page, cut by category, cursor, and limit, and the refusals.
	let page = cells(
		&session
			.send(
				&op,
				"operatorSnapshot",
				&[
					Argument::String("rooms".into()),
					Argument::Integer(0),
					Argument::Integer(32),
				],
			)
			.await
			.unwrap(),
	);
	assert_eq!(int(&page, 0), revision);
	assert_eq!(page[1], Argument::Void);
	assert_eq!(int(&page, 3), 1);
	assert!(refused(
		&session,
		&op,
		"operatorSnapshot",
		&[
			Argument::String("nope".into()),
			Argument::Integer(0),
			Argument::Integer(32)
		],
	)
	.await
	.contains("operatorSnapshot category is unknown"));
	assert!(refused(
		&session,
		&op,
		"operatorSnapshot",
		&[
			Argument::String("rooms".into()),
			Argument::Integer(0),
			Argument::Integer(33)
		],
	)
	.await
	.contains("cursor or limit is out of range"));
	assert!(refused(&session, &op, "nope", &[])
		.await
		.contains("Rooms operator has no method nope"));

	// Stewardship: issued, usable, revoked, and refused when nothing stands.
	let issued = cells(
		&session
			.send(&op, "giveSteward", &[Argument::String("garden".into())])
			.await
			.unwrap(),
	);
	assert_eq!(text(&issued, 0), "garden");
	assert!(boolean(&issued, 4));
	let steward_link = text(&issued, 5).to_string();
	assert!(steward_link.starts_with("ocapn://"));
	let steward = session.enliven(&steward_link).await.unwrap();
	// A steward governs a room identity, the opaque name a room keeps
	// across its public names.
	assert!(matches!(
		session.send(&steward, "governs", &[]).await.unwrap(),
		Argument::String(identity) if !identity.is_empty()
	));
	let revoked = cells(
		&session
			.send(&op, "revokeSteward", &[Argument::String("garden".into())])
			.await
			.unwrap(),
	);
	assert!(!boolean(&revoked, 4));
	assert!(session.send(&steward, "governs", &[]).await.is_err());
	assert!(
		refused(&session, &op, "revokeSteward", &[Argument::String("garden".into())])
			.await
			.contains("not-steward")
	);
	assert!(
		refused(&session, &op, "giveSteward", &[Argument::String("nowhere".into())])
			.await
			.contains("no-such-room")
	);
	let management_identity = member_session
		.send(room.reference(), "managedRoomIdentity", &[])
		.await
		.unwrap();
	let manager = session.send(&op, "giveManager", &[management_identity]).await.unwrap();
	let manager = session.enliven(manager.as_str().unwrap()).await.unwrap();
	assert!(matches!(
		session.send(&manager, "governs", &[]).await.unwrap(),
		Argument::String(_)
	));

	// The links inventory holds the room link the stewardship made; revoking
	// it by name empties the inventory.
	let (_, pages) = whole(&session.send(&op, "operatorSnapshot", &[]).await.unwrap());
	assert_eq!(pages["links"].2, 1);
	session
		.send(&op, "revokeRoomLink", &[Argument::String("garden".into())])
		.await
		.unwrap();
	let (_, pages) = whole(&session.send(&op, "operatorSnapshot", &[]).await.unwrap());
	assert_eq!(pages["links"].2, 0);

	// The search counts every match and retires past its page; the room
	// goes by its exact id and its member hears why.
	let batch = cells(
		&session
			.send(
				&op,
				"operatorRetireMatching",
				&[
					Argument::String("rooms".into()),
					Argument::String("gar".into()),
					Argument::Integer(4),
				],
			)
			.await
			.unwrap(),
	);
	assert_eq!((int(&batch, 0), int(&batch, 1), text(&batch, 2)), (1, 0, ""));
	assert!(
		refused(&session, &op, "removeOperatorRoom", &[Argument::String(garden_id)])
			.await
			.contains("no longer present")
	);
	tokio::time::timeout(Duration::from_secs(5), async {
		// The stream drains to its end; the room's word arrives as the
		// ended event beside it.
		while let Ok(Some(_)) = messages.next().await {}
		while !events.borrow().iter().any(|reason| reason.contains("operator removed")) {
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("the member heard the room end");
	drop(room);

	// Sessions: the operator's own stays; another goes.
	let own = session_rows
		.iter()
		.find(|row| boolean(row, 3))
		.map(|row| text(row, 0).to_string())
		.unwrap();
	assert!(refused(&session, &op, "disconnectSession", &[Argument::String(own)])
		.await
		.contains("is this operator"));
	session
		.send(&op, "disconnectSession", &[Argument::String(member_id)])
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(5), member_session.closed())
		.await
		.expect("the disconnected member's session ended")
		.ok();

	// A full reset retires rooms before it closes their peer sessions. The
	// terminal reason must survive that close rather than becoming transport loss.
	let reset_session = member_runtime
		.connect(&dial, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let reset_client = Client::new(reset_session.borrowed(), crate::client::Deadline);
	let reset_directory = Directory::fetch(reset_client.clone()).await.unwrap();
	let reset_events = Rc::new(RefCell::new(Vec::<String>::new()));
	let noted = reset_events.clone();
	let (reset_room, mut reset_messages) = Room::subscribe(
		reset_client,
		reset_directory.open("reset-room").await.unwrap(),
		"alice",
		SubscribeOptions {
			voucher: None,
			on_event: Box::new(move |event| {
				if let rooms_glowcap::client::room::Event::Ended(reason) = event {
					noted.borrow_mut().push(reason.to_string());
				}
			}),
		},
	)
	.await
	.unwrap();
	tokio::time::timeout(Duration::from_secs(5), reset_messages.next())
		.await
		.expect("the reset room roster in time")
		.expect("the reset room stayed open")
		.expect("the reset room roster line");
	let second_runtime = super::runtime().await;
	let second_session = second_runtime
		.connect(&dial, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let second_client = Client::new(second_session.borrowed(), crate::client::Deadline);
	let second_directory = Directory::fetch(second_client.clone()).await.unwrap();
	let second_events = Rc::new(RefCell::new(Vec::<String>::new()));
	let noted = second_events.clone();
	let (second_room, mut second_messages) = Room::subscribe(
		second_client,
		second_directory.enter("reset-room").await.unwrap(),
		"bob",
		SubscribeOptions {
			voucher: None,
			on_event: Box::new(move |event| {
				if let rooms_glowcap::client::room::Event::Ended(reason) = event {
					noted.borrow_mut().push(reason.to_string());
				}
			}),
		},
	)
	.await
	.unwrap();
	tokio::time::timeout(Duration::from_secs(5), second_messages.next())
		.await
		.expect("the second reset room roster in time")
		.expect("the second reset room stayed open")
		.expect("the second reset room roster line");

	// The journal clears on the operator's word, and a reset of everything
	// answers; unknown scopes refuse.
	session.send(&op, "clearOperatorTrouble", &[]).await.unwrap();
	assert!(
		refused(&session, &op, "resetOperatorScope", &[Argument::String("nope".into())])
			.await
			.contains("unknown operator reset scope")
	);
	session
		.send(&op, "resetOperatorScope", &[Argument::String("all".into())])
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(5), async {
		while [&reset_events, &second_events].iter().any(|events| {
			!events
				.borrow()
				.iter()
				.any(|reason| reason.starts_with("room-retired: "))
		}) {
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("factory reset delivered terminal room retirement before session close");
	let (first_closed, second_closed) = tokio::join!(
		tokio::time::timeout(Duration::from_secs(5), reset_session.closed()),
		tokio::time::timeout(Duration::from_secs(5), second_session.closed()),
	);
	first_closed
		.expect("factory reset closed the first retired room session")
		.ok();
	second_closed
		.expect("factory reset closed the second retired room session")
		.ok();
	drop((reset_room, reset_directory, second_room, second_directory));
	session.send(&op, "unwatch", &[]).await.unwrap();
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	member_runtime.close(PendingWork::Cancel).await.unwrap();
	second_runtime.close(PendingWork::Cancel).await.unwrap();
}
