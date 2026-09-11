//! Rooms under real CapTP with the Rust room client: opening, entering,
//! presence, lines and their edits, history, topics, files, invitations,
//! managed rooms with their managers and stewards, durable links redeemed
//! from a fresh connection, and the same links and history after a restart.
use super::{closing_tolerated, runtime, start, tcp, Temp};
use crate::client::Deadline;
use glowcap::{ConnectOptions, PendingWork};
use rooms_application::{
	directory::creation::RecoveryKey,
	files::FileDescription,
	room::{
		inbox::{metadata::Presence, Message},
		message::ChangeKind,
		policy::{MembershipKind, RoomPolicy},
	},
	session::checkpoint::commands::CommandRoutes,
};
use rooms_glowcap::client::{
	directory::Directory,
	invitation::Invitation,
	room::{Event, Messages, Room, SubscribeOptions},
	Client,
};
use std::{cell::RefCell, rc::Rc, time::Duration};

type Line = Message<String, glowcap::Ref>;

async fn next(messages: &mut Messages) -> Line {
	tokio::time::timeout(Duration::from_secs(5), messages.next())
		.await
		.expect("a room line in time")
		.expect("the room stayed open")
		.expect("a line")
}

/// The next line that is a member's or the room's own words, skipping
/// presence and facts.
async fn next_said(messages: &mut Messages) -> Line {
	loop {
		let line = next(messages).await;
		if line.presence.is_none() && line.facts.is_none() {
			return line;
		}
	}
}

async fn next_presence(messages: &mut Messages) -> Presence<String> {
	loop {
		let line = next(messages).await;
		if let Some(presence) = line.presence {
			return presence;
		}
	}
}

fn events() -> (Rc<RefCell<Vec<String>>>, SubscribeOptions) {
	let seen = Rc::new(RefCell::new(Vec::new()));
	let held = seen.clone();
	let options = SubscribeOptions {
		voucher: None,
		on_event: Box::new(move |event| {
			held.borrow_mut().push(match event {
				Event::Typing { name, on } => format!("typing {name} {on}"),
				Event::Authority { kind, token, .. } => format!("authority {kind:?} {token}"),
				Event::Policy(policy) => format!("policy {:?}", policy),
				Event::Ended(reason) => format!("ended {reason}"),
			})
		}),
	};
	(seen, options)
}

/// Subscribe and drain the arrival through its roster, which is the last
/// presence an arrival hears about itself; the names are answered.
async fn join(
	client: &Client<Deadline>,
	room: glowcap::Ref,
	nick: &str,
) -> (Room<Deadline>, Messages, Rc<RefCell<Vec<String>>>, Vec<String>) {
	let (seen, options) = events();
	let (room, mut messages) = Room::subscribe(client.clone(), room, nick, options).await.unwrap();
	let names = loop {
		if let Presence::Roster { names } = next_presence(&mut messages).await {
			break names;
		}
	};
	(room, messages, seen, names)
}

#[tokio::test]
async fn room_server_hosts_rooms_lines_files_invitations_and_links_over_tcp() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(60), rooms())
				.await
				.expect("native room server deadline");
		})
		.await;
}

