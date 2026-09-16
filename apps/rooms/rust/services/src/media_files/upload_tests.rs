use super::{tests::description, *};
use glowcap::Session;
use rooms_application::{files::CHUNK_BYTES, room::attachment::Attachment};
use rooms_glowcap::client::sources::Source;
use std::{cell::Cell, rc::Rc, time::Duration};

pub(super) async fn run(session: &Session, peer: &Session) {
	let size = 1024 * 1024;
	let bytes = vec![7; size];
	let original = bytes.as_ptr();
	let source = Source::bytes(description("local", size), bytes).unwrap();
	let reads = Rc::new(Cell::new(0));
	let observed = reads.clone();
	let _root = peer
		.publish("upload-reuse", move |_, _| {
			observed.set(observed.get() + 1);
			Err("sender must not download its own file".into())
		})
		.unwrap();
	let blob = session.fetch("upload-reuse").await.unwrap();
	let attachment = Attachment {
		description: source.description().clone(),
		blob,
	};
	let mut owner = MediaFiles::default();
	assert!(
		owner
			.uploads(
				session,
				vec![
					(attachment.blob.clone(), source.capture().unwrap()),
					(attachment.blob.clone(), source.capture().unwrap()),
				],
				&[],
			)
			.is_err()
	);
	assert_eq!(owner.usage().files, 0, "duplicate upload admission is atomic");
	let upload = owner
		.uploads(session, vec![(attachment.blob.clone(), source.capture().unwrap())], &[])
		.unwrap()
		.pop()
		.unwrap();
	let file = owner.receive(session, attachment.clone()).unwrap();
	assert_eq!(owner.usage().files, 1, "echo shares the admitted upload");
	assert_eq!(owner.usage().bytes, size);
	assert!(
		owner
			.uploads(session, vec![(attachment.blob.clone(), source.capture().unwrap())], &[])
			.is_err()
	);
	assert_eq!(
		owner.usage().bytes,
		size,
		"an upload cannot charge the same identity twice"
	);
	assert!(
		tokio::time::timeout(Duration::from_millis(10), file.materialize())
			.await
			.is_err(),
		"local bytes cannot claim success before upload acknowledgement"
	);
	upload.complete();
	let retained = file.materialize().await.unwrap();
	assert_eq!(retained.span(0, CHUNK_BYTES).unwrap().as_ref().as_ptr(), original);
	let kept = owner
		.receive_retaining(session, vec![attachment.clone()], &[file.previous(attachment.blob)])
		.unwrap();
	let again = kept[0].materialize().await.unwrap();
	assert_eq!(again.span(0, CHUNK_BYTES).unwrap().as_ref().as_ptr(), original);
	assert_eq!(
		reads.get(),
		0,
		"a 1 MiB upload and kept refile return zero payload bytes"
	);
	owner.close().await.unwrap();
	assert!(file.materialize().await.is_err());
	assert_eq!(
		retained.read(0, 3).unwrap(),
		[7; 3],
		"admitted readers survive retirement"
	);
	assert_eq!(owner.usage().bytes, size);
	drop((retained, again));
	assert_eq!(owner.usage().bytes, 0);

	let mut owner = MediaFiles::default();
	let _failed_root = peer
		.publish("upload-failed", |_, _| {
			panic!("failed local upload must not fall back to download")
		})
		.unwrap();
	let blob = session.fetch("upload-failed").await.unwrap();
	let upload = owner
		.uploads(session, vec![(blob.clone(), source.capture().unwrap())], &[])
		.unwrap();
	let file = owner
		.receive(
			session,
			Attachment {
				description: source.description().clone(),
				blob,
			},
		)
		.unwrap();
	drop(upload);
	assert!(
		file.materialize()
			.await
			.err()
			.unwrap()
			.to_string()
			.contains("without acknowledging")
	);
	assert_eq!(owner.usage().bytes, 0, "failed upload releases its receiver charge");
	owner.close().await.unwrap();
	pressure(session).await;
}

async fn pressure(session: &Session) {
	let mut owner = MediaFiles::default();
	let mut views = Vec::new();
	let mut identities = Vec::new();
	for _ in 0..rooms_application::files::sources::MAX_SOURCES {
		let blob = session.spawn_owned(|_, _| panic!("empty file needs no read")).unwrap();
		let file = owner
			.receive(
				session,
				Attachment {
					description: description("empty", 0),
					blob: blob.clone(),
				},
			)
			.unwrap();
		drop(file.materialize().await.unwrap());
		views.push(file);
		identities.push(blob);
	}
	let blob = session
		.spawn_owned(|_, _| panic!("retained upload must not read"))
		.unwrap();
	let source = Source::bytes(description("new", 1), vec![9]).unwrap();
	// Local history still names [A, B], while a delegated [B] revision is
	// queued ahead of our keep[0] + C. Peer indices already name B.
	let previous: Vec<_> = views[..2]
		.iter()
		.zip(&identities)
		.map(|(file, blob)| file.previous(blob.clone()))
		.collect();
	let upload = owner
		.uploads(
			session,
			vec![(blob.clone(), source.capture().unwrap())],
			&identities[..2],
		)
		.unwrap()
		.pop()
		.unwrap();
	assert!(
		views[0].materialize().await.is_ok(),
		"the earlier local selection stays protected until authoritative replay"
	);
	assert!(
		views[1].materialize().await.is_ok(),
		"the peer's reordered keep[0] survives upload admission"
	);
	assert!(
		views[2].materialize().await.is_err(),
		"ordinary oldest unpinned preview is the victim"
	);
	let kept = Attachment {
		description: description("empty", 0),
		blob: identities[1].clone(),
	};
	let delegated = owner.receive_retaining(session, vec![kept.clone()], &previous).unwrap();
	assert!(delegated[0].materialize().await.is_ok());
	let mut refiled = owner
		.receive_retaining(
			session,
			vec![
				kept.clone(),
				Attachment {
					description: source.description().clone(),
					blob,
				},
			],
			&[delegated[0].previous(kept.blob)],
		)
		.unwrap();
	assert!(refiled[0].materialize().await.is_ok());
	let file = refiled.pop().unwrap();
	upload.complete();
	let mut readers = vec![file.materialize().await.unwrap()];
	for (at, file) in views.iter().enumerate() {
		if at != 2 {
			readers.push(file.materialize().await.unwrap());
		}
	}
	let before = owner.usage();
	let fresh = (0..2)
		.map(|_| {
			(
				session.spawn_owned(|_, _| panic!("refused batch cannot read")).unwrap(),
				source.capture().unwrap(),
			)
		})
		.collect();
	assert!(owner.uploads(session, fresh, &[]).is_err());
	assert_eq!(
		owner.usage(),
		before,
		"pinned pressure refuses the entire batch without eviction"
	);
	assert_eq!(readers[0].read(0, 1).unwrap(), [9]);
	drop(readers);
	owner.close().await.unwrap();
}
