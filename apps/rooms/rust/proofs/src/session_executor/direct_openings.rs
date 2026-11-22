//! An incoming opening lands in the open row that reaches its registration,
//! so a member who closed their side and opens again continues the one open
//! row. With none open it is a new row, and a closed row stays closed. Every
//! opening a row took, the one it holds now included, refuses replay.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::Workspace;

/// A registration no other row of the fixture reaches.
const REGISTRATION: &str = "00000000-0000-4000-8000-000000000002";

pub(super) async fn run(host: &Host, owner: &managed::Session<Platform>, source: &Ref, callback: &Ref) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let original = workspace.snapshot().await.unwrap();
	let selected = workspace::InboxSelection::directory(&original.intent.directories.as_slice()[0]).unwrap();
	let request = |id: &str, opening: &str| {
		vec![
			serde_json::to_string(&selected).unwrap().into(),
			callback.clone().into(),
			id.into(),
			"peer".into(),
			REGISTRATION.into(),
			opening.into(),
		]
	};
	let accept = async |id: &str, opening: &str| {
		host.send(source, "accept-direct-introduction", &request(id, opening))
			.await
			.map(|landed| landed.as_str().map(str::to_owned))
	};
	// The rows that reach the registration, each with whether it is open and
	// the opening it holds.
	let rows = async || -> Vec<(String, bool, String)> {
		let snapshot = workspace.snapshot().await.unwrap();
		snapshot
			.intent
			.conversations
			.as_slice()
			.iter()
			.filter_map(|row| match row {
				workspace::Conversation::Direct(row) => {
					let introduction = row.introduction.as_ref()?;
					(introduction.registration.text().as_str() == Some(REGISTRATION)).then(|| {
						Some((
							row.id.text().as_str()?.to_owned(),
							!row.closed,
							introduction.opening.text().as_str()?.to_owned(),
						))
					})?
				}
				workspace::Conversation::Room(_) => None,
			})
			.collect()
	};
	let first = "incoming-first".to_owned();
	assert_eq!(accept("incoming-first", "first").await.unwrap(), Some(first.clone()));
	let admitted = workspace.snapshot().await.unwrap();
	assert_eq!(accept("incoming-first", "first").await.unwrap(), Some(first.clone()));
	assert_eq!(
		workspace.snapshot().await.unwrap().revision,
		admitted.revision,
		"exact retry creates no second receiver"
	);
	// The member closed their side and opened again while this row is open:
	// the new opening continues this row, and no second one opens.
	assert_eq!(accept("incoming-second", "second").await.unwrap(), Some(first.clone()));
	assert_eq!(rows().await, [(first.clone(), true, "second".to_owned())]);
	assert!(
		accept("incoming-first", "first").await.is_err(),
		"the replaced opening is refused"
	);
	// A third opening lands too. A late replay of the second, which names no
	// row by its id and no longer matches the row's introduction, is refused
	// by the openings the row took, and leaves the third's route in place.
	assert_eq!(accept("incoming-third", "third").await.unwrap(), Some(first.clone()));
	let third = workspace.snapshot().await.unwrap();
	assert!(accept("incoming-second", "second").await.is_err());
	assert_eq!(workspace.snapshot().await.unwrap().revision, third.revision);
	assert_eq!(rows().await, [(first.clone(), true, "third".to_owned())]);
	let mut closed = workspace.snapshot().await.unwrap().intent;
	closed.active = Some(rooms_application::fields::Text::new(first.as_str().into()).unwrap());
	for conversation in closed.conversations.as_mut_slice() {
		if let workspace::Conversation::Direct(row) = conversation
			&& row.id.text().as_str() == Some(first.as_str())
		{
			row.closed = true;
		}
	}
	owner.replace_workspace(&closed).await.unwrap();
	let retired = workspace.snapshot().await.unwrap();
	assert!(accept("incoming-third", "third").await.is_err());
	assert!(
		accept("stale-renamed", "third").await.is_err(),
		"a different display ID cannot revive the closed opening"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, retired.revision);
	// A fresh opening is a new row beside the closed one, which the view
	// follows from the selected closed row.
	let fresh = "incoming-fresh".to_owned();
	assert_eq!(accept("incoming-fresh", "fresh").await.unwrap(), Some(fresh.clone()));
	assert_eq!(
		rows().await,
		[
			(first.clone(), false, "third".to_owned()),
			(fresh.clone(), true, "fresh".to_owned())
		]
	);
	let followed = workspace.snapshot().await.unwrap();
	assert_eq!(
		followed.intent.active.as_ref().and_then(|id| id.text().as_str()),
		Some("incoming-fresh"),
		"a fresh opening replaces the selected closed conversation for the exact registered peer"
	);
	for (id, opening) in [("incoming-first", "first"), ("incoming-second", "second")] {
		assert!(
			accept(id, opening).await.is_err(),
			"an opening the closed row took stays refused"
		);
	}
	assert_eq!(workspace.snapshot().await.unwrap().revision, followed.revision);
	owner.replace_workspace(&original.intent).await.unwrap();
}
