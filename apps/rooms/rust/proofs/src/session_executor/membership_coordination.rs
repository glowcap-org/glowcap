//! Shared source sequencing and field aliases survive aggregate reconciliation.
use super::*;
use rooms_glowcap::client::workspace::Workspace;

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	platform: &Platform,
	joins: &Cell<usize>,
) {
	let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
	let mut intent = workspace.snapshot().await.unwrap().intent;
	let session::workspace::Conversation::Room(first) = &intent.conversations.as_slice()[0] else {
		unreachable!()
	};
	let mut second = first.clone();
	second.id = rooms_application::fields::Text::new("second".into()).unwrap();
	second.name = rooms_application::fields::Text::new("second".into()).unwrap();
	// Both rows initially alias the same seat, subject, files and closed inbox.
	// Replacing the first row must preserve the second row's exact custody.
	intent
		.conversations
		.try_push(session::workspace::Conversation::Room(second))
		.unwrap();
	owner.replace_workspace(&intent).await.unwrap();
	let prior = joins.get();
	let mut memberships = managed::Memberships::default();
	let mut entropy = realization::Entropy::seeded(200);
	let received = Rc::new(Cell::new(0));
	let report = memberships
		.reconcile(owner, &intent, "ocapn://member.id", &mut entropy, |_| {
			let received = received.clone();
			Box::new(move |_| {
				received.set(received.get() + 1);
				Ok(Argument::Void)
			})
		})
		.await;
	assert!(report.failures.is_empty(), "coordinated startup: {:?}", report.failures);
	assert_eq!(report.ready, 2);
	assert_eq!(joins.get(), prior + 2);
	let installed = workspace.snapshot().await.unwrap().intent;
	let mut callbacks = room_callbacks(owner, &installed).await;
	for callback in &callbacks {
		host.send(callback, "notify", &[]).await.unwrap();
	}
	assert_eq!(received.get(), 2);
	let report = memberships
		.reconcile(owner, &installed, "ocapn://member.id", &mut entropy, |_| {
			panic!("a live row cannot create another receiver")
		})
		.await;
	assert!(report.failures.is_empty());
	assert_eq!(report.ready, 2);
	assert_eq!(joins.get(), prior + 2, "unchanged intent sends no subscription");
	let mut requested = installed;
	let directory = &mut requested.directories.as_mut_slice()[0];
	directory.assigned_nick = Some(rooms_application::fields::Text::new("member".into()).unwrap());
	directory.nick = rooms_application::fields::Text::new("requested".into()).unwrap();
	owner.replace_workspace(&requested).await.unwrap();
	for callback in &callbacks {
		host.send(callback, "notify", &[]).await.unwrap();
	}
	let report = memberships
		.reconcile(owner, &requested, "ocapn://member.id", &mut entropy, |_| {
			panic!("a pending nickname request cannot replace the current room identity")
		})
		.await;
	assert!(report.failures.is_empty());
	assert_eq!(joins.get(), prior + 2);
	let mut assigned = requested;
	assigned.directories.as_mut_slice()[0].assigned_nick =
		Some(rooms_application::fields::Text::new("assigned".into()).unwrap());
	owner.replace_workspace(&assigned).await.unwrap();
	for callback in &callbacks {
		assert!(
			host.send(callback, "notify", &[]).await.is_err(),
			"assignment fences old room callbacks before reconciliation"
		);
	}
	let report = memberships
		.reconcile(owner, &assigned, "ocapn://member.id", &mut entropy, |_| {
			let received = received.clone();
			Box::new(move |_| {
				received.set(received.get() + 1);
				Ok(Argument::Void)
			})
		})
		.await;
	assert!(
		report.failures.is_empty(),
		"reassigned membership: {:?}",
		report.failures
	);
	assert_eq!(report.ready, 2);
	assert_eq!(
		joins.get(),
		prior + 4,
		"each room subscribes once with the assigned identity"
	);
	let directory_access = owner
		.restore_custody(&[requests::coordinate(custody::Role::DirectoryAccess, 1)])
		.await
		.unwrap()
		.remove(0);
	assert_eq!(
		host.send(&directory_access, "last-nickname", &[])
			.await
			.unwrap()
			.as_str(),
		Some("assigned")
	);
	let installed = workspace.snapshot().await.unwrap().intent;
	callbacks = room_callbacks(owner, &installed).await;
	let registration = requests::coordinate(custody::Role::DirectoryName, 97);
	owner.import(registration, directory_access, None).await.unwrap();
	let mut reregistered = installed;
	reregistered.directories.as_mut_slice()[0].name = Some(custody::FieldKey::new(
		registration.key.slot(),
		registration.key.generation(),
	));
	owner.replace_workspace(&reregistered).await.unwrap();
	for callback in &callbacks {
		assert!(
			host.send(callback, "notify", &[]).await.is_err(),
			"registration replacement fences the old seat even when its nickname is unchanged"
		);
	}
	let report = memberships
		.reconcile(owner, &reregistered, "ocapn://member.id", &mut entropy, |_| {
			let received = received.clone();
			Box::new(move |_| {
				received.set(received.get() + 1);
				Ok(Argument::Void)
			})
		})
		.await;
	assert!(
		report.failures.is_empty(),
		"reregistered membership: {:?}",
		report.failures
	);
	assert_eq!(report.ready, 2);
	assert_eq!(joins.get(), prior + 6);
	let installed = workspace.snapshot().await.unwrap().intent;
	callbacks = room_callbacks(owner, &installed).await;
	let mut departed = installed;
	let session::workspace::Conversation::Room(first) = &mut departed.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	first.reconnect = session::workspace::Reconnect::Manual;
	first.seat = None;
	owner.replace_workspace(&departed).await.unwrap();
	let report = memberships
		.reconcile(owner, &departed, "ocapn://member.id", &mut entropy, |_| {
			panic!("departure cannot restart a live sibling")
		})
		.await;
	assert!(report.failures.is_empty());
	assert_eq!(report.ready, 1);
	assert!(host.send(&callbacks[0], "notify", &[]).await.is_err());
	host.send(&callbacks[1], "notify", &[]).await.unwrap();
	assert_eq!(
		received.get(),
		5,
		"one cancellation cannot retire a sibling observation"
	);
	memberships.close().await.unwrap();
	memberships.close().await.unwrap();
	assert!(host.send(&callbacks[1], "notify", &[]).await.is_err());
	assert_eq!(joins.get(), prior + 6);
	registration_precedes_seat(owner, &workspace, joins, registration).await;
}

