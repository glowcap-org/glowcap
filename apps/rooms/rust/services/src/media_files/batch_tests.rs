use super::{tests::description, *};
use glowcap::Session;
use rooms_application::{files::sources::MAX_SOURCES, room::attachment::Attachment};

pub(super) async fn run(session: &Session) {
	let mut owner = MediaFiles::default();
	let mut oldest = None;
	let mut second = None;
	for index in 0..MAX_SOURCES {
		let blob = session.spawn_owned(|_, _| panic!("empty source read")).unwrap();
		let attachment = Attachment {
			description: description("empty", 0),
			blob,
		};
		let file = owner.receive(session, attachment.clone()).unwrap();
		drop(file.materialize().await.unwrap());
		if index == 0 {
			oldest = Some((attachment, file));
		} else if index == 1 {
			second = Some(file);
		}
	}
	let (old, first) = oldest.unwrap();
	let previous = vec![first.previous(old.blob.clone())];
	let fresh = Attachment {
		description: description("fresh", 0),
		blob: session.spawn_owned(|_, _| panic!("empty source read")).unwrap(),
	};
	let mut inconsistent = fresh.clone();
	inconsistent.description = description("different size", 1);
	let before = owner.usage();
	assert!(owner.receive_many(session, vec![fresh.clone(), inconsistent]).is_err());
	assert_eq!(owner.usage(), before, "a refused batch cannot evict or start a prefix");
	assert!(first.materialize().await.is_ok());
	assert!(second.as_ref().unwrap().materialize().await.is_ok());
	let batch = owner
		.receive_many(session, vec![old.clone(), fresh.clone(), fresh])
		.unwrap();
	assert_eq!(
		owner.usage().files,
		MAX_SOURCES,
		"duplicate batch capabilities spend one slot"
	);
	assert!(
		first.materialize().await.is_ok(),
		"selected oldest entry cannot be evicted"
	);
	assert!(second.unwrap().materialize().await.is_err());
	for file in &batch {
		drop(file.materialize().await.unwrap());
	}
	owner.expire(&first);
	drop((batch, first));
	// Retire the pool and its last strong entry owner. Weak actor history must
	// still prevent a replacement pool from recapturing an exhausted source.
	owner.close().await.unwrap();
	let mut owner = MediaFiles::default();
	let before = owner.usage();
	let expired = owner.receive_retaining(session, vec![old], &previous).unwrap();
	assert!(expired[0].materialize().await.is_err());
	assert_eq!(owner.usage(), before);
	owner.close().await.unwrap();

	let mut owner = MediaFiles::default();
	let mut held = Vec::new();
	// Tasks cannot poll during this synchronous admission sequence.
	for _ in 0..rooms_application::files::sources::MAX_READS - 1 {
		let blob = session
			.spawn_owned(|_, _| Err("not read during admission".into()))
			.unwrap();
		held.push(
			owner
				.receive(
					session,
					Attachment {
						description: description("pending", 1),
						blob,
					},
				)
				.unwrap(),
		);
	}
	let pair: Vec<_> = (0..2)
		.map(|_| Attachment {
			description: description("extra", 1),
			blob: session
				.spawn_owned(|_, _| panic!("refused batch cannot read a prefix"))
				.unwrap(),
		})
		.collect();
	let before = owner.usage();
	assert!(owner.receive_many(session, pair).is_err());
	assert_eq!(owner.usage(), before);
	assert_eq!(held.len(), before.active);
	owner.close().await.unwrap();
}
