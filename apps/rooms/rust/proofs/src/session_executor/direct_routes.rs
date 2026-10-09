//! Reciprocal handoffs replace only the route admitted by the exact callback.
//! Older replay cannot select retired custody or redirect a newer reply.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::Workspace;

pub(super) async fn run(host: &Host, owner: &managed::Session<Platform>, source: &Ref) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let original = workspace.snapshot().await.unwrap();
	let mut intent = original.intent.clone();
	let callback = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
	let first = host.spawn(|_, _| Ok("first route".into())).unwrap();
	let second = host.spawn(|_, _| Ok("second route".into())).unwrap();
	for role in [
		custody::Role::DirectoryName,
		custody::Role::DirectoryInbox,
		custody::Role::DirectInbox,
	] {
		owner
			.import(requests::coordinate(role, 94), callback.clone(), None)
			.await
			.unwrap();
	}
	let workspace::Conversation::Direct(row) = &mut intent.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	let source_key = row.source.unwrap();
	row.access = None;
	row.inbox = Some(fresh());
	let directory = &mut intent.directories.as_mut_slice()[0];
	directory.name = Some(fresh());
	directory.inbox = Some(fresh());
	directory.source = Some(source_key);
	row.introduction = Some(workspace::Introduction {
		access: directory.access,
		name: fresh(),
		callback: fresh(),
		opening: rooms_application::fields::Text::new("opening".into()).unwrap(),
		registration: rooms_application::fields::Text::new("00000000-0000-4000-8000-000000000001".into()).unwrap(),
	});
	let selected = workspace::InboxSelection::direct(row).unwrap();
	let mut sibling = (**row).clone();
	sibling.id = rooms_application::fields::Text::new("independent-route".into()).unwrap();
	sibling.peer = rooms_application::fields::Text::new("another-peer".into()).unwrap();
	sibling.access = Some(custody::FieldKey::new(
		NonZeroU64::new(98).unwrap(),
		NonZeroU64::new(1).unwrap(),
	));
	sibling.introduction = None;
	sibling.inbox = None;
	owner
		.import(
			requests::coordinate(custody::Role::DirectAccess, 98),
			first.clone(),
			None,
		)
		.await
		.unwrap();
	intent
		.conversations
		.try_push(workspace::Conversation::Direct(Box::new(sibling)))
		.unwrap();
	owner.replace_workspace(&intent).await.unwrap();
	super::direct_openings::run(host, owner, source, &callback).await;
	let encoded = serde_json::to_string(&selected).unwrap();
	let first_request = vec![
		encoded.clone().into(),
		callback.clone().into(),
		first.clone().into(),
		1.into(),
	];
	let second_request = vec![encoded.into(), callback.clone().into(), second.clone().into(), 2.into()];
	host.send(source, "adopt-direct-route", &first_request).await.unwrap();
	let initial = workspace.snapshot().await.unwrap();
	host.send(source, "adopt-direct-route", &second_request)
		.await
		.expect("reopened peer hands its actual new receiver");
	let replaced = workspace.snapshot().await.unwrap();
	assert!(replaced.revision > initial.revision);
	let workspace::Conversation::Direct(row) = &replaced.intent.conversations.as_slice()[0] else {
		unreachable!()
	};
	let coordinate = custody::Coordinate {
		role: custody::Role::DirectAccess,
		key: fresh(),
	};
	let latest = custody::Coordinate {
		role: coordinate.role,
		key: custody::FieldKey::new(coordinate.key.slot(), NonZeroU64::new(2).unwrap()),
	};
	assert!(
		owner.restore_custody(&[coordinate]).await.is_err(),
		"previous generation retired atomically"
	);
	let restored = owner.restore_custody(&[latest]).await.unwrap();
	assert_eq!(restored[0], second);
	assert_eq!(
		owner
			.restore_custody(&[requests::coordinate(custody::Role::DirectAccess, 98)])
			.await
			.unwrap()[0],
		first,
		"another conversation retains its independently held occurrence"
	);
	assert_eq!(row.access.unwrap().generation().get(), 2);
	for request in [&first_request, &second_request] {
		host.send(source, "adopt-direct-route", request).await.unwrap();
		assert_eq!(
			workspace.snapshot().await.unwrap().revision,
			replaced.revision,
			"exact and old replay preserve the latest route"
		);
	}
	let mut aliased = replaced.intent.clone();
	let workspace::Conversation::Direct(other) = &mut aliased.conversations.as_mut_slice()[1] else {
		unreachable!()
	};
	other.access = row.access;
	assert!(
		owner.replace_workspace(&aliased).await.is_err(),
		"conversation-owned route coordinates cannot be aliased"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, replaced.revision);
	let mut substitution = second_request.clone();
	substitution[2] = first.clone().into();
	assert!(
		host.send(source, "adopt-direct-route", &substitution).await.is_err(),
		"one ordinal cannot name different authority"
	);
	let mut wrong_callback = second_request.clone();
	wrong_callback[1] = first.clone().into();
	assert!(host.send(source, "adopt-direct-route", &wrong_callback).await.is_err());
	// A newer unchanged handoff must still fence a delayed distinct handoff.
	let mut newer = second_request.clone();
	newer[3] = 4.into();
	host.send(source, "adopt-direct-route", &newer).await.unwrap();
	let watermark = workspace.snapshot().await.unwrap();
	let mut delayed = first_request.clone();
	delayed[3] = 3.into();
	host.send(source, "adopt-direct-route", &delayed).await.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, watermark.revision);
	let latest = custody::Coordinate {
		role: latest.role,
		key: custody::FieldKey::new(latest.key.slot(), NonZeroU64::new(4).unwrap()),
	};
	assert_eq!(owner.restore_custody(&[latest]).await.unwrap()[0], second);
	let collision = requests::coordinate(custody::Role::DirectAccess, 197);
	owner.import(collision, second.clone(), None).await.unwrap();
	owner
		.import(
			requests::coordinate(custody::Role::DirectInbox, 197),
			callback.clone(),
			None,
		)
		.await
		.unwrap();
	let before_collision = workspace.snapshot().await.unwrap();
	let mut collision_intent = watermark.intent.clone();
	let workspace::Conversation::Direct(row) = &mut collision_intent.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	row.inbox = Some(custody::FieldKey::new(collision.key.slot(), collision.key.generation()));
	assert!(
		owner.replace_workspace(&collision_intent).await.is_err(),
		"callback installation reserves its route slot before accepting handoffs"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, before_collision.revision);
	// Even this conversation's own retained route cannot seed a new callback
	// lifetime. A new generation at the old slot still restarts route ordinal one.
	let workspace::Conversation::Direct(row) = &watermark.intent.conversations.as_slice()[0] else {
		unreachable!()
	};
	let own_slot = row.access.unwrap().slot();
	let self_collision = custody::Coordinate {
		role: custody::Role::DirectInbox,
		key: custody::FieldKey::new(own_slot, NonZeroU64::new(2).unwrap()),
	};
	let before = workspace.snapshot().await.unwrap();
	let mut self_colliding = before.intent.clone();
	let workspace::Conversation::Direct(row) = &mut self_colliding.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	let old_inbox = row.inbox.unwrap();
	row.inbox = Some(custody::FieldKey::new(
		self_collision.key.slot(),
		self_collision.key.generation(),
	));
	assert!(
		workspace
			.prepare_acquisition(
				before.revision,
				vec![rooms_glowcap::client::workspace::Import {
					coordinate: self_collision,
					reference: callback.clone(),
					uri: None,
				}],
				&[custody::Coordinate {
					role: custody::Role::DirectInbox,
					key: custody::FieldKey::new(old_inbox.slot(), old_inbox.generation())
				}],
				&self_colliding
			)
			.unwrap()
			.submit()
			.await
			.is_err(),
		"replacement callback cannot inherit its old route watermark"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, before.revision);
	// A fresh callback has a fresh slot and restarts its own ordinal at one.
	let next = requests::coordinate(custody::Role::DirectInbox, 196);
	let callback = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
	owner.import(next, callback.clone(), None).await.unwrap();
	let mut restarted = watermark.intent.clone();
	let workspace::Conversation::Direct(row) = &mut restarted.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	row.inbox = Some(custody::FieldKey::new(next.key.slot(), next.key.generation()));
	let selected = workspace::InboxSelection::direct(row).unwrap();
	owner.replace_workspace(&restarted).await.unwrap();
	let restarted_request = vec![
		serde_json::to_string(&selected).unwrap().into(),
		callback.into(),
		first.into(),
		1.into(),
	];
	host.send(source, "adopt-direct-route", &restarted_request)
		.await
		.unwrap();
	let restarted = workspace.snapshot().await.unwrap();
	assert!(
		host.send(source, "adopt-direct-route", &newer).await.is_err(),
		"old callback cannot replay into a fresh callback epoch"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, restarted.revision);
	let mut closed = restarted.intent.clone();
	let workspace::Conversation::Direct(row) = &mut closed.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	row.closed = true;
	owner.replace_workspace(&closed).await.unwrap();
	assert!(
		host.send(source, "adopt-direct-route", &restarted_request)
			.await
			.is_err(),
		"retired callback cannot admit replay"
	);
	owner.replace_workspace(&original.intent).await.unwrap();
}
fn fresh<K>() -> custody::FieldKey<K> {
	custody::FieldKey::new(NonZeroU64::new(94).unwrap(), NonZeroU64::new(1).unwrap())
}