/// A reconnecting directory clears its registration before it registers again.
/// A room that joined in that interval would be fenced the moment the new
/// registration landed, so it waits for the name it will carry.
async fn registration_precedes_seat(
	owner: &managed::Session<Platform>,
	workspace: &Workspace<Platform>,
	joins: &Cell<usize>,
	registration: custody::Coordinate,
) {
	let original = workspace.snapshot().await.unwrap().intent;
	let mut registering = original.clone();
	let directory = &mut registering.directories.as_mut_slice()[0];
	directory.source = Some(custody::FieldKey::new(
		NonZeroU64::new(7).unwrap(),
		NonZeroU64::new(1).unwrap(),
	));
	directory.name = None;
	assert!(directory.registers());
	owner.replace_workspace(&registering).await.unwrap();
	let prior = joins.get();
	let mut rooms = managed::Memberships::with_kinds(managed::MembershipKinds {
		discovery: false,
		directories: false,
		rooms: true,
		directs: false,
	});
	let mut entropy = realization::Entropy::seeded(300);
	for _ in 0..2 {
		let report = rooms
			.reconcile(owner, &registering, "ocapn://member.id", &mut entropy, |_| {
				panic!("a room cannot take a seat before its directory registers")
			})
			.await;
		assert!(
			report.failures.is_empty(),
			"unregistered directory: {:?}",
			report.failures
		);
		assert_eq!(report.ready, 0);
		assert_eq!(joins.get(), prior);
	}
	let mut registered = workspace.snapshot().await.unwrap().intent;
	registered.directories.as_mut_slice()[0].name = Some(custody::FieldKey::new(
		registration.key.slot(),
		registration.key.generation(),
	));
	owner.replace_workspace(&registered).await.unwrap();
	let report = rooms
		.reconcile(owner, &registered, "ocapn://member.id", &mut entropy, |_| {
			Box::new(|_| Ok(Argument::Void))
		})
		.await;
	assert!(
		report.failures.is_empty(),
		"registered directory: {:?}",
		report.failures
	);
	assert_eq!(report.ready, 1);
	assert_eq!(joins.get(), prior + 1, "the room joins once, under the registration");
	rooms.close().await.unwrap();
	let mut restored = workspace.snapshot().await.unwrap().intent;
	let directory = &mut restored.directories.as_mut_slice()[0];
	directory.source = original.directories.as_slice()[0].source;
	directory.name = original.directories.as_slice()[0].name;
	owner.replace_workspace(&restored).await.unwrap();
}

async fn room_callbacks(owner: &managed::Session<Platform>, intent: &Intent) -> Vec<Ref> {
	let mut callbacks = Vec::new();
	for row in intent.conversations.as_slice() {
		let session::workspace::Conversation::Room(row) = row else {
			unreachable!()
		};
		callbacks.push(
			owner
				.restore_custody(&[session::workspace::InboxSelection::room(row, intent)
					.unwrap()
					.coordinate()])
				.await
				.unwrap()
				.remove(0),
		);
	}
	callbacks
}
