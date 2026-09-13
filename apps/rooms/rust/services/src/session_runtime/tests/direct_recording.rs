use super::*;
use crate::{
	archive::file::{FileArchive, Options},
	session_archive::{FileRecording, SessionArchive},
};
use rooms_application::archive::{Body, Filter, LineState};
use std::cell::Cell;

#[tokio::test]
async fn direct_recording_precedes_consumer_delay_and_preserves_message_delivery_on_refusal() {
	deadline(async {
		let mut fixture = Fixture::new("direct-recording").await;
		let (archive, worker) = SessionArchive::new(
			rooms_platform::HostPlatform,
			fixture.transport.clone(),
			FileArchive::open(fixture._temp.0.join("archive"), Options::default())
				.await
				.unwrap(),
		);
		let archive = Rc::new(archive);
		(fixture.lines, fixture.events) = DirectEvents::with_recorder(
			rooms_platform::HostPlatform,
			&mut rooms_platform::OsEntropy,
			archive.clone(),
			"recorder".into(),
		)
		.unwrap();
		let (dispatch, dispatcher, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(dispatcher.run());
		fixture.arrival.notify("mintInboxFor").await;
		let first = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		fixture.other_arrival.notify("mintInboxFor").await;
		let second = published(&mut outcomes).await;
		let other = fixture.other.offers.recv().await.unwrap();
		let called = Rc::new(tokio::sync::Notify::new());
		let read = called.clone();
		let live = Rc::new(Cell::new(true));
		let active = live.clone();
		let blob = offer
			.session
			.spawn_owned(move |verb, _| {
				if verb != "read" || !active.replace(false) {
					return Err("source retired".into());
				}
				read.notify_one();
				Ok(Argument::Bytes(vec![1, 2, 3]))
			})
			.unwrap();
		let Argument::Reference(line) = offer
			.session
			.send(
				&offer.inbox,
				"dm",
				&[
					"file".into(),
					"file".into(),
					"one".into(),
					"text/plain".into(),
					3.into(),
					blob.clone().into(),
					0.into(),
					0.into(),
				],
			)
			.await
			.unwrap()
		else {
			panic!("direct line")
		};
		// Neither storage nor the event consumer is running. Admission must have
		// started capture on the actual incoming capability already.
		if tokio::time::timeout(Duration::from_secs(5), called.notified())
			.await
			.is_err()
		{
			let event = fixture.events.next().await.unwrap();
			panic!(
				"capture did not start: files={}, admission={:?}",
				event.line().unwrap().files.len(),
				event.recording.err()
			);
		}
		other
			.session
			.send(&other.inbox, "dm", &["sibling".into()])
			.await
			.unwrap();
		command(
			&fixture.commands,
			"disable",
			Command::ChooseHistoryRetention,
			vec!["false".into()],
		)
		.await;
		offer
			.session
			.send(&offer.inbox, "dm", &["not retained".into()])
			.await
			.unwrap();
		let archive_task = tokio::task::spawn_local(worker.run());
		let first_event = fixture.events.next().await.unwrap();
		let at = first_event.at;
		let view = first_event.files[0].clone();
		assert_eq!(view.read(0, 3).await.unwrap(), [1, 2, 3]);
		let recording = first_event.recording.unwrap().unwrap();
		let coordinates = recording.coordinates;
		assert_eq!(recording.completion.wait().await.unwrap().files, FileRecording::Stored);
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
		assert!(fixture.events.next().await.unwrap().recording.unwrap().is_none());
		let rows = archive.read(Filter::default()).unwrap().wait().await.unwrap();
		assert_eq!(rows.len(), 2);
		let kept = rows
			.iter()
			.find(|row| row.record.coordinates() == &coordinates)
			.unwrap();
		assert_eq!(kept.record.directory(), first.directory().text());
		assert_eq!(kept.record.conversation(), first.conversation().text());
		assert!(
			matches!(kept.record.body(), Body::Line { at: time, mine: false, state: LineState::Present, .. } if *time == at)
		);
		assert_eq!(
			kept.blob(0).await.unwrap().unwrap().read(0, 3).await.unwrap(),
			[1, 2, 3]
		);
		assert!(
			rows.iter()
				.any(|row| row.record.directory() == second.directory().text())
		);
		drop(rows);
		// Retention is sampled again for subsequent delegated changes. Withdrawal
		// needs no live file authority and preserves the original coordinates.
		command(
			&fixture.commands,
			"enable",
			Command::ChooseHistoryRetention,
			vec!["true".into()],
		)
		.await;
		for (verb, args) in [
			("edit", vec!["edited caption".into()]),
			("refile", vec!["retained file".into(), 0.into()]),
		] {
			offer.session.send(&line, verb, &args).await.unwrap();
			let event = fixture.events.next().await.unwrap();
			assert_eq!(event.files[0].read(0, 3).await.unwrap(), [1, 2, 3]);
			if verb == "edit" {
				assert!(event.line().unwrap().files.is_empty());
			}
			let edited = event.recording.unwrap().unwrap();
			assert_eq!(edited.coordinates, coordinates);
			assert_eq!(edited.completion.wait().await.unwrap().files, FileRecording::Stored);
		}
		let edited = archive.read(Filter::default()).unwrap().wait().await.unwrap();
		assert!(edited.iter().any(|row| row.record.coordinates() == &coordinates
			&& matches!(row.record.body(), Body::Line { state: LineState::Edited, attachments, .. } if attachments.len() == 1)));
		drop(edited);
		live.set(false);
		offer.session.send(&line, "withdraw", &[]).await.unwrap();
		let withdrawn = fixture.events.next().await.unwrap().recording.unwrap().unwrap();
		assert_eq!(withdrawn.coordinates, coordinates);
		withdrawn.completion.wait().await.unwrap();
		assert!(view.read(0, 3).await.is_err(), "withdrawal expires unpinned views");
		let rows = archive.read(Filter::default()).unwrap().wait().await.unwrap();
		assert!(rows.iter().any(|row| row.record.coordinates() == &coordinates &&
			matches!(row.record.body(), Body::Line { state: LineState::Withdrawn, attachments, .. } if attachments.is_empty())));
		drop(rows);
		offer.typing().await.unwrap();
		assert!(fixture.events.next().await.unwrap().recording.unwrap().is_none());
		archive.close().await.unwrap();
		archive_task.await.unwrap();
		offer
			.session
			.send(&offer.inbox, "dm", &["still delivered".into()])
			.await
			.unwrap();
		let event = fixture.events.next().await.unwrap();
		assert_eq!(event.line().unwrap().text, "still delivered");
		assert!(matches!(
			event.recording.err().unwrap(),
			rooms_runtime::Error::Closed(_)
		));
		let context_client = fixture.runtime.direct_directory(&first).unwrap().client().clone();
		let exporter_client = fixture.runtime.direct_directory(&second).unwrap().client().clone();
		let exported = other
			.session
			.publish("retained-file", |verb, _| {
				if verb != "read" {
					return Err("file method".into());
				}
				Ok(Argument::Bytes(vec![7]))
			})
			.unwrap();
		let reference = exporter_client.session().fetch("retained-file").await.unwrap();
		let file = rooms_glowcap::client::files::File::received(
			context_client.clone(),
			rooms_application::room::attachment::Attachment {
				description: rooms_application::files::FileDescription::new(
					"exporter".into(),
					"text/plain".into(),
					1,
					0,
					0,
				)
				.unwrap(),
				blob: reference.clone(),
			},
		);
		// Resolve on the first read, after the contextual connection has closed.
		// The token names a sibling exporter in this Host, which remains usable.
		context_client.session().close(PendingWork::Cancel).await.unwrap();
		assert_eq!(file.read(0, 1).await.unwrap(), [7]);
		drop(file);
		assert_eq!(
			exporter_client
				.session()
				.send(&reference, "read", &[0.into(), 1.into()])
				.await
				.unwrap()
				.as_bytes(),
			Some([7].as_slice())
		);
		other.session.release(exported).unwrap();
		drop((context_client, exporter_client, reference));
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		drop((offer, other, line, blob, archive));
		fixture.close().await;
	})
	.await;
}
