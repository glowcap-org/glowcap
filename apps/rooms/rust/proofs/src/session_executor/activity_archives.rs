//! Received archives keep original arrival admission across an independent reader.
use super::*;
use rooms_application::{
	archive::ShareKind,
	content::{permissions::Permission, session::workspace::ReceivedArchive},
	fields::Text,
};
use rooms_glowcap::client::workspace::Workspace;

pub(super) async fn run(
	host: &Host,
	exporter: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	control: &Ref,
	inbox: &Ref,
	cursor: &str,
) {
	let calls = Rc::new(Cell::new(0));
	let archive = exporter
		.spawn({
			let calls = calls.clone();
			move |verb, _| {
				let verb = verb.ok_or("fixture requires a method")?;
				assert_eq!(verb, "read");
				calls.set(calls.get() + 1);
				Ok(Argument::Void)
			}
		})
		.unwrap();
	exporter
		.send(
			inbox,
			rooms_application::direct::HAND_ARCHIVE,
			&["directory".into(), "room".into(), "garden".into(), archive.into()],
		)
		.await
		.unwrap();
	let original = Workspace::local(host.clone(), Platform::default(), source.clone());
	let reader = original.activity_reader().await.unwrap();
	let event: serde_json::Value = serde_json::from_str(&reader.read(cursor, false).await.unwrap()).unwrap();
	assert_eq!(event["incoming"], "archiveAccess");
	let token = event["cursor"].as_str().unwrap();
	let policy = rooms_glowcap::policy::descriptor().unwrap();
	let terms = policy
		.value_for_kind(session::KIND, &[Permission::ReadArchive.key()], &[])
		.unwrap();
	let (viewer, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
	let snapshot = original.snapshot().await.unwrap();
	let mut intent = snapshot.intent.clone();
	let channel = intent.conversations.as_slice()[0].id().clone();
	let access = requests::coordinate(custody::Role::ArchiveAccess, 92);
	let origin = requests::coordinate(custody::Role::SessionAccess, 93);
	intent.archive_shares = List::new(vec![ReceivedArchive {
		id: Text::new("received-archive".into()).unwrap(),
		channel,
		directory: Text::new("directory".into()).unwrap(),
		kind: ShareKind::Room,
		conversation: Some(Text::new("garden".into()).unwrap()),
		from: Text::new("peer".into()).unwrap(),
		access: custody::FieldKey::new(access.key.slot(), access.key.generation()),
		source: custody::FieldKey::new(origin.key.slot(), origin.key.generation()),
		durable: false,
	}])
	.unwrap();
	let acquisition = original
		.prepare_activity_acquisition(token, access, Some(origin), snapshot.revision, &[], &intent)
		.await
		.unwrap();
	acquisition.submit().await.unwrap();
	acquisition.submit().await.unwrap();
	let independent = Workspace::local(host.clone(), Platform::default(), viewer.clone());
	let retained = independent.archive_reader(access, false).await.unwrap();
	host.send(&retained, "read", &[]).await.unwrap();
	let before = calls.get();
	publication_results::lifecycle(host, control, "pause").await;
	assert!(
		host.send(&retained, "read", &[]).await.is_err(),
		"an independent reader must retain the original arrival source"
	);
	assert_eq!(calls.get(), before);
	publication_results::lifecycle(host, control, "resume").await;
	host.send(&retained, "read", &[]).await.unwrap();
	drop((retained, independent, viewer, acquisition, reader));
	owner.replace_workspace(&snapshot.intent).await.unwrap();
	sharing(host, exporter, owner, source, control).await;
	super::activity_offers::run(host, exporter, owner, source, inbox).await;
}

pub(super) async fn sharing(
	host: &Host,
	exporter: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	control: &Ref,
) {
	let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9147");
	let narrows = Rc::new(Cell::new(0));
	let issues = Rc::new(Cell::new(0));
	let revocations = Rc::new(Cell::new(0));
	let offers = Rc::new(Cell::new(0));
	let refuse_delivery = Rc::new(Cell::new(false));
	let delivered = Rc::new(std::cell::RefCell::new(None));
	let share_uri = glowcap::format_sturdyref(&locator, b"durable-share", glowcap::CaptpVersion::V1_0).unwrap();
	let read = exporter
		.spawn(|verb, _| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert_eq!(verb, "read");
			Ok(Argument::Void)
		})
		.unwrap();
	exporter
		.publish("share-source", {
			let read = read.clone();
			let narrows = narrows.clone();
			let issues = issues.clone();
			let revocations = revocations.clone();
			let share_uri = share_uri.clone();
			move || {
				let read = read.clone();
				let narrows = narrows.clone();
				let issues = issues.clone();
				let revocations = revocations.clone();
				let share_uri = share_uri.clone();
				Box::new(move |verb, args| {
					let verb = verb.ok_or("fixture requires a method")?;
					use rooms_application::archive::shares::protocol::{self, Request};
					if verb != "narrow" {
						let values: Vec<_> = rooms_glowcap::values(args).collect();
						return Ok(match Request::read(verb, &values).unwrap() {
							Request::Issue(share) => {
								assert_eq!(share.filter().conversation.as_ref().unwrap().as_str(), Some("direct"));
								issues.set(issues.get() + 1);
								share_uri.clone().into()
							}
							Request::Revoke(id) => {
								assert_eq!(id, "00000000-0000-4000-8000-000000000002");
								revocations.set(revocations.get() + 1);
								true.into()
							}
							Request::List => {
								assert_eq!(verb, protocol::LIST);
								Argument::List(vec![])
							}
						});
					}
					assert_eq!(verb, "narrow");
					assert_eq!(args.len(), 2);
					assert_eq!(args[1], Argument::from("read"));
					narrows.set(narrows.get() + 1);
					Ok(read.clone().into())
				})
			}
		})
		.unwrap();
	exporter
		.publish("share-recipient", {
			let delivered = delivered.clone();
			let offers = offers.clone();
			let share_uri = share_uri.clone();
			let refuse_delivery = refuse_delivery.clone();
			move || {
				let delivered = delivered.clone();
				let offers = offers.clone();
				let share_uri = share_uri.clone();
				let refuse_delivery = refuse_delivery.clone();
				Box::new(move |verb, args| {
					let verb = verb.ok_or("fixture requires a method")?;
					if verb == rooms_application::direct::OFFER_ARCHIVE {
						assert_eq!(args[3], Argument::from(share_uri.as_str()));
						offers.set(offers.get() + 1);
						return if refuse_delivery.get() {
							Err("delivery outcome is uncertain".into())
						} else {
							Ok(Argument::Void)
						};
					}
					assert_eq!(verb, rooms_application::direct::HAND_ARCHIVE);
					assert_eq!(args[1], Argument::from("direct"));
					assert!(delivered.borrow().is_none(), "original delivery cannot run twice");
					*delivered.borrow_mut() = Some(Ref::try_from(&args[3]).unwrap());
					Ok(Argument::Void)
				})
			}
		})
		.unwrap();
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let original = workspace.snapshot().await.unwrap();
	let mut intent = original.intent.clone();
	let archive = requests::coordinate(custody::Role::ArchiveAccess, 94);
	let recipient = requests::coordinate(custody::Role::DirectAccess, 95);
	intent.archive = Some(custody::FieldKey::new(archive.key.slot(), archive.key.generation()));
	let session::workspace::Conversation::Direct(mut row) = intent.conversations.as_slice()[0].clone() else {
		panic!("direct recipient");
	};
	let conversation = row.id.text().as_str().unwrap().to_owned();
	row.id = Text::new("sharing-recipient".into()).unwrap();
	row.access = Some(custody::FieldKey::new(recipient.key.slot(), recipient.key.generation()));
	row.source = None;
	row.inbox = None;
	row.introduction = None;
	row.lines = Default::default();
	let mut conversations = intent.conversations.as_slice().to_vec();
	conversations.push(session::workspace::Conversation::Direct(row));
	intent.conversations = List::new(conversations).unwrap();
	let archive_uri = glowcap::format_sturdyref(&locator, b"share-source", glowcap::CaptpVersion::V1_0).unwrap();
	let recipient_uri = glowcap::format_sturdyref(&locator, b"share-recipient", glowcap::CaptpVersion::V1_0).unwrap();
	let acquisition = workspace
		.prepare_acquisition(
			original.revision,
			vec![
				rooms_glowcap::client::workspace::Import {
					coordinate: archive,
					reference: host.enliven(&archive_uri).await.unwrap(),
					uri: Some(archive_uri),
				},
				rooms_glowcap::client::workspace::Import {
					coordinate: recipient,
					reference: host.enliven(&recipient_uri).await.unwrap(),
					uri: None,
				},
			],
			&[],
			&intent,
		)
		.unwrap();
	acquisition.submit().await.unwrap();
	let base = workspace.snapshot().await.unwrap().revision;
	let command = workspace
		.prepare_command(
			"archive-sharing",
			base,
			"shareArchiveHistory",
			&[
				conversation,
				"sharing-recipient".into(),
				"direct".into(),
				"00000000-0000-4000-8000-000000000001".into(),
				"History".into(),
			],
		)
		.await
		.unwrap();
	command
		.submit()
		.await
		.unwrap_or_else(|error| panic!("archive admission: {error:?}; {:?}", host.take_failures()));
	assert_eq!(
		finished(host, source, "archive-sharing", source).await.as_str(),
		Some("committed")
	);
	command.result().await.unwrap();
	command.submit().await.unwrap();
	assert_eq!(narrows.get(), 1, "receipt retry does not narrow or deliver again");
	let reader = delivered.borrow().as_ref().unwrap().clone();
	exporter.send(&reader, "read", &[]).await.unwrap();
	publication_results::lifecycle(host, control, "pause").await;
	assert!(
		exporter.send(&reader, "read", &[]).await.is_err(),
		"the delivered read facet retains the issuing source"
	);
	publication_results::lifecycle(host, control, "resume").await;
	exporter.send(&reader, "read", &[]).await.unwrap();
	let base = workspace.snapshot().await.unwrap().revision;
	let durable = workspace
		.prepare_command(
			"archive-durable",
			base,
			"offerDurableArchive",
			&[
				"direct".into(),
				"sharing-recipient".into(),
				"direct".into(),
				"00000000-0000-4000-8000-000000000002".into(),
				"Durable history".into(),
			],
		)
		.await
		.unwrap();
	durable.submit().await.unwrap();
	assert_eq!(
		finished(host, source, "archive-durable", source).await.as_str(),
		Some("committed")
	);
	durable.submit().await.unwrap();
	assert_eq!(
		(issues.get(), offers.get()),
		(1, 1),
		"durable receipt replay neither issues nor offers again"
	);
	assert!(workspace.issued_archive_shares().await.unwrap().is_empty());
	let base = workspace.snapshot().await.unwrap().revision;
	let revoke = workspace
		.prepare_command(
			"archive-revoke",
			base,
			"revokeIssuedArchiveShare",
			&["00000000-0000-4000-8000-000000000002".into()],
		)
		.await
		.unwrap();
	revoke.submit().await.unwrap();
	assert_eq!(
		finished(host, source, "archive-revoke", source).await.as_str(),
		Some("committed")
	);
	revoke.submit().await.unwrap();
	assert_eq!(revocations.get(), 1, "revocation retries recover the original receipt");
	refuse_delivery.set(true);
	let base = workspace.snapshot().await.unwrap().revision;
	let uncertain = workspace
		.prepare_command(
			"archive-uncertain",
			base,
			"offerDurableArchive",
			&[
				"direct".into(),
				"sharing-recipient".into(),
				"direct".into(),
				"00000000-0000-4000-8000-000000000002".into(),
				"Uncertain history".into(),
			],
		)
		.await
		.unwrap();
	uncertain.submit().await.unwrap();
	assert_eq!(
		finished(host, source, "archive-uncertain", source).await.as_str(),
		Some("unknown")
	);
	assert_eq!((issues.get(), offers.get()), (2, 2));
	refuse_delivery.set(false);
	uncertain.submit().await.unwrap();
	owner.resume_pending().unwrap();
	assert_eq!(
		finished(host, source, "archive-uncertain", source).await.as_str(),
		Some("unknown")
	);
	assert_eq!(
		(issues.get(), offers.get()),
		(2, 2),
		"unknown delivery cannot issue or offer again after replay and resume"
	);
	owner.replace_workspace(&original.intent).await.unwrap();
	// The recipient owns the handed facet until it releases it. Retire that
	// custody while both Hosts and the issuing attachment can still progress.
	drop(reader);
	delivered.borrow_mut().take();
	assert!(exporter.unpublish("share-recipient").unwrap());
	assert!(exporter.unpublish("share-source").unwrap());
}
