//! An operator who is also a member closes or forgets the room over the one
//! connection both hold: the member hears why and the room is gone from the
//! inventories.
use super::*;
use rooms_testing::scratch::Scratch;

#[tokio::test]
async fn rooms_server_operator_close_reaches_a_member_on_the_operators_own_connection() {
	rooms_testing::local_set::run_within(Duration::from_secs(60), removed(false)).await;
}

#[tokio::test]
async fn rooms_server_operator_forget_removes_a_live_room_and_its_member_hears_why() {
	rooms_testing::local_set::run_within(Duration::from_secs(60), removed(true)).await;
}

/// `forget` names the room instead of removing it by its id.
async fn removed(forget: bool) {
	use rooms_glowcap::client::{
		Client,
		directory::Directory,
		room::{Event, Room, SubscribeOptions},
	};
	use std::{cell::RefCell, rc::Rc};
	let temp = Scratch::create("server");
	let running = start_with(temp.to_path_buf(), tcp(), Asked::parse("operator").unwrap()).await;
	let swiss = running.capabilities[0].swiss.clone();
	let runtime = runtime().await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	let session = runtime.connect(&dial, ConnectOptions::default()).await.unwrap();
	let op = session.fetch(&swiss).await.unwrap();

	let client = Client::new(session.borrowed(), rooms_platform::HostPlatform);
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let heard = Rc::new(RefCell::new(Vec::<String>::new()));
	let noted = heard.clone();
	let (room, mut messages) = Room::subscribe(
		client,
		directory.open("garden").await.unwrap(),
		"alice",
		SubscribeOptions {
			voucher: None,
			on_event: Box::new(move |event| {
				if let Event::Ended(reason) = event {
					noted.borrow_mut().push(reason.to_string());
				}
			}),
		},
	)
	.await
	.unwrap();
	tokio::time::timeout(Duration::from_secs(5), messages.next())
		.await
		.expect("the roster in time")
		.expect("the room stayed open")
		.expect("the roster line");

	let (_, pages) = whole(&session.send(&op, "operatorSnapshot", &[]).await.unwrap());
	assert_eq!(pages["stewardships"].2, 1, "a live room is listed with its links");
	if forget {
		session
			.send(&op, "forgetRoom", &[Argument::String("Garden".into())])
			.await
			.unwrap();
	} else {
		let id = text(&pages["rooms"].1[0], 0).to_string();
		session
			.send(&op, "removeOperatorRoom", &[Argument::String(id)])
			.await
			.unwrap();
	}
	tokio::time::timeout(Duration::from_secs(5), async {
		while heard.borrow().is_empty() {
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("the operator-member heard the room end");
	assert_eq!(*heard.borrow(), ["room-retired: An operator removed this room."]);
	drop(room);
	let (_, pages) = whole(&session.send(&op, "operatorSnapshot", &[]).await.unwrap());
	assert_eq!((pages["rooms"].2, pages["stewardships"].2), (0, 0));
}
