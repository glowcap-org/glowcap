//! Collaborators acquire only their exact introduction, including reopening,
//! and never a second open row for one registration.
use super::*;
use rooms_application::fields::Text;
use rooms_glowcap::client::workspace::{ResultImport, Workspace};

const OTHER_REGISTRATION: &str = "00000000-0000-4000-8000-000000000002";

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
	// The owner's open row reaches another member, so the collaborator's
	// introductions below open and reopen rows of their own.
	let mut intent = workspace.snapshot().await.unwrap().intent;
	for row in intent.conversations.as_mut_slice() {
		if let workspace::Conversation::Direct(row) = row
			&& let Some(introduction) = row.introduction.as_mut()
		{
			introduction.registration = Text::new(OTHER_REGISTRATION.into()).unwrap();
		}
	}
	owner.replace_workspace(&intent).await.unwrap();
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
			second_open(host, &workspace, &source, &start, &plan.conversation).await;
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

/// A second introduction of a peer whose row is open commits, but its route
/// never lands in a second open row: the plan gives it back and the session
/// refuses the row the plan would not make.
async fn second_open(
	host: &Host,
	workspace: &Workspace<Platform>,
	source: &Ref,
	start: &workspace::StartDirect<'_>,
	open: &workspace::Id,
) {
	let id = "collaborator-twice";
	let snapshot = workspace.snapshot().await.unwrap();
	let command = workspace
		.prepare_command(id, snapshot.revision, "startDirect", &start.arguments())
		.await
		.unwrap();
	command.submit().await.unwrap();
	assert_eq!(finished(host, source, id, source).await.as_str(), Some("committed"));
	let snapshot = workspace.snapshot().await.unwrap();
	let destination = coordinate(custody::Role::DirectAccess, 42);
	let initiating = coordinate(custody::Role::SessionAccess, 42);
	let receipt = rooms_application::content::session::results::Direct {
		inbox: coordinate(custody::Role::DirectAccess, 1).key.retag(),
	};
	let current = &snapshot.intent;
	let planned = workspace::adopt_direct(
		current,
		current,
		id,
		start,
		&receipt,
		destination.key.retag(),
		initiating.key.retag(),
	);
	assert_eq!(planned, Err(workspace::DirectRefusal::Open(open.clone())));
	let mut twice = current.clone();
	let row = twice
		.conversations
		.as_slice()
		.iter()
		.find_map(|row| match row {
			workspace::Conversation::Direct(row) if row.id == *open => Some(row.clone()),
			_ => None,
		})
		.unwrap();
	let mut row = *row;
	row.id = workspace::Id::new(id.into()).unwrap();
	row.access = Some(destination.key.retag());
	row.source = Some(initiating.key.retag());
	row.inbox = None;
	row.lines = Default::default();
	row.draft = Default::default();
	twice
		.conversations
		.try_push(workspace::Conversation::Direct(Box::new(row)))
		.unwrap();
	let mappings = [ResultImport {
		result: coordinate(custody::Role::DirectAccess, 1),
		destination,
	}];
	let refused = command
		.prepare_result_acquisition_with_source(snapshot.revision, &mappings, &[], &twice, Some(initiating.key.retag()))
		.unwrap()
		.submit()
		.await
		.expect_err("a second open row for one registration is refused");
	assert!(
		!matches!(refused, rooms_glowcap::client::Error::WorkspaceConflict),
		"refused by the rule, not by a moved workspace"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, snapshot.revision);
	command.release().await.unwrap();
}
