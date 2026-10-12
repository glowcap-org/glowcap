//! A delayed line receipt cannot attach its numeric identity to another seat.
use super::*;
use rooms_glowcap::client::workspace::{ResultImport, Workspace};

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	administrator: &Ref,
	source: &Ref,
	canonical: &str,
	original_target: Ref,
	replacement: Ref,
) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let (id, base, name, args): (String, u64, String, Vec<String>) = serde_json::from_str(canonical).unwrap();
	let command = workspace.prepare_command(&id, base, &name, &args).await.unwrap();
	let original = workspace.snapshot().await.unwrap().intent;
	let replacement_key = custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap());
	owner
		.import(
			custody::Coordinate {
				role: custody::Role::RoomSeat,
				key: replacement_key,
			},
			replacement.clone(),
			None,
		)
		.await
		.unwrap();
	let mut replacement_intent = original.clone();
	let session::workspace::Conversation::Room(room) = &mut replacement_intent.conversations.as_mut_slice()[0] else {
		panic!("room")
	};
	room.seat = Some(custody::FieldKey::new(
		replacement_key.slot(),
		replacement_key.generation(),
	));
	owner.replace_workspace(&replacement_intent).await.unwrap();
	let current = workspace.snapshot().await.unwrap();
	let mut candidate = current.intent.clone();
	let session::workspace::Conversation::Room(room) = &mut candidate.conversations.as_mut_slice()[0] else {
		panic!("room")
	};
	room.lines = List::new(vec![session::workspace::PostedLine {
		id: rooms_application::fields::SafeInteger::new(23).unwrap(),
		handle: key(),
	}])
	.unwrap();
	let mappings = [ResultImport {
		result: custody::Coordinate {
			role: custody::Role::Line,
			key: key(),
		},
		destination: custody::Coordinate {
			role: custody::Role::Line,
			key: key(),
		},
	}];
	let acquisition = command
		.prepare_result_acquisition(current.revision, &mappings, &[], &candidate)
		.unwrap();
	assert!(
		acquisition.submit().await.is_err(),
		"a late line receipt must refuse replacement membership"
	);
	assert_eq!(
		workspace.snapshot().await.unwrap().revision,
		current.revision,
		"refusal changes no custody or intent"
	);
	// Reusing the scalar coordinate must still compare the actual capability.
	for (target, number) in [(replacement, 23), (original_target, 24)] {
		let mut detached = original.clone();
		let session::workspace::Conversation::Room(room) = &mut detached.conversations.as_mut_slice()[0] else {
			panic!("room")
		};
		room.seat = None;
		let revision = workspace.snapshot().await.unwrap().revision;
		let coordinate = custody::Coordinate {
			role: custody::Role::RoomSeat,
			key: key(),
		};
		owner
			.acquire_workspace(administrator, revision, Vec::new(), &[coordinate], &detached)
			.await
			.unwrap();
		owner.import(coordinate, target, None).await.unwrap();
		owner.replace_workspace(&original).await.unwrap();
		let current = workspace.snapshot().await.unwrap();
		let mut candidate = current.intent.clone();
		let session::workspace::Conversation::Room(room) = &mut candidate.conversations.as_mut_slice()[0] else {
			panic!("room")
		};
		room.lines = List::new(vec![session::workspace::PostedLine {
			id: rooms_application::fields::SafeInteger::new(number).unwrap(),
			handle: key(),
		}])
		.unwrap();
		assert!(
			command
				.prepare_result_acquisition(current.revision, &mappings, &[], &candidate)
				.unwrap()
				.submit()
				.await
				.is_err(),
			"adoption must reject a replaced capability or a mismatched line number"
		);
		assert_eq!(workspace.snapshot().await.unwrap().revision, current.revision);
	}
	let current = workspace.snapshot().await.unwrap();
	let mut candidate = current.intent;
	let session::workspace::Conversation::Room(room) = &mut candidate.conversations.as_mut_slice()[0] else {
		panic!("room")
	};
	room.lines = List::new(vec![session::workspace::PostedLine {
		id: rooms_application::fields::SafeInteger::new(23).unwrap(),
		handle: key(),
	}])
	.unwrap();
	for attack in 0..3 {
		let mut altered = candidate.clone();
		let mut releases = Vec::new();
		let mut source_slot = None;
		match attack {
			0 => altered.keep_history = !altered.keep_history,
			1 => releases.push(custody::Coordinate {
				role: custody::Role::DirectoryAccess,
				key: key(),
			}),
			_ => source_slot = Some(key()),
		}
		assert!(
			command
				.prepare_result_acquisition_with_source(current.revision, &mappings, &releases, &altered, source_slot)
				.unwrap()
				.submit()
				.await
				.is_err(),
			"a collaborator cannot attach unrelated changes to a line result"
		);
		assert_eq!(workspace.snapshot().await.unwrap().revision, current.revision);
		assert!(!command.adopted().await.unwrap());
	}
	let mut stale = candidate.clone();
	stale.keep_history = !stale.keep_history;
	assert!(
		matches!(
			command
				.prepare_result_acquisition(current.revision - 1, &mappings, &[], &stale)
				.unwrap()
				.submit()
				.await,
			Err(rooms_glowcap::client::Error::WorkspaceConflict)
		),
		"stale acquisition has no authority to change intent"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, current.revision);
	command
		.prepare_result_acquisition(current.revision, &mappings, &[], &candidate)
		.unwrap()
		.submit()
		.await
		.unwrap();
}
