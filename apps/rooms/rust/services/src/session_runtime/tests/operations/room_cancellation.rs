//! Cancellation retires authority reservations; only uncorrelated peers need rejoin.
use super::*;
use rooms_runtime::{rooms::RoomRuntime, session::bridge_secrets::BridgeSecrets};
use std::cell::{Cell, RefCell};

#[tokio::test]
async fn cancelled_legacy_posts_rejoin_before_accepting_more_line_authority() {
	deadline(exercise(false)).await;
}
#[tokio::test]
async fn cancelled_retained_posts_release_authority_capacity_without_rejoining() {
	deadline(exercise(true)).await;
}
async fn exercise(retained: bool) {
	let fixture = Fixture::new(if retained {
		"retained-cancellation"
	} else {
		"legacy-cancellation"
	})
	.await;
	let subscriptions = Rc::new(Cell::new(0));
	let edits = Rc::new(RefCell::new(Vec::new()));
	let room_actor = publish(&fixture.arrival.session, subscriptions.clone(), edits.clone(), retained);
	let locator = fixture.peer.locator();
	let link = glowcap::format_sturdyref(
		&glowcap::parse_locator(&locator).unwrap(),
		b"cancellation-room",
		glowcap::CaptpVersion::V1_0,
	)
	.unwrap();
	command(
		&fixture.commands,
		"join-cancellation",
		Command::JoinRoom,
		vec![
			json!({
				"locator": locator, "nick": "alice", "conversation": {
					"kind": "room", "id": "cancellation", "directory": fixture.id,
					"name": "cancellation", "link": link, "held": false, "standing": null, "draft": ""
				}
			})
			.to_string()
			.into(),
		],
	)
	.await;
	let secrets = BridgeSecrets::open(rooms_runtime::documents::VolatileDocument::new(
		rooms_application::documents::SessionDocument::BridgeSecrets,
	))
	.await
	.unwrap();
	let (rooms, worker, mut events) = RoomRuntime::open(
		fixture.platform.clone(),
		rooms_platform::OsEntropy,
		fixture.runtime.clone(),
		fixture.commands.clone(),
		secrets,
		None,
	)
	.unwrap();
	let worker = tokio::task::spawn_local(worker.run());
	let mut changed = rooms.changes();
	loop {
		changed.borrow_and_update();
		if rooms.connected("cancellation") {
			break;
		}
		changed.changed().await.unwrap();
	}
	// Exercise both uncertainty shapes: no echo, and an echo whose reply
	// observer disappeared. Neither can leave the next line's FIFO shifted.
	// Retained refusals exceed the authority-slot ceiling without any line
	// event removing a slot. Native loopback keeps this pressure proof cheap.
	let attempts = if retained { 2002 } else { 2 };
	for attempt in 0..attempts {
		let text = if attempt + 1 == attempts { "accepted" } else { "refused" };
		let previous = rooms.live("cancellation").unwrap();
		assert_eq!(previous.supports_retained(), retained);
		let before = subscriptions.get();
		let (reached, resume) = fixture.platform.pause_next();
		{
			let mut send = core::pin::pin!(rooms.say("cancellation", text));
			tokio::select! {
				_ = &mut send => panic!("reply was not paused"),
				result = reached => result.unwrap(),
			}
		}
		drop(resume);
		if retained {
			assert!(Rc::ptr_eq(&rooms.live("cancellation").unwrap(), &previous));
			assert_eq!(subscriptions.get(), before);
			if attempt + 1 != attempts {
				continue;
			}
		} else {
			assert!(
				rooms.say("cancellation", "too soon").await.is_err(),
				"resync admission is synchronous"
			);
			loop {
				changed.borrow_and_update();
				if rooms
					.live("cancellation")
					.is_ok_and(|live| !Rc::ptr_eq(&live, &previous))
				{
					break;
				}
				changed.changed().await.unwrap();
			}
			assert_eq!(subscriptions.get(), before + 1);
		}
		rooms
			.say("cancellation", "recovered")
			.await
			.map_err(rooms_runtime::Error::from)
			.unwrap();
		loop {
			let event = events.next().await.unwrap();
			if event.text == "recovered" {
				assert!(event.editable);
				rooms
					.edit("cancellation", event.line_id.unwrap(), "edited")
					.await
					.map_err(rooms_runtime::Error::from)
					.unwrap();
				break;
			}
		}
	}
	assert_eq!(*edits.borrow(), vec!["recovered"; if retained { 1 } else { 2 }]);
	rooms.close().await.unwrap();
	worker.await.unwrap().unwrap();
	drop(room_actor);
	fixture.close().await;
}

fn publish(
	session: &glowcap::Session,
	subscriptions: Rc<Cell<u32>>,
	edits: Rc<RefCell<Vec<String>>>,
	retained: bool,
) -> glowcap::Ref {
	let hosted = session.borrowed();
	let sequence = Rc::new(Cell::new(0u64));
	session
		.publish("cancellation-room", move |verb, args| match verb {
			"subscribe" => {
				subscriptions.set(subscriptions.get() + 1);
				let Argument::Reference(inbox) = &args[1] else {
					panic!("subscription inbox");
				};
				if retained {
					hosted
						.tell(
							inbox,
							"notify",
							&["room".into(), "".into(), "carries".into(), "retained".into()],
						)
						.unwrap();
				}
				hosted
					.tell(
						inbox,
						"notify",
						&["room".into(), "".into(), "roster".into(), "alice".into()],
					)
					.unwrap();
				let (inbox, host, sequence, edits) =
					(inbox.clone(), hosted.borrowed(), sequence.clone(), edits.clone());
				let seat = hosted
					.spawn_owned(move |verb, args| match verb {
						"post" | "postRetained" => {
							let text = args[0].as_str().unwrap().to_owned();
							if text == "refused" {
								if retained {
									host.tell(&inbox, "receiptRejected", &args[2..3]).unwrap();
								}
								return Err("post refused before echo".into());
							}
							sequence.set(sequence.get() + 1);
							if retained {
								host.tell(
									&inbox,
									"receipt",
									&[
										args[2].clone(),
										Argument::Integer(sequence.get() as i64),
										"alice".into(),
										Argument::Boolean(false),
										Argument::Boolean(false),
									],
								)
								.unwrap();
							} else {
								host.tell(
									&inbox,
									"notify",
									&[
										"alice".into(),
										text.clone().into(),
										"line".into(),
										Argument::Integer(sequence.get() as i64),
									],
								)
								.unwrap();
							}
							let edits = edits.clone();
							Ok(host
								.spawn_owned(move |verb, _| match verb {
									"edit" => {
										edits.borrow_mut().push(text.clone());
										Ok(Argument::Void)
									}
									_ => Err("unknown line method".into()),
								})
								.unwrap()
								.into())
						}
						"leave" => Ok(Argument::Void),
						_ => Err("unknown membership method".into()),
					})
					.unwrap();
				Ok(Argument::List(vec![
					seat.into(),
					"participant".into(),
					Argument::Void,
					Argument::Void,
				]))
			}
			"roomPolicy" => Ok(Argument::List(vec!["listed".into(), "open".into(), "open".into()])),
			_ => Err("unknown room method".into()),
		})
		.unwrap()
}
