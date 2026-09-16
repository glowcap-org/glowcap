//! The peering capability under real CapTP: a room held at one server and
//! published at another under a name, listed as foreign and entered as the
//! source's own capability, taken down by its lease, and taken down with
//! its publisher's session.
use super::*;

#[tokio::test]
async fn rooms_server_lists_a_room_another_directory_publishes_until_its_lease_revokes() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(60), peering())
				.await
				.expect("peering scenario deadline");
		})
		.await;
}

/// One phase of a scenario under its own deadline, so a hang names itself.
async fn within<T>(what: &'static str, phase: impl std::future::IntoFuture<Output = T>) -> T {
	tokio::time::timeout(Duration::from_secs(40), phase.into_future())
		.await
		.unwrap_or_else(|_| panic!("{what} did not finish in time"))
}

async fn peering() {
	use rooms_glowcap::client::{
		Client,
		directory::Directory,
		room::{Room, SubscribeOptions},
	};
	let (source_state, destination_state) = (Temp::new(), Temp::new());
	let source = start_with(source_state.0.clone(), tcp(), Asked::default()).await;
	let destination = start_with(
		destination_state.0.clone(),
		tcp(),
		Asked {
			peering: true,
			..Default::default()
		},
	)
	.await;
	let swiss = destination.capabilities[0].swiss.clone();
	let source_dial = glowcap::parse_locator(&source.location).unwrap();
	let destination_dial = glowcap::parse_locator(&destination.location).unwrap();

	// The publisher holds a room at the source and hands it to the
	// destination under a name.
	let publisher = super::runtime().await;
	let at_source = publisher
		.connect(&source_dial, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let source_directory = at_source.fetch("directory").await.unwrap();
	let garden = at_source
		.send(&source_directory, "open", &[Argument::String("garden".into())])
		.await
		.unwrap();
	let Argument::Reference(garden) = garden else {
		panic!("a room, not {garden:?}");
	};
	let at_destination = publisher
		.connect(&destination_dial, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let peering = at_destination.fetch(&swiss).await.unwrap();
	assert!(
		refused(
			&at_destination,
			&peering,
			"publishDurableRoom",
			&[Argument::String("garden".into())]
		)
		.await
		.contains("needs a name of at most 32 characters")
	);
	assert!(
		refused(&at_destination, &peering, "nope", &[])
			.await
			.contains("directory peering has no method nope")
	);
	let lease = within(
		"publishing",
		at_destination.send(
			&peering,
			"publishDurableRoom",
			&[Argument::String("garden".into()), Argument::Reference(garden.clone())],
		),
	)
	.await
	.unwrap();
	let Argument::Reference(lease) = lease else {
		panic!("a lease, not {lease:?}");
	};
	let ready = within("the lease becoming ready", at_destination.send(&lease, "ready", &[])).await;
	if let Err(reason) = &ready {
		panic!(
			"the lease never became ready: {reason}; the destination said {:?}; the source said {:?}",
			destination.notices.borrow(),
			source.notices.borrow()
		);
	}
	assert_eq!(ready.unwrap(), Argument::Void);
	assert!(
		refused(&at_destination, &lease, "ready", &[Argument::Integer(1)])
			.await
			.contains("ready takes no arguments")
	);
	// The name is taken at the destination now, for a publication and for
	// a local room alike; the link stays with the source.
	let again = at_destination
		.send(
			&peering,
			"publishDurableRoom",
			&[Argument::String("Garden".into()), Argument::Reference(garden.clone())],
		)
		.await;
	assert!(again.unwrap_err().to_string().contains("room-exists"));
	let destination_directory = at_destination.fetch("directory").await.unwrap();
	assert!(
		refused(
			&at_destination,
			&destination_directory,
			"open",
			&[Argument::String("garden".into())],
		)
		.await
		.contains("room-exists")
	);
	assert!(
		refused(
			&at_destination,
			&destination_directory,
			"link",
			&[Argument::String("garden".into())],
		)
		.await
		.contains("linked by its source directory")
	);

	// A visitor at the destination lists the room as foreign and enters the
	// source's own capability through it.
	let visitor = super::runtime().await;
	let visiting = visitor
		.connect(&destination_dial, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let client = Client::new(visiting.borrowed(), rooms_platform::HostPlatform);
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let listed = directory.list().await.unwrap();
	assert_eq!(listed.len(), 1);
	assert_eq!(listed[0].kind, rooms_application::directory::PublicationKind::Foreign);
	assert_eq!(listed[0].proof, rooms_application::directory::OriginProof::Session);
	assert!(matches!(listed[0].count, rooms_application::fields::Nullable::Null));
	let entered = within("entering the foreign room", directory.enter("garden"))
		.await
		.unwrap();
	let (room, mut messages) = within(
		"subscribing through the foreign room",
		Room::subscribe(
			client.clone(),
			entered,
			"visitor",
			SubscribeOptions {
				voucher: None,
				on_event: Box::new(|_| {}),
			},
		),
	)
	.await
	.unwrap();
	// The room states what it carries ahead of the roster, so the roster is
	// the first line with presence rather than the first line.
	let roster = tokio::time::timeout(Duration::from_secs(5), async {
		loop {
			let line = messages.next().await.unwrap().unwrap();
			if line.presence().is_some() {
				break line;
			}
		}
	})
	.await
	.expect("the roster in time");
	assert!(roster.presence().is_some());
	room.say("hello from the destination").await.unwrap();
	let said = tokio::time::timeout(Duration::from_secs(5), async {
		loop {
			let line = messages.next().await.unwrap().unwrap();
			if line.text.contains("hello from the destination") {
				break line;
			}
		}
	})
	.await
	.expect("the line came back through the source's room");
	assert_eq!(said.from, "visitor");

	// Revoking the lease removes the listing; the room already handed out
	// keeps working.
	assert_eq!(
		at_destination.send(&lease, "revoke", &[]).await.unwrap(),
		Argument::Void
	);
	assert!(directory.list().await.unwrap().is_empty());
	assert!(directory.enter("garden").await.is_err());
	room.say("still here").await.unwrap();
	drop(room);

	// Published again, the listing goes with the publisher's session.
	let lease = at_destination
		.send(
			&peering,
			"publishDurableRoom",
			&[Argument::String("garden".into()), Argument::Reference(garden.clone())],
		)
		.await
		.unwrap();
	assert!(matches!(lease, Argument::Reference(_)));
	let Argument::Reference(lease) = lease else {
		unreachable!()
	};
	within(
		"the second lease becoming ready",
		at_destination.send(&lease, "ready", &[]),
	)
	.await
	.unwrap();
	assert_eq!(directory.list().await.unwrap().len(), 1);
	within("the publisher leaving", at_destination.close(PendingWork::Cancel))
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(5), async {
		while !directory.list().await.unwrap().is_empty() {
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("the publisher leaving took its listing");

	within("the visitor leaving", visiting.close(PendingWork::Cancel))
		.await
		.unwrap();
	within("the source session closing", at_source.close(PendingWork::Cancel))
		.await
		.unwrap();
	for running in [source, destination] {
		running.stop.send(()).unwrap();
		within("a server stopping", running.task).await.unwrap().unwrap();
	}
	within("the publisher runtime closing", publisher.close(PendingWork::Cancel))
		.await
		.unwrap();
	within("the visitor runtime closing", visitor.close(PendingWork::Cancel))
		.await
		.unwrap();
}
