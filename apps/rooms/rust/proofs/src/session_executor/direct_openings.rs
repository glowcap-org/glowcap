//! A retired incoming witness refuses replay; a fresh opening gets new custody.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::Workspace;

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
			"00000000-0000-4000-8000-000000000001".into(),
			opening.into(),
		]
	};
	let first = request("incoming-first", "first");
	assert_eq!(
		host.send(source, "accept-direct-introduction", &first)
			.await
			.unwrap()
			.as_str(),
		Some("incoming-first")
	);
	let admitted = workspace.snapshot().await.unwrap();
	assert_eq!(
		host.send(source, "accept-direct-introduction", &first)
			.await
			.unwrap()
			.as_str(),
		Some("incoming-first")
	);
	assert_eq!(
		workspace.snapshot().await.unwrap().revision,
		admitted.revision,
		"exact retry creates no second receiver"
	);
	let mut closed = admitted.intent;
	closed.active = Some(rooms_application::fields::Text::new("incoming-first".into()).unwrap());
	for conversation in closed.conversations.as_mut_slice() {
		if let workspace::Conversation::Direct(row) = conversation
			&& row.id.text().as_str() == Some("incoming-first")
		{
			row.closed = true;
		}
	}
	owner.replace_workspace(&closed).await.unwrap();
	let retired = workspace.snapshot().await.unwrap();
	assert!(host.send(source, "accept-direct-introduction", &first).await.is_err());
	assert!(
		host.send(source, "accept-direct-introduction", &request("stale-renamed", "first"))
			.await
			.is_err(),
		"a different display ID cannot revive the closed opening"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, retired.revision);
	assert_eq!(
		host.send(
			source,
			"accept-direct-introduction",
			&request("incoming-fresh", "fresh")
		)
		.await
		.unwrap()
		.as_str(),
		Some("incoming-fresh")
	);
	let reopened = workspace.snapshot().await.unwrap();
	assert_eq!(
		reopened.intent.active.as_ref().and_then(|id| id.text().as_str()),
		Some("incoming-fresh"),
		"a fresh opening replaces the selected closed conversation for the exact registered peer"
	);
	assert!(
		host.send(source, "accept-direct-introduction", &first).await.is_err(),
		"the retired witness remains refused after the fresh opening"
	);
	owner.replace_workspace(&original.intent).await.unwrap();
}
