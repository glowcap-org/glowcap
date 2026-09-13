use super::*;
use crate::{
	session_archive::{FileRecording, MetadataReason},
	session_runtime::{
		direct_events::{Direction, EVENT_LIMIT},
		direct_outgoing::{Delivery, DirectOutgoing},
	},
};
use rooms_application::{direct::Notice, files::FileDescription, room::message::ChangeKind};
use rooms_glowcap::client::{
	direct,
	sources::{Reader, Source, Sources},
};
use std::{cell::Cell, pin::Pin};

struct Counted(Rc<Cell<usize>>, u8);
impl Reader for Counted {
	fn read(&self, _: usize, length: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, String>>>> {
		self.0.set(self.0.get() + 1);
		let byte = self.1;
		Box::pin(async move { Ok(vec![byte; length]) })
	}
}
fn source(name: &str, byte: u8, reads: &Rc<Cell<usize>>) -> Source {
	Source::reader(
		FileDescription::new(name.into(), "text/plain".into(), 3, 0, 0).unwrap(),
		Counted(reads.clone(), byte),
	)
}
struct Remote {
	owner: DirectEvents,
	events: Events,
	delay: Rc<Cell<bool>>,
	answers: mpsc::Receiver<(glowcap::Resolver, glowcap::Ref)>,
	_actor: glowcap::Ref,
}
async fn remote(offer: &peers::Offer, context: &AcceptedDirect) -> Remote {
	let (owner, events) = DirectEvents::new(rooms_platform::HostPlatform, &mut rooms_platform::OsEntropy).unwrap();
	let receiver = owner.receiver();
	let context = context.clone();
	let delay = Rc::new(Cell::new(false));
	let delayed = delay.clone();
	let (tx, answers) = mpsc::channel(4);
	let actor = offer
		.session
		.spawn_owned(direct::receiver(move |notice, session| {
			let Notice::Message {
				text,
				previews,
				attachments: files,
				..
			} = notice
			else {
				return Err("fixture expects a message".into());
			};
			let line = receiver
				.post_with_previews(context.clone(), &session, text, previews, files)
				.map_err(rooms_runtime::Error::into_refusal)?;
			if delayed.replace(false) {
				tx.try_send((session.host().defer_turn().unwrap(), line)).unwrap();
				Ok(Argument::Void)
			} else {
				Ok(line.into())
			}
		}))
		.unwrap();
	offer
		.session
		.send(&offer.inbox, rooms_application::direct::READY, &[actor.clone().into()])
		.await
		.unwrap();
	Remote {
		owner,
		events,
		delay,
		answers,
		_actor: actor,
	}
}

#[tokio::test]
async fn outgoing_files_edits_recording_and_withdrawal_have_one_local_materialization() {
	deadline(async {
		let mut fixture = Fixture::new("outgoing-files").await;
		let (archive, archive_worker) = crate::session_archive::SessionArchive::new(
			rooms_platform::HostPlatform,
			fixture.transport.clone(),
			crate::archive::file::FileArchive::open(fixture._temp.0.join("archive"), Default::default())
				.await
				.unwrap(),
		);
		let archive = Rc::new(archive);
		let archive_task = tokio::task::spawn_local(archive_worker.run());
		(fixture.lines, fixture.events) = DirectEvents::with_recorder(
			rooms_platform::HostPlatform,
			&mut rooms_platform::OsEntropy,
			archive.clone(),
			"sender".into(),
		)
		.unwrap();
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let dispatcher = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let first = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let mut peer = remote(&offer, &first).await;
		fixture.other_arrival.notify("mintInboxFor").await;
		let second = published(&mut outcomes).await;
		let other_offer = fixture.other.offers.recv().await.unwrap();
		let mut other = remote(&other_offer, &second).await;
		let sources = Rc::new(Sources::new(HostPlatform));
		let (outgoing, worker) = DirectOutgoing::new(
			rooms_platform::HostPlatform,
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		let task = tokio::task::spawn_local(worker.run());
		let reads = Rc::new(Cell::new(0));
		let previews = rooms_application::open_graph::Selection::all("caption https://example.com");
		let sent = outgoing
			.send_with_previews(
				&first,
				"caption https://example.com",
				previews.clone(),
				vec![source("first", 1, &reads), source("second", 2, &reads)],
			)
			.unwrap()
			.wait()
			.await
			.unwrap();
		assert!(sent.editable);
		let event = fixture.events.next().await.unwrap();
		assert_eq!(
			(event.direction, event.from.as_str(), event.editable),
			(Direction::Outgoing, "alice", true)
		);
		assert_eq!(event.line().unwrap().line, sent.line);
		assert_eq!(event.line().unwrap().previews, previews);
		let old = event.files.clone();
		let recording = event.recording.unwrap().unwrap();
		recording.completion.wait().await.unwrap();
		let received = peer.events.next().await.unwrap();
		assert_eq!(received.line().unwrap().previews, previews);
		for (index, file) in received.files.iter().enumerate() {
			assert_eq!(file.read(0, 3).await.unwrap(), vec![1 + index as u8; 3]);
		}
		assert_eq!(old[0].read(0, 3).await.unwrap(), [1; 3]);
		assert_eq!(
			reads.get(),
			2,
			"local view, remote grant and recording share each source capture"
		);
		let rows = archive.read(Default::default()).unwrap().wait().await.unwrap();
		assert_eq!(rows.len(), 1);
		assert!(matches!(
			rows[0].record.body(),
			rooms_application::archive::Body::Line { mine: true, .. }
		));
		assert_eq!(
			rows[0].blob(0).await.unwrap().unwrap().read(0, 3).await.unwrap(),
			[1; 3]
		);
		drop(rows);
		assert!(outgoing.edit(&second, sent.line, "wrong conversation").is_err());
		assert!(
			outgoing
				.refile(
					&first,
					sent.line,
					"duplicate",
					&[0, 0],
					vec![source("unused", 9, &reads)]
				)
				.is_err()
		);
		assert_eq!(reads.get(), 2, "invalid selection starts no source");
		outgoing
			.edit(&first, sent.line, "edited https://example.com")
			.unwrap()
			.wait()
			.await
			.unwrap();
		let remote_edit = peer.events.next().await.unwrap();
		assert_eq!(remote_edit.line().unwrap().kind, ChangeKind::Edited);
		assert_eq!(remote_edit.line().unwrap().previews, previews);
		let edit = fixture.events.next().await.unwrap();
		assert_eq!(edit.line().unwrap().previews, previews);
		assert_eq!(edit.files.len(), 2);
		edit.recording.unwrap().unwrap().completion.wait().await.unwrap();
		outgoing
			.refile(&first, sent.line, "replacement", &[1], vec![source("third", 3, &reads)])
			.unwrap()
			.wait()
			.await
			.unwrap();
		let refile = fixture.events.next().await.unwrap();
		assert!(refile.line().unwrap().previews.is_empty());
		let kept = refile.files.clone();
		refile.recording.unwrap().unwrap().completion.wait().await.unwrap();
		assert!(old[0].read(0, 3).await.is_err());
		assert_eq!(old[1].read(0, 3).await.unwrap(), [2; 3]);
		let changed = peer.events.next().await.unwrap();
		assert!(changed.line().unwrap().previews.is_empty());
		assert_eq!(changed.files[1].read(0, 3).await.unwrap(), [3; 3]);
		assert_eq!(reads.get(), 3);
		let pinned = kept[1].materialize();
		outgoing.withdraw(&first, sent.line).unwrap().wait().await.unwrap();
		let gone = fixture.events.next().await.unwrap();
		assert!(!gone.editable && gone.files.is_empty());
		gone.recording.unwrap().unwrap().completion.wait().await.unwrap();
		assert_eq!(
			peer.events.next().await.unwrap().line().unwrap().kind,
			ChangeKind::Withdrawn
		);
		assert!(kept[1].read(0, 3).await.is_err());
		assert_eq!(pinned.await.unwrap().read(0, 3).unwrap(), [3; 3]);
		assert!(outgoing.edit(&first, sent.line, "retired").is_err());
		let pressure_line = outgoing
			.send(&first, "evictable preview", vec![source("evicted", 4, &reads)])
			.unwrap()
			.wait()
			.await
			.unwrap();
		let initial = fixture.events.next().await.unwrap();
		let expired = initial.files[0].clone();
		initial.recording.unwrap().unwrap().completion.wait().await.unwrap();
		peer.events.next().await.unwrap().files[0].read(0, 3).await.unwrap();
		for _ in 0..16 {
			let empty = (0..8)
				.map(|_| {
					Source::bytes(
						FileDescription::new("empty".into(), "text/plain".into(), 0, 0, 0).unwrap(),
						Vec::new(),
					)
					.unwrap()
				})
				.collect();
			outgoing.send(&first, "pressure", empty).unwrap().wait().await.unwrap();
			fixture
				.events
				.next()
				.await
				.unwrap()
				.recording
				.unwrap()
				.unwrap()
				.completion
				.wait()
				.await
				.unwrap();
			let received = peer.events.next().await.unwrap();
			for file in received.files {
				file.materialize().await.unwrap();
			}
		}
		assert!(expired.read(0, 3).await.is_err());
		for refile in [false, true] {
			let changed = if refile {
				outgoing.refile(&first, pressure_line.line, "keep expired", &[0], vec![])
			} else {
				outgoing.edit(&first, pressure_line.line, "caption after eviction")
			};
			changed.unwrap().wait().await.unwrap();
			let event = fixture.events.next().await.unwrap();
			assert_eq!(event.files.len(), 1);
			assert!(event.files[0].read(0, 3).await.is_err());
			// The change is archived; the evicted file is named without bytes.
			let FileRecording::MetadataOnly(MetadataReason::SourceFailed(reason)) =
				event.recording.unwrap().unwrap().completion.wait().await.unwrap().files
			else {
				panic!("an evicted file leaves a metadata-only recording");
			};
			assert!(reason.contains("no longer retained"), "{reason}");
			assert_eq!(peer.events.next().await.unwrap().files.len(), 1);
		}

		outgoing
			.send(&second, "independent", vec![])
			.unwrap()
			.wait()
			.await
			.unwrap();
		assert_eq!(other.events.next().await.unwrap().line().unwrap().text, "independent");
		fixture
			.events
			.next()
			.await
			.unwrap()
			.recording
			.unwrap()
			.unwrap()
			.completion
			.wait()
			.await
			.unwrap();
		outgoing.close().await.unwrap();
		task.await.unwrap().unwrap();
		peer.owner.close_files().await.unwrap();
		other.owner.close_files().await.unwrap();
		dispatch.close().await.unwrap();
		dispatcher.await.unwrap().unwrap();
		archive.close().await.unwrap();
		assert_eq!(archive_task.await.unwrap().cleanup_failures, 0);
		drop((peer, other, offer, other_offer, outgoing, sources));
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn outgoing_abandonment_backpressure_and_uncertain_shutdown_are_observable() {
	deadline(async {
		let mut fixture = Fixture::new("outgoing-lifecycle").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let dispatcher = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let first = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let mut peer = remote(&offer, &first).await;
		fixture.other_arrival.notify("mintInboxFor").await;
		let second = published(&mut outcomes).await;
		let other_offer = fixture.other.offers.recv().await.unwrap();
		let mut other = remote(&other_offer, &second).await;
		let sources = Rc::new(Sources::new(HostPlatform));
		let (outgoing, worker) = DirectOutgoing::new(
			rooms_platform::HostPlatform,
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		let task = tokio::task::spawn_local(worker.run());
		for _ in 0..EVENT_LIMIT {
			fixture.lines.receiver().typing(first.clone(), true).unwrap();
		}
		assert!(outgoing.send(&first, "queue full", vec![]).is_err());
		for _ in 0..EVENT_LIMIT {
			drop(fixture.events.next().await.unwrap());
		}
		peer.delay.set(true);
		drop(outgoing.send(&first, "abandoned observation", vec![]).unwrap());
		let (mut answer, line) = peer.answers.recv().await.unwrap();
		assert!(outgoing.send(&first, "serialized", vec![]).is_err());
		outgoing
			.send(&second, "other progresses", vec![])
			.unwrap()
			.wait()
			.await
			.unwrap();
		assert_eq!(
			fixture.events.next().await.unwrap().line().unwrap().text,
			"other progresses"
		);
		assert_eq!(
			other.events.next().await.unwrap().line().unwrap().text,
			"other progresses"
		);
		answer.fulfill_value(&line.into()).unwrap();
		assert_eq!(
			fixture.events.next().await.unwrap().line().unwrap().text,
			"abandoned observation"
		);
		assert_eq!(
			peer.events.next().await.unwrap().line().unwrap().text,
			"abandoned observation"
		);
		let mut completed = Vec::new();
		for _ in 0..crate::session_runtime::direct_outgoing::OPERATION_LIMIT {
			completed.push(outgoing.send(&second, "retained receipt", vec![]).unwrap());
			drop(fixture.events.next().await.unwrap());
			drop(other.events.next().await.unwrap());
		}
		assert!(outgoing.send(&second, "over budget", vec![]).is_err());
		completed.pop().unwrap().wait().await.unwrap();
		outgoing
			.send(&second, "credit restored", vec![])
			.unwrap()
			.wait()
			.await
			.unwrap();
		drop(fixture.events.next().await.unwrap());
		drop(other.events.next().await.unwrap());
		drop(completed);
		peer.delay.set(true);
		let late = outgoing.send(&first, "retired before ack", vec![]).unwrap();
		let (mut answer, line) = peer.answers.recv().await.unwrap();
		command(
			&fixture.commands,
			"close-outgoing",
			Command::CloseDirect,
			vec![first.conversation().text().clone()],
		)
		.await;
		answer.fulfill_value(&line.into()).unwrap();
		assert_eq!(late.wait().await.unwrap_err().delivery, Delivery::Accepted);
		assert!(
			Box::pin(fixture.events.next())
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		other.delay.set(true);
		let pending = outgoing.send(&second, "uncertain", vec![]).unwrap();
		let (mut answer, line) = other.answers.recv().await.unwrap();
		outgoing.close().await.unwrap();
		task.await.unwrap().unwrap();
		assert_eq!(pending.wait().await.unwrap_err().delivery, Delivery::Uncertain);
		answer.fulfill_value(&line.into()).unwrap();
		let (queued, worker) = DirectOutgoing::new(
			rooms_platform::HostPlatform,
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		let not_sent = queued.send(&second, "never started", vec![]).unwrap();
		drop(worker);
		assert_eq!(not_sent.wait().await.unwrap_err().delivery, Delivery::NotSent);
		assert!(
			queued
				.close()
				.await
				.unwrap_err()
				.to_string()
				.contains("without completing shutdown")
		);
		peer.owner.close_files().await.unwrap();
		other.owner.close_files().await.unwrap();
		dispatch.close().await.unwrap();
		dispatcher.await.unwrap().unwrap();
		drop((peer, other, offer, other_offer, queued, outgoing, sources));
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn uncertain_mutation_preserves_only_safe_withdrawal_and_preflight_failures_send_nothing() {
	deadline(async {
		let mut fixture = Fixture::new("outgoing-refusal").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let dispatcher = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let context = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let calls = Rc::new(Cell::new(0));
		let changes = calls.clone();
		let line = offer
			.session
			.spawn_owned(move |verb, _| {
				changes.set(changes.get() + 1);
				match verb {
					"edit" => Err("fixture lost mutation outcome".into()),
					"withdraw" => Ok(Argument::Void),
					_ => panic!("unsafe mutation reached peer"),
				}
			})
			.unwrap();
		let posted = line.clone();
		let messages = Rc::new(Cell::new(0));
		let received = messages.clone();
		let target = offer
			.session
			.spawn_owned(move |verb, _| {
				assert_eq!(verb, rooms_application::direct::DM);
				received.set(received.get() + 1);
				Ok(posted.clone().into())
			})
			.unwrap();
		offer
			.session
			.send(&offer.inbox, rooms_application::direct::READY, &[target.clone().into()])
			.await
			.unwrap();
		let sources = Rc::new(Sources::new(HostPlatform));
		let (outgoing, worker) = DirectOutgoing::new(
			rooms_platform::HostPlatform,
			fixture.routes.receiver(),
			fixture.lines.receiver(),
			sources.clone(),
		);
		let task = tokio::task::spawn_local(worker.run());
		struct Broken;
		impl Reader for Broken {
			fn read(&self, _: usize, _: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, String>>>> {
				Box::pin(async { Err("local source unavailable".into()) })
			}
		}
		let failed = outgoing
			.send(
				&context,
				"bad source",
				vec![Source::reader(
					FileDescription::new("broken".into(), "text/plain".into(), 1, 0, 0).unwrap(),
					Broken,
				)],
			)
			.unwrap()
			.wait()
			.await
			.unwrap_err();
		assert_eq!(failed.delivery, Delivery::NotSent);
		assert_eq!(messages.get(), 0);
		let sent = outgoing.send(&context, "posted", vec![]).unwrap().wait().await.unwrap();
		drop(fixture.events.next().await.unwrap());
		let changed = outgoing
			.edit(&context, sent.line, "unknown")
			.unwrap()
			.wait()
			.await
			.unwrap_err();
		assert_eq!(changed.delivery, Delivery::Uncertain);
		assert_eq!(calls.get(), 1);
		assert!(outgoing.edit(&context, sent.line, "unsafe retry").is_err());
		assert!(
			outgoing
				.refile(&context, sent.line, "unknown selection", &[], vec![])
				.is_err()
		);
		outgoing.withdraw(&context, sent.line).unwrap().wait().await.unwrap();
		assert_eq!(
			calls.get(),
			2,
			"actual delegated authority remains available for withdrawal"
		);
		assert_eq!(
			fixture.events.next().await.unwrap().line().unwrap().kind,
			ChangeKind::Withdrawn
		);
		outgoing.close().await.unwrap();
		task.await.unwrap().unwrap();
		dispatch.close().await.unwrap();
		dispatcher.await.unwrap().unwrap();
		drop((target, line, offer, outgoing, sources));
		fixture.close().await;
	})
	.await;
}

#[path = "direct_commands.rs"]
mod direct_commands;
