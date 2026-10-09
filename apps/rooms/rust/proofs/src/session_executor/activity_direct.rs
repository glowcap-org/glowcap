//! Shared activity owns direct lines without viewers; acquisition replay does
//! not resolve a retired presentation occurrence into new authority.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::Workspace;
use std::cell::RefCell;

pub(super) async fn run(
	host: &Host,
	exporter: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	control: &Ref,
	reciprocal: &RefCell<Option<Ref>>,
) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let intent = workspace.snapshot().await.unwrap().intent;
	let workspace::Conversation::Direct(row) = &intent.conversations.as_slice()[0] else {
		unreachable!()
	};
	let target = managed::MembershipTarget::Direct(row.id.text().as_str().unwrap().into());
	let mut receive = owner.activity_receiver(&target);
	let mut membership = owner
		.supervise_direct(
			row,
			&mut realization::Entropy::seeded(601),
			move |verb, arguments, delivering, origin| {
				receive(managed::MembershipEvent::Direct {
					verb,
					arguments,
					delivering,
					origin,
				})
			},
		)
		.await
		.unwrap();
	membership.ready().await.unwrap();
	let before = owner.activity().token(owner.activity().cursor()).unwrap();
	let inbox = reciprocal.borrow().as_ref().unwrap().clone();
	let reply = exporter.spawn(|_, _| Ok(Argument::Void)).unwrap();
	let line = exporter
		.send(
			&inbox,
			rooms_application::direct::DM,
			&["without a viewer".into(), reply.into()],
		)
		.await
		.unwrap();
	let line = Ref::try_from(&line).unwrap();
	// No reader or listener has been created. The session owns this line.
	exporter
		.send(&line, "edit", &["edited before viewing".into()])
		.await
		.unwrap();
	let reader = workspace.activity_reader().await.unwrap();
	let initial: serde_json::Value = serde_json::from_str(&reader.read(&before, false).await.unwrap()).unwrap();
	let token = initial["cursor"].as_str().unwrap();
	assert_eq!(initial["incoming"], "directAccess");
	assert!(initial["data"].as_str().unwrap().contains("without a viewer"));
	let edited: serde_json::Value = serde_json::from_str(&reader.read(token, false).await.unwrap()).unwrap();
	assert!(edited["data"].as_str().unwrap().contains("edited before viewing"));
	super::activity_archives::run(
		host,
		exporter,
		owner,
		source,
		control,
		&inbox,
		edited["cursor"].as_str().unwrap(),
	)
	.await;

	let destination = requests::coordinate(custody::Role::DirectAccess, 91);
	let candidate = workspace.snapshot().await.unwrap();
	let mut intent = candidate.intent.clone();
	let mut received = (**row).clone();
	received.id = rooms_application::fields::Text::new("received".into()).unwrap();
	received.access = Some(custody::FieldKey::new(
		destination.key.slot(),
		destination.key.generation(),
	));
	received.inbox = None;
	received.lines = List::default();
	let mut conversations = intent.conversations.as_slice().to_vec();
	conversations.push(workspace::Conversation::Direct(Box::new(received)));
	intent.conversations = List::new(conversations).unwrap();
	let acquisition = workspace
		.prepare_activity_acquisition(token, destination, None, candidate.revision, &[], &intent)
		.await
		.unwrap();
	acquisition.submit().await.unwrap();
	let saved = owner.restore_custody(&[destination]).await.unwrap();
	assert_eq!(
		host.send(&saved[0], "retained-route", &[]).await.unwrap(),
		Argument::Void
	);

	exporter.send(&line, "withdraw", &[]).await.unwrap();
	assert!(
		exporter
			.send(&line, "edit", &["after withdrawal".into()])
			.await
			.is_err()
	);
	membership.close().await.unwrap();
	// The original callback is now retired. Exact replay owns its receipt;
	// a fresh mutation may not acquire from the same old event token.
	let revision = workspace.snapshot().await.unwrap().revision;
	acquisition.submit().await.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, revision);
	assert!(
		workspace
			.prepare_activity_acquisition(token, destination, None, candidate.revision, &[], &intent)
			.await
			.is_err(),
		"retired incoming authority refuses before new preparation"
	);
	drop((acquisition, saved, reader));
	owner.replace_workspace(&candidate.intent).await.unwrap();
}
