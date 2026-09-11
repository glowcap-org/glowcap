use super::*;
use crate::session_runtime::direct_events::{Events, EVENT_LIMIT};
use glowcap::{Argument, Ref};
use rooms_application::room::message::ChangeKind;

pub(super) async fn exercise(
	runtime: &DirectoryRuntime,
	context: &AcceptedDirect,
	offer: &peers::Offer,
	line: &Ref,
	messages: &mut Events,
) {
	// The caller still holds said and edited events. Handed-out work retains its
	// budget even though its channel slots are free.
	for _ in 0..EVENT_LIMIT - 2 {
		offer.session.send(line, "edit", &["queued".into()]).await.unwrap();
	}
	assert!(offer.session.send(line, "withdraw", &[]).await.is_err());
	drop(messages.next().await.unwrap());
	offer.session.send(line, "edit", &["still live".into()]).await.unwrap();
	drop(messages.next().await.unwrap());
	offer.session.send(line, "withdraw", &[]).await.unwrap();
	// Repeated withdrawal has no event and needs no capacity reservation.
	offer.session.send(line, "withdraw", &[]).await.unwrap();
	for _ in 0..EVENT_LIMIT - 2 {
		drop(messages.next().await.unwrap());
	}
	assert!(offer.session.send(line, "edit", &["withdrawn".into()]).await.is_err());
	let blob = offer
		.session
		.spawn_owned(|verb, args| {
			assert_eq!(verb, "read");
			assert_eq!(args[0].as_i64(), Some(0));
			assert_eq!(args[1].as_i64(), Some(3));
			Ok(Argument::Bytes(vec![1, 2, 3]))
		})
		.unwrap();
	let mut args = vec!["caption".into()];
	args.extend(record("first", &blob));
	let Argument::Reference(file_line) = offer.session.send(&offer.inbox, "dm", &args).await.unwrap() else {
		panic!("file line")
	};
	let initial = messages.next().await.unwrap();
	assert_eq!(initial.line().unwrap().kind, ChangeKind::Said);
	assert_eq!(initial.line().unwrap().files.len(), 1);
	assert_eq!(initial.line().unwrap().files[0].description.name(), "first");
	assert!(offer
		.session
		.send(&file_line, "refile", &["bad".into(), 0.into(), 0.into()])
		.await
		.is_err());
	let mut refile = vec!["replaced".into(), 0.into()];
	refile.extend(record("second", &blob));
	offer.session.send(&file_line, "refile", &refile).await.unwrap();
	let changed = messages.next().await.unwrap();
	assert_eq!(changed.line().unwrap().kind, ChangeKind::Refiled);
	assert_eq!(changed.line().unwrap().line, initial.line().unwrap().line);
	assert_eq!(
		changed
			.line()
			.unwrap()
			.files
			.iter()
			.map(|f| f.description.name())
			.collect::<Vec<_>>(),
		["first", "second"]
	);
	let directory = runtime.direct_directory(context).unwrap();
	let file =
		rooms_glowcap::client::files::File::new(directory.client().clone(), changed.line().unwrap().files[1].clone());
	assert_eq!(file.read(0, 3).await.unwrap(), [1, 2, 3]);
	// Malformed inline records and overlong captions must preserve both files.
	assert!(offer
		.session
		.send(&file_line, "refile", &["bad".into(), "file".into()])
		.await
		.is_err());
	assert!(offer
		.session
		.send(&file_line, "refile", &["x".repeat(8193).into(), 0.into()])
		.await
		.is_err());
	offer
		.session
		.send(&file_line, "refile", &["kept second".into(), 1.into()])
		.await
		.unwrap();
	let kept = messages.next().await.unwrap();
	assert_eq!(kept.line().unwrap().files.len(), 1);
	assert_eq!(kept.line().unwrap().files[0].description.name(), "second");
	offer.session.send(&file_line, "refile", &["".into()]).await.unwrap();
	let withdrawn = messages.next().await.unwrap();
	assert_eq!(withdrawn.line().unwrap().kind, ChangeKind::Withdrawn);
	assert!(withdrawn.line().unwrap().files.is_empty());
}
fn record(name: &str, blob: &Ref) -> [Argument; 7] {
	[
		"file".into(),
		name.into(),
		"application/octet-stream".into(),
		3.into(),
		blob.clone().into(),
		0.into(),
		0.into(),
	]
}
