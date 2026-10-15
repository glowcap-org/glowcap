//! The production directory authorizes one exact publication across connections.
use super::*;
use glowcap::{Argument, Ref};
use rooms_application::directory::creation::SUBSCRIBE_PUBLICATION;

async fn named(directory: &Directory<HostPlatform>, name: &str) -> Vec<rooms_application::directory::RoomInfo> {
	let reply = directory
		.client()
		.session()
		.send(
			directory.reference(),
			rooms_application::directory::NAMED,
			&[name.into()],
		)
		.await
		.unwrap();
	rooms_application::directory::rooms(&rooms_glowcap::Value(&reply)).unwrap()
}

#[tokio::test]
async fn named_managed_publication_reopens_without_members_and_fences_policy_replacement() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), dormant())
				.await
				.expect("dormant public membership deadline");
		})
		.await;
}
async fn dormant() {
	let temp = Temp::new();
	let running = super::super::start_with(
		temp.0.clone(),
		tcp(),
		crate::server::Asked {
			operator: true,
			..Default::default()
		},
	)
	.await;
	let locator = glowcap::parse_locator(&running.location).unwrap();
	let peer = runtime().await;
	let client = Client::new(
		peer.connect(&locator, ConnectOptions::default()).await.unwrap(),
		HostPlatform,
	);
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let (linked, _, _, _) = join(&client, directory.open("Orchard").await.unwrap(), "Keeper").await;
	let operator = client.session().fetch(&running.capabilities[0].swiss).await.unwrap();
	client
		.session()
		.send(&operator, "giveSteward", &["Orchard".into()])
		.await
		.unwrap();
	let ordinary = named(&directory, "ORCHARD").await.remove(0);
	let ordinary_id = ordinary.id.text().as_str().unwrap().to_owned();
	linked.leave().await.unwrap();
	assert_eq!(named(&directory, "Orchard").await[0].id, ordinary.id);
	let (linked, _, _, _) = join(
		&client,
		directory.enter_publication(&ordinary_id).await.unwrap(),
		"Reader",
	)
	.await;
	assert_eq!(linked.kind().unwrap(), MembershipKind::Participant);
	linked.leave().await.unwrap();
	let managed = directory
		.open_managed("Quiet", RoomPolicy::Moderated, &RecoveryKey::from_entropy([12; 16]))
		.await
		.unwrap();
	assert!(
		directory.list(None).await.unwrap().rooms.is_empty(),
		"no occupancy before subscription"
	);
	let entry = named(&directory, "QUIET").await.remove(0);
	let publication = entry.id.text().as_str().unwrap().to_owned();
	assert_eq!(
		entry.offers,
		rooms_application::fields::Nullable::Value(MembershipKind::Observer)
	);
	let inbox = client.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
	let result = client
		.session()
		.send(
			directory.reference(),
			SUBSCRIBE_PUBLICATION,
			&[publication.clone().into(), "Reader".into(), inbox.into()],
		)
		.await
		.unwrap();
	let seat = Ref::try_from(&result.as_list().unwrap()[0]).unwrap();
	assert_eq!(
		client
			.session()
			.send(&seat, "membershipKind", &[])
			.await
			.unwrap()
			.as_str(),
		Some("observer")
	);
	client.session().send(&seat, "leave", &[]).await.unwrap();
	assert!(directory.list(None).await.unwrap().rooms.is_empty());
	assert_eq!(named(&directory, "Quiet").await[0].id, entry.id);
	let manager = managed.manager_link;
	closing_tolerated(peer.close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	let running = start(temp.0.clone(), tcp()).await;
	let peer = runtime().await;
	let locator = glowcap::parse_locator(&running.location).unwrap();
	let saved = glowcap::parse_sturdyref(&manager, glowcap::CaptpVersion::V1_0).unwrap();
	let manager = glowcap::format_sturdyref(&locator, &saved.swissnum, glowcap::CaptpVersion::V1_0).unwrap();
	let client = Client::new(
		peer.connect(&locator, ConnectOptions::default()).await.unwrap(),
		HostPlatform,
	);
	let directory = Directory::fetch(client.clone()).await.unwrap();
	assert_eq!(named(&directory, "Orchard").await[0].id, ordinary.id);
	let (linked, _, _, _) = join(
		&client,
		directory.enter_publication(&ordinary_id).await.unwrap(),
		"Reader",
	)
	.await;
	linked.leave().await.unwrap();
	assert_eq!(named(&directory, "Quiet").await[0].id, entry.id);
	let (room, _lines, _, _) = join(
		&client,
		directory.enter_publication(&publication).await.unwrap(),
		"Reader",
	)
	.await;
	assert_eq!(room.kind().unwrap(), MembershipKind::Observer);
	room.stewardship().take_manager(&manager).await.unwrap();
	room.stewardship().set_policy(RoomPolicy::Open, "Quiet").await.unwrap();
	assert!(directory.enter_publication(&publication).await.is_err());
	let successor = named(&directory, "Quiet").await.remove(0);
	assert_ne!(successor.id, entry.id);
	assert_eq!(
		successor.offers,
		rooms_application::fields::Nullable::Value(MembershipKind::Participant)
	);
	room.stewardship()
		.set_policy(RoomPolicy::Private, "Quiet")
		.await
		.unwrap();
	assert!(named(&directory, "Quiet").await.is_empty());
	assert!(
		directory
			.enter_publication(successor.id.text().as_str().unwrap())
			.await
			.is_err()
	);
	closing_tolerated(peer.close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
}

#[tokio::test]
async fn public_membership_reopens_exact_publication_and_refuses_same_name_replacement() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), journey())
				.await
				.expect("public membership deadline");
		})
		.await;
}
async fn journey() {
	let temp = Temp::new();
	let running = start(temp.0.clone(), tcp()).await;
	let locator = glowcap::parse_locator(&running.location).unwrap();
	let alice_runtime = runtime().await;
	let alice = Client::new(
		alice_runtime
			.connect(&locator, ConnectOptions::default())
			.await
			.unwrap(),
		HostPlatform,
	);
	let directory = Directory::fetch(alice.clone()).await.unwrap();
	let entrance = directory.open("Public recovery").await.unwrap();
	let (alice_room, _lines, _, _) = join(&alice, entrance, "Alice").await;
	let publication = directory
		.list(None)
		.await
		.unwrap()
		.rooms
		.remove(0)
		.id
		.text()
		.as_str()
		.unwrap()
		.to_owned();
	// A fresh connection uses the original directory/publication witness; no
	// accepted visit or room capability survives between these connections.
	for _ in 0..2 {
		let reader_runtime = runtime().await;
		let reader = Client::new(
			reader_runtime
				.connect(&locator, ConnectOptions::default())
				.await
				.unwrap(),
			HostPlatform,
		);
		let directory = Directory::fetch(reader.clone()).await.unwrap();
		let inbox = reader.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
		let result = reader
			.session()
			.send(
				directory.reference(),
				SUBSCRIBE_PUBLICATION,
				&[publication.clone().into(), "Reader".into(), inbox.into()],
			)
			.await
			.unwrap();
		let seat = Ref::try_from(&result.as_list().unwrap()[0]).unwrap();
		reader.session().send(&seat, "membershipKind", &[]).await.unwrap();
		reader.session().send(&seat, "leave", &[]).await.unwrap();
		closing_tolerated(reader_runtime.close(PendingWork::Cancel).await);
	}
	alice_room.leave().await.unwrap();
	assert!(directory.list(None).await.unwrap().rooms.is_empty());
	let replacement = directory.open("Public recovery").await.unwrap();
	let (replacement_room, _replacement_lines, _, _) = join(&alice, replacement, "Alice").await;
	let current = directory
		.list(None)
		.await
		.unwrap()
		.rooms
		.remove(0)
		.id
		.text()
		.as_str()
		.unwrap()
		.to_owned();
	assert_ne!(publication, current);
	let inbox = alice.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
	let old = alice
		.session()
		.send(
			directory.reference(),
			SUBSCRIBE_PUBLICATION,
			&[publication.into(), "Reader".into(), inbox.clone().into()],
		)
		.await;
	assert!(
		old.is_err(),
		"a replaced public generation must not be found by its display name"
	);
	let selected = alice
		.session()
		.send(
			directory.reference(),
			SUBSCRIBE_PUBLICATION,
			&[current.into(), "Reader".into(), inbox.into()],
		)
		.await
		.unwrap();
	let seat = Ref::try_from(&selected.as_list().unwrap()[0]).unwrap();
	alice.session().send(&seat, "leave", &[]).await.unwrap();
	// The raw subscription replaced this connection's previous membership.
	assert!(replacement_room.say("retired seat").await.is_err());
	closing_tolerated(alice_runtime.close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
}
