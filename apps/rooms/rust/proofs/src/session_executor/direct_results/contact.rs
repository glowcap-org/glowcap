//! First result adoption cannot relabel its persisted original contact witness.
use super::*;
use rooms_glowcap::client::workspace::{ResultImport, Workspace};

pub(super) async fn refuse_replacement(host: &Host, source: &Ref, platform: &Platform) {
	let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
	let command = workspace
		.recover_effect("introduced")
		.await
		.unwrap()
		.expect("unadopted introduction");
	let snapshot = workspace.snapshot().await.unwrap();
	let directory = &snapshot.intent.directories.as_slice()[0];
	let destination = coordinate(custody::Role::DirectAccess, 99);
	let mappings = [ResultImport {
		result: coordinate(custody::Role::DirectAccess, 1),
		destination,
	}];
	let mut candidate = snapshot.intent.clone();
	candidate
		.conversations
		.try_push(workspace::Conversation::Direct(Box::new(workspace::Direct {
			kind: workspace::DirectKind::Direct,
			id: rooms_application::fields::Text::new("contact".into()).unwrap(),
			directory: directory.id.clone(),
			peer: rooms_application::fields::Text::new("peer".into()).unwrap(),
			source: None,
			access: Some(custody::FieldKey::new(
				destination.key.slot(),
				destination.key.generation(),
			)),
			introduction: Some(workspace::Introduction {
				access: directory.access,
				name: directory.name.unwrap(),
				callback: directory.inbox.unwrap(),
				opening: rooms_application::fields::Text::new("opening".into()).unwrap(),
				registration: rooms_application::fields::Text::new(REGISTRATION.into()).unwrap(),
			}),
			inbox: None,
			closed: false,
			lines: List::default(),
			draft: rooms_application::fields::Text::new("".into()).unwrap(),
		})))
		.unwrap();
	let refused = command
		.prepare_result_acquisition_with_source(snapshot.revision, &mappings, &[], &candidate, None)
		.unwrap()
		.submit()
		.await;
	assert!(
		refused.is_err(),
		"first adoption cannot rebind the original local contact"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, snapshot.revision);
	assert!(
		!command.adopted().await.unwrap(),
		"refusal keeps the original receipt unadopted"
	);
}

/// Production result acquisition checks both the positive and refused opening.
pub(super) async fn adopt_exact(host: &Host, source: &Ref, platform: &Platform) {
	let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
	let command = workspace
		.recover_effect("cold-introduced")
		.await
		.unwrap()
		.expect("unadopted introduction");
	let snapshot = workspace.snapshot().await.unwrap();
	let directory = &snapshot.intent.directories.as_slice()[0];
	let mut candidate = snapshot.intent.clone();
	let workspace::Conversation::Direct(row) = &mut candidate.conversations.as_mut_slice()[0] else {
		panic!("direct candidate");
	};
	row.introduction = Some(workspace::Introduction {
		access: directory.access,
		name: directory.name.unwrap(),
		callback: directory.inbox.unwrap(),
		registration: rooms_application::fields::Text::new(REGISTRATION.into()).unwrap(),
		opening: rooms_application::fields::Text::new("other-opening".into()).unwrap(),
	});
	let destination = coordinate(custody::Role::DirectAccess, 10);
	let mappings = [ResultImport {
		result: coordinate(custody::Role::DirectAccess, 1),
		destination,
	}];
	assert!(
		command
			.prepare_result_acquisition_with_source(snapshot.revision, &mappings, &[], &candidate, None)
			.unwrap()
			.submit()
			.await
			.is_err(),
		"another opening cannot adopt this result"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, snapshot.revision);
	assert!(!command.adopted().await.unwrap(), "refusal preserves the receipt");
	let workspace::Conversation::Direct(row) = &mut candidate.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	row.introduction.as_mut().unwrap().opening = rooms_application::fields::Text::new("opening".into()).unwrap();
	command
		.prepare_result_acquisition_with_source(snapshot.revision, &mappings, &[], &candidate, None)
		.unwrap()
		.submit()
		.await
		.unwrap();
	assert!(
		command.adopted().await.unwrap(),
		"the exact opening adopts its live route"
	);
	assert_eq!(
		workspace.snapshot().await.unwrap().intent,
		candidate,
		"route and contact commit together"
	);
}
