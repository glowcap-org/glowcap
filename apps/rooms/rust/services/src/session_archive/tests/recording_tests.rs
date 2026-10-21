use super::*;
use rooms_application::{
	archive::{Kind, recording::Message},
	room::message::{ChangeKind, LineId},
};
use std::{
	future::Future,
	task::{Context, Waker},
};

pub(super) fn admit(owner: &SessionArchive, conversation: &str, kind: ConversationKind, id: u64) -> Recording {
	let source = "source".into();
	let generation = "generation".into();
	let directory = "directory".into();
	let conversation = conversation.into();
	owner
		.record_message(
			&source,
			&Message {
				keep: true,
				generation: Some(&generation),
				kind,
				directory: &directory,
				conversation: &conversation,
				nick: "alice",
				from: "bob",
				text: "kept",
				previews: &Default::default(),
				system: false,
				line: LineId::new(id),
				change: ChangeKind::Said,
				at: 123,
			},
			Vec::new(),
		)
		.unwrap()
		.unwrap()
}

#[tokio::test]
async fn recording_distinguishes_failed_lines_partial_standing_and_successful_retry() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let runtime = runtime().await;
			let backend = Memory::new();
			let failures = backend.put_fails.clone();
			let attempts = backend.attempts.clone();
			let index = backend.index.clone();
			let (owner, worker) = SessionArchive::new(rooms_platform::HostPlatform, runtime.clone(), backend);
			let worker = tokio::task::spawn_local(worker.run());
			failures.set(Some(Kind::Line));
			let refused = admit(&owner, "garden", ConversationKind::Room, 1);
			assert_eq!(refused.coordinates.id.as_str(), Some("1"));
			assert!(refused.completion.wait().await.is_err());
			assert_eq!(index.borrow().revision(), 0);
			assert_eq!(*attempts.borrow(), [Kind::Line]);
			failures.set(Some(Kind::Standing));
			let partial = admit(&owner, "garden", ConversationKind::Room, 1)
				.completion
				.wait()
				.await
				.unwrap();
			assert_eq!(partial.revision, 1);
			assert!(partial.standing.is_err());
			assert_eq!(*attempts.borrow(), [Kind::Line, Kind::Line, Kind::Standing]);
			failures.set(None);
			let retried = admit(&owner, "garden", ConversationKind::Room, 1)
				.completion
				.wait()
				.await
				.unwrap();
			assert_eq!(retried.revision, 2);
			assert_eq!(retried.standing.unwrap(), Some(3));
			let repeated = admit(&owner, "garden", ConversationKind::Room, 2)
				.completion
				.wait()
				.await
				.unwrap();
			assert_eq!(repeated.revision, 4);
			assert_eq!(repeated.standing.unwrap(), None);
			let direct = admit(&owner, "garden", ConversationKind::Direct, 1)
				.completion
				.wait()
				.await
				.unwrap();
			assert_eq!(direct.revision, 5);
			assert_eq!(direct.standing.unwrap(), None);
			failures.set(Some(Kind::Standing));
			drop(admit(&owner, "orchard", ConversationKind::Room, 3));
			let report = owner.close().await.unwrap();
			assert_eq!(report.refused, 1);
			assert_eq!(report.completed, 5);
			assert_eq!(report.partial_recordings, 2);
			assert_eq!(report.lost_replies, 1);
			assert_eq!(index.borrow().revision(), 6);
			assert_eq!(worker.await.unwrap(), report);
			runtime.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn erasure_waits_for_the_whole_recording_and_resets_successful_standing() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let runtime = runtime().await;
			let backend = Memory::new();
			let blocked = backend.blocked.clone();
			let started = backend.started.clone();
			let gate = backend.gate.clone();
			let attempts = backend.attempts.clone();
			let index = backend.index.clone();
			blocked.set(true);
			let (owner, worker) = SessionArchive::new(rooms_platform::HostPlatform, runtime.clone(), backend);
			let worker = tokio::task::spawn_local(worker.run());
			let first = admit(&owner, "garden", ConversationKind::Room, 1);
			started.notified().await;
			let source = "source".into();
			let mut erase = Box::pin(owner.clear_source_when_ready(&source));
			assert!(
				erase
					.as_mut()
					.poll(&mut Context::from_waker(Waker::noop()))
					.is_pending()
			);
			let after = admit(&owner, "garden", ConversationKind::Room, 2);
			assert_eq!(*attempts.borrow(), [Kind::Line]);
			blocked.set(false);
			gate.notify_one();
			assert_eq!(first.completion.wait().await.unwrap().standing.unwrap(), Some(2));
			erase.await.unwrap();
			let after = after.completion.wait().await.unwrap();
			assert_eq!(after.revision, 3);
			assert_eq!(after.standing.unwrap(), Some(4));
			assert_eq!(
				*attempts.borrow(),
				[Kind::Line, Kind::Standing, Kind::Line, Kind::Standing]
			);
			assert_eq!(
				index.borrow().read(&Filter::default(), 0, 128).unwrap().records.len(),
				2
			);
			let report = owner.close().await.unwrap();
			assert_eq!(report.completed, 3);
			assert_eq!(report.partial_recordings, 0);
			assert_eq!(worker.await.unwrap(), report);
			runtime.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn admission_charges_unused_source_capacity_but_withdrawal_releases_it() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let runtime = runtime().await;
			let (owner, worker) = SessionArchive::new(rooms_platform::HostPlatform, runtime.clone(), Memory::new());
			let excess = MAX_BYTES / core::mem::size_of::<File<HostPlatform>>() + 1;
			assert!(owner.put(line(LineState::Present), Vec::with_capacity(excess)).is_err());
			let previews = Default::default();
			let mut input = Message {
				keep: true,
				generation: Some(&"generation".into()),
				kind: ConversationKind::Room,
				directory: &"directory".into(),
				conversation: &"garden".into(),
				nick: "alice",
				from: "bob",
				text: "",
				previews: &previews,
				system: false,
				line: LineId::new(1),
				change: ChangeKind::Withdrawn,
				at: 123,
			};
			let recording = owner
				.record_message(&"source".into(), &input, Vec::with_capacity(excess))
				.unwrap()
				.unwrap();
			let held = owner.usage();
			assert_eq!(owner.usage().requests, 1);
			assert_eq!(held.files, 0);
			assert!(held.bytes < 1024);
			input.keep = false;
			assert!(
				owner
					.record_message(&"source".into(), &input, vec![])
					.unwrap()
					.is_none()
			);
			assert_eq!(owner.usage().requests, 1);
			let worker = tokio::task::spawn_local(worker.run());
			recording.completion.wait().await.unwrap().standing.unwrap();
			let report = owner.close().await.unwrap();
			assert_eq!(report.completed, 1);
			assert_eq!(worker.await.unwrap(), report);
			runtime.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