async fn rooms() {
	let temp = Temp::new();
	let running = start(temp.0.clone(), tcp()).await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	let alice_runtime = runtime().await;
	let bob_runtime = runtime().await;
	let alice = Client::new(
		alice_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		Deadline,
	);
	let bob = Client::new(
		bob_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		Deadline,
	);
	let alice_dir = Directory::fetch(alice.clone()).await.unwrap();
	let bob_dir = Directory::fetch(bob.clone()).await.unwrap();

	// Opening and entering: the room is listed once occupied, and both
	// members hear the arrival.
	let garden = alice_dir.open("Garden").await.unwrap();
	let (alice_room, mut alice_lines, alice_seen, roster) = join(&alice, garden, "Alice").await;
	assert_eq!(roster, ["Alice"]);
	assert_eq!(alice_room.listed(), Some(true));
	assert_eq!(alice_room.kind().unwrap(), MembershipKind::Participant);
	let listed = bob_dir.list().await.unwrap();
	assert_eq!(listed.len(), 1);
	assert_eq!(listed[0].name.text().as_str(), Some("Garden"));
	assert_eq!(listed[0].count.as_ref().unwrap().get(), 1);
	let entered = bob_dir.enter("garden").await.unwrap();
	assert_eq!(bob.room_called(&entered).await.unwrap(), "Garden");
	let (bob_room, mut bob_lines, bob_seen, roster) = join(&bob, entered, "Bob").await;
	assert_eq!(roster, ["Alice", "Bob"]);
	assert!(matches!(next_presence(&mut alice_lines).await, Presence::Join { name } if name == "Bob"));

	// A line said, heard, edited, and kept.
	let posted = alice_room.say("hello").await.unwrap().expect("a line capability");
	let heard = next_said(&mut bob_lines).await;
	assert_eq!((heard.from.as_str(), heard.text.as_str()), ("Alice", "hello"));
	assert!(matches!(heard.marker, Some(marker) if marker.kind == ChangeKind::Said && marker.id.get() == 1));
	next_said(&mut alice_lines).await;
	posted.edit("hi there").await.unwrap();
	let edited = next_said(&mut bob_lines).await;
	assert_eq!(edited.text, "hi there");
	assert!(matches!(edited.marker, Some(marker) if marker.kind == ChangeKind::Edited));
	next_said(&mut alice_lines).await;
	let kept = bob_room.history().await.unwrap();
	assert_eq!(kept.len(), 1);
	assert_eq!((kept[0].from.as_str(), kept[0].text.as_str()), ("Alice", "hi there"));

	// Typing, away, and the topic are the room's own word.
	alice_room.typing(true).unwrap();
	alice_room.away("lunch").await.unwrap();
	assert!(matches!(
		next_presence(&mut bob_lines).await,
		Presence::Away { name, reason } if name == "Alice" && reason == "lunch"
	));
	assert_eq!(bob_seen.borrow().as_slice(), ["typing Alice true"]);
	assert!(alice_seen.borrow().is_empty(), "the typer is not told");
	alice_room.set_topic("seeds").await.unwrap();
	let topic = next(&mut bob_lines).await;
	assert_eq!(topic.facts.and_then(|facts| facts.topic).as_deref(), Some("seeds"));
	let carol_runtime = runtime().await;
	let carol = Client::new(
		carol_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		Deadline,
	);
	let carol_dir = Directory::fetch(carol.clone()).await.unwrap();
	let (carol_room, mut carol_lines, _, roster) =
		join(&carol, carol_dir.enter("Garden").await.unwrap(), "Carol").await;
	assert_eq!(roster.len(), 3);
	// Who is already away and what the room is about follow the roster.
	let mut arrival = Vec::new();
	for _ in 0..2 {
		arrival.push(next(&mut carol_lines).await);
	}
	assert!(arrival
		.iter()
		.any(|line| matches!(&line.presence, Some(Presence::Away { name, .. }) if name == "Alice")));
	assert!(arrival
		.iter()
		.any(|line| line.facts.as_ref().and_then(|f| f.topic.as_deref()) == Some("seeds")));
	next_presence(&mut alice_lines).await;
	next_presence(&mut bob_lines).await;

	// A file is admitted, posted, filled, and read by another member.
	let description = FileDescription::parse("pic.png", "image/png", 5, 2, 2).unwrap();
	let mut upload = alice_room.stage(description).await.unwrap();
	alice_room.post_files("").await.unwrap();
	upload.write(vec![1, 2, 3, 4, 5]).await.unwrap();
	assert!(upload.complete());
	let with_file = next_said(&mut bob_lines).await;
	assert_eq!(with_file.text, "pic.png");
	assert_eq!(with_file.attachments.len(), 1);
	let attachment = with_file.attachments.into_iter().next().unwrap();
	assert_eq!(attachment.description.name(), "pic.png");
	let bytes = bob_room.file(attachment).fetch(|_| {}).await.unwrap();
	assert_eq!(bytes, [1, 2, 3, 4, 5]);
	next_said(&mut alice_lines).await;
	next_said(&mut carol_lines).await;

	// A private room admits by invitation, and the invited seat's kind is the
	// inviter's choice.
	let key = RecoveryKey::from_entropy([7; 16]);
	let secret = alice_dir.open_private("Secret", &key).await.unwrap();
	assert!(
		bob_dir.enter("Secret").await.is_err(),
		"a private room is not entered by name"
	);
	let (secret_room, _secret_lines, _, _) = join(&alice, secret, "Alice").await;
	assert_eq!(secret_room.listed(), Some(false));
	// An invitation is a capability the inviter hands on; claimed here on the
	// inviter's own connection, it re-seats them under the invited kind. The
	// gift to another member rides a direct message, which the session
	// peer's handed-rooms tests drive against this server.
	let invitation = secret_room.invite(MembershipKind::Observer).await.unwrap();
	let claimant = Invitation::new(alice.clone(), invitation.reference().clone()).unwrap();
	let entrance = claimant.claim().await.unwrap();
	let (observer, _observer_lines, _, _) = join(&alice, entrance, "Alice").await;
	assert_eq!(observer.kind().unwrap(), MembershipKind::Observer);
	let refused = match observer.say("shh").await {
		Err(refused) => refused,
		Ok(_) => panic!("an observer spoke"),
	};
	assert!(refused.to_string().contains("read-only-membership"), "{refused}");
	assert!(claimant.claim().await.is_ok(), "the same receipt claims again");
	let bob_secret = observer;

	// A managed room: its bootstrap mints the manager, the manager gives a
	// steward, the steward asks a member out, and a policy change relists
	// the room under a new name.
	let managed_key = RecoveryKey::from_entropy([9; 16]);
	let yard = alice_dir
		.open_managed("Yard", RoomPolicy::Moderated, &managed_key)
		.await
		.unwrap();
	let (alice_yard, mut alice_yard_lines, alice_yard_seen, _) = join(&alice, yard.room, "Alice").await;
	alice_yard.stewardship().take_manager(&yard.manager_link).await.unwrap();
	assert!(alice_yard.stewardship().claim().await.unwrap());
	let (bob_yard, mut bob_yard_lines, bob_yard_seen, _) =
		join(&bob, bob_dir.enter("yard").await.unwrap(), "Bob").await;
	assert_eq!(bob_yard.kind().unwrap(), MembershipKind::Observer);
	next_presence(&mut alice_yard_lines).await;
	alice_yard.stewardship().kick("bob").await.unwrap();
	tokio::time::timeout(Duration::from_secs(5), async {
		while !bob_yard_seen.borrow().iter().any(|seen| seen.starts_with("ended")) {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("Bob is told he was asked to leave");
	assert_eq!(
		bob_yard.ended_reason().as_deref(),
		Some("You were asked to leave #Yard.")
	);
	assert!(matches!(next_presence(&mut alice_yard_lines).await, Presence::Leave { name } if name == "Bob"));
	let _ = &mut bob_yard_lines;
	let update = alice_yard
		.stewardship()
		.set_policy(RoomPolicy::Open, "Lawn")
		.await
		.unwrap();
	assert_eq!((update.name.as_str(), update.policy), ("Lawn", RoomPolicy::Open));
	tokio::time::timeout(Duration::from_secs(5), async {
		while !alice_yard_seen.borrow().iter().any(|seen| seen.starts_with("policy")) {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("the member hears the policy change");
	assert!(bob_dir.enter("Yard").await.is_err(), "the old name is gone");
	let lawn = bob_dir.enter("Lawn").await.unwrap();
	assert_eq!(bob.room_policy(&lawn).await.unwrap(), RoomPolicy::Open);

	// The room link redeems from a fresh connection, the durable entrance.
	let links = alice_yard.stewardship().links();
	let room_link = links.room.clone().expect("a room link");
	let dave_runtime = runtime().await;
	let dave = Client::new(
		dave_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		Deadline,
	);
	let redeemed = dave.enliven(&room_link).await.unwrap();
	assert_eq!(dave.room_called(&redeemed).await.unwrap(), "Lawn");
	let (dave_room, _dave_lines, _, _) = join(&dave, redeemed, "Dave").await;
	assert_eq!(dave_room.kind().unwrap(), MembershipKind::Participant);
	// Revoking the steward ends its capability and tells the members.
	let steward_token = rooms_glowcap::routes::CheckpointRoutes
		.authority_token(links.steward.as_deref().unwrap())
		.unwrap();
	alice_yard.stewardship().revoke_steward(&steward_token).await.unwrap();
	tokio::time::timeout(Duration::from_secs(5), async {
		while !alice_yard_seen.borrow().iter().any(|seen| seen.contains("Steward")) {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("the member hears the steward end");
	assert!(alice_yard.stewardship().kick("dave").await.is_err());

	// Leaving is announced; the last member out closes the room.
	bob_room.leave().await.unwrap();
	assert!(matches!(next_presence(&mut alice_lines).await, Presence::Leave { name } if name == "Bob"));
	carol_room.leave().await.unwrap();
	next_presence(&mut alice_lines).await;
	drop((
		bob_secret,
		secret_room,
		alice_yard,
		dave_room,
		bob_yard,
		carol_room,
		alice_room,
	));
	drop((alice_dir, bob_dir, carol_dir));
	for client in [&alice, &bob, &carol, &dave] {
		closing_tolerated(client.session().close(PendingWork::Cancel).await);
	}
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());
	for runtime in [alice_runtime, bob_runtime, carol_runtime, dave_runtime] {
		runtime.close(PendingWork::Cancel).await.unwrap();
	}

	// After a restart the link still answers, and the kept line is still
	// there for whoever enters the room next.
	let running = start(temp.0.clone(), tcp()).await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	let runtime = runtime().await;
	let client = Client::new(
		runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		Deadline,
	);
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let again = glowcap::parse_sturdyref(&room_link, glowcap::CaptpVersion::V1_0).unwrap();
	let relinked = glowcap::format_sturdyref(&dial, &again.swissnum, glowcap::CaptpVersion::V1_0).unwrap();
	let redeemed = client.enliven(&relinked).await.unwrap();
	assert_eq!(client.room_called(&redeemed).await.unwrap(), "Lawn");
	let garden = directory.open("Garden").await.unwrap();
	let (room, _lines, _, _) = join(&client, garden, "Erin").await;
	let kept = room.history().await.unwrap();
	assert_eq!(kept.len(), 2, "the text line and the file caption");
	assert_eq!(kept[0].text, "hi there");
	// History is kept under the room's key, the file name the TypeScript
	// server writes for the same room.
	assert!(std::fs::read_to_string(temp.0.join("history").join("%23garden.jsonl"))
		.unwrap()
		.contains("\"hi there\""));
	drop((room, directory));
	closing_tolerated(client.session().close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
}
