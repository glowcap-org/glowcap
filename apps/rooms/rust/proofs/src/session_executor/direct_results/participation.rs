//! Collaborators acquire only their exact introduction, including reopening.
use super::*;
use rooms_application::fields::Text;
use rooms_glowcap::client::workspace::{ResultImport, Workspace};

pub(super) async fn run(host: &Host, owner: &managed::Session<Platform>, platform: &Platform) {
	let policy = rooms_glowcap::policy::descriptor().unwrap();
	let terms = policy
		.value_for_kind(
			session::KIND,
			&[Permission::ObserveWorkspace.key(), Permission::InteractWorkspace.key()],
			&[],
		)
		.unwrap();
	let (source, _) = owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
	let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
	for (id, slot) in [("collaborator-direct", 40), ("collaborator-reopen", 41)] {
		let snapshot = workspace.snapshot().await.unwrap();
		let command = workspace
			.prepare_command(
				id,
				snapshot.revision,
				"startDirect",
				&["directory".into(), "peer".into(), REGISTRATION.into(), "opening".into()],
			)
			.await
			.unwrap();
		command.submit().await.unwrap();
		assert_eq!(finished(host, &source, id, &source).await.as_str(), Some("committed"));
		let snapshot = workspace.snapshot().await.unwrap();
		let directory = &snapshot.intent.directories.as_slice()[0];
		let destination = coordinate(custody::Role::DirectAccess, slot);
		let initiating = coordinate(custody::Role::SessionAccess, slot);
		let mappings = [ResultImport {
			result: coordinate(custody::Role::DirectAccess, 1),
			destination,
		}];
		let prior = snapshot.intent.conversations.as_slice().iter().rposition(|row| {
			matches!(row, workspace::Conversation::Direct(row) if row.closed && row.id.text().as_str() == Some("collaborator-direct"))
		});
		let mut next = workspace::Direct {
			kind: workspace::DirectKind::Direct,
			id: Text::new("collaborator-direct".into()).unwrap(),
			directory: directory.id.clone(),
			peer: Text::new("peer".into()).unwrap(),
			source: Some(custody::FieldKey::new(
				initiating.key.slot(),
				initiating.key.generation(),
			)),
			access: Some(custody::FieldKey::new(
				destination.key.slot(),
				destination.key.generation(),
			)),
			introduction: Some(workspace::Introduction {
				access: directory.access,
				name: directory.name.unwrap(),
				callback: directory.inbox.unwrap(),
				registration: Text::new(REGISTRATION.into()).unwrap(),
				opening: Text::new("opening".into()).unwrap(),
			}),
			inbox: None,
			lines: List::default(),
			closed: false,
			draft: Text::new("".into()).unwrap(),
		};
		let mut candidate = snapshot.intent.clone();
		if let Some(at) = prior {
			let workspace::Conversation::Direct(old) = &candidate.conversations.as_slice()[at] else {
				unreachable!()
			};
			next.draft = old.draft.clone();
			candidate.conversations.as_mut_slice()[at] = workspace::Conversation::Direct(Box::new(next));
		} else {
			candidate
				.conversations
				.try_push(workspace::Conversation::Direct(Box::new(next)))
				.unwrap();
		}
		for attack in 0..3 {
			let mut altered = candidate.clone();
			let mut releases = Vec::new();
			match attack {
				0 => altered.keep_history = !altered.keep_history,
				1 => releases.push(coordinate(custody::Role::DirectoryAccess, 1)),
				_ => {
					let position = prior.unwrap_or(altered.conversations.as_slice().len() - 1);
					let workspace::Conversation::Direct(row) = &mut altered.conversations.as_mut_slice()[position]
					else {
						unreachable!()
					};
					row.peer = Text::new("substitute-peer".into()).unwrap();
				}
			}
			assert!(
				command
					.prepare_result_acquisition_with_source(
						snapshot.revision,
						&mappings,
						&releases,
						&altered,
						Some(custody::FieldKey::new(
							initiating.key.slot(),
							initiating.key.generation()
						))
					)
					.unwrap()
					.submit()
					.await
					.is_err()
			);
			assert_eq!(
				workspace.snapshot().await.unwrap().revision,
				snapshot.revision,
				"refused acquisition changes nothing"
			);
			assert!(!command.adopted().await.unwrap());
		}
		command
			.prepare_result_acquisition_with_source(
				snapshot.revision,
				&mappings,
				&[],
				&candidate,
				Some(custody::FieldKey::new(
					initiating.key.slot(),
					initiating.key.generation(),
				)),
			)
			.unwrap()
			.submit()
			.await
			.unwrap();
		assert!(command.adopted().await.unwrap());
		assert_eq!(workspace.snapshot().await.unwrap().intent, candidate);
		if prior.is_none() {
			let row = candidate.conversations.as_mut_slice().last_mut().unwrap();
			let workspace::Conversation::Direct(row) = row else {
				unreachable!()
			};
			row.closed = true;
			row.access = None;
			row.inbox = None;
			row.draft = Text::new("draft held while closed".into()).unwrap();
			owner.replace_workspace(&candidate).await.unwrap();
		}
	}
}
