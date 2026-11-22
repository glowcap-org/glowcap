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
	let start = workspace::StartDirect {
		directory: "directory",
		peer: "peer",
		registration: REGISTRATION,
		opening: "opening",
	};
	for (id, slot) in [("collaborator-direct", 40), ("collaborator-reopen", 41)] {
		let snapshot = workspace.snapshot().await.unwrap();
		let command = workspace
			.prepare_command(id, snapshot.revision, "startDirect", &start.arguments())
			.await
			.unwrap();
		command.submit().await.unwrap();
		assert_eq!(finished(host, &source, id, &source).await.as_str(), Some("committed"));
		let snapshot = workspace.snapshot().await.unwrap();
		let destination = coordinate(custody::Role::DirectAccess, slot);
		let initiating = coordinate(custody::Role::SessionAccess, slot);
		let receipt = rooms_application::content::session::results::Direct {
			inbox: coordinate(custody::Role::DirectAccess, 1).key.retag(),
		};
		// The shared plan is the candidate, so the session's admission rule
		// holds the plan every front submits.
		let plan = workspace::adopt_direct(
			&snapshot.intent,
			&snapshot.intent,
			id,
			&start,
			&receipt,
			destination.key.retag(),
			initiating.key.retag(),
		)
		.unwrap();
		assert_eq!(
			plan.conversation.text().as_str(),
			Some("collaborator-direct"),
			"a new route lands under its operation and a closed one reopens under its own id"
		);
		let mappings: Vec<_> = plan
			.mappings
			.iter()
			.map(|&[result, destination]| ResultImport { result, destination })
			.collect();
		let mut candidate = plan.intent;
		let position = candidate
			.conversations
			.as_slice()
			.iter()
			.position(|row| row.id() == &plan.conversation)
			.unwrap();
		let reopened = id != "collaborator-direct";
		for attack in 0..3 {
			let mut altered = candidate.clone();
			let mut releases = Vec::new();
			match attack {
				0 => altered.keep_history.toggle(),
				1 => releases.push(coordinate(custody::Role::DirectoryAccess, 1)),
				_ => {
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
						Some(initiating.key.retag())
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
				Some(initiating.key.retag()),
			)
			.unwrap()
			.submit()
			.await
			.unwrap();
		assert!(command.adopted().await.unwrap());
		assert_eq!(workspace.snapshot().await.unwrap().intent, candidate);
		if !reopened {
			let workspace::Conversation::Direct(row) = &mut candidate.conversations.as_mut_slice()[position] else {
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
