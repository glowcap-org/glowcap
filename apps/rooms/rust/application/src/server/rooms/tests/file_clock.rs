//! Event time governs files even before the host delivers an idle timer.
use super::*;
use crate::files::{FileDescription, ReadOutcome, UPLOAD_IDLE_MS};

#[test]
fn failed_adapter_publication_releases_only_its_reservation_without_a_timer() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	let before = world.rooms.files().usage();
	let make = |name| FileDescription::parse(name, "", 3, 0, 0).unwrap();
	let kept = world.rooms.attach(&entrance.room, alice, make("kept"), 0).unwrap();
	let failed = world
		.rooms
		.attach(&entrance.room, alice, make("unpublished"), 0)
		.unwrap();
	let failed_blob = world.rooms.upload_blob(failed).unwrap();
	world.rooms.cancel_upload(failed, 0).unwrap();
	assert!(world.rooms.upload_blob(failed).is_none());
	assert!(!world.rooms.files().contains(&failed_blob));
	let usage = world.rooms.files().usage();
	assert_eq!(usage.pending_files, before.pending_files + 1);
	assert_eq!(usage.pending_bytes, before.pending_bytes + 3);
	let (_, mutation) = world.rooms.post_files(&entrance.room, alice, "", 1, 0).unwrap();
	assert!(
		matches!(&mutation.effects.tells[0].notice, Notice::Line { files, .. } if files.len() == 1 && files[0].description().name() == "kept")
	);
	world
		.rooms
		.upload_verb(kept, "write", &[Value::Bytes(&[1, 2, 3])], 0)
		.unwrap();
}

#[test]
fn uploads_start_and_renew_from_event_time_after_a_quiet_server() {
	let mut world = World::new(true);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	let start = 10 * UPLOAD_IDLE_MS;
	let description = FileDescription::parse("slow.bin", "", 3, 0, 0).unwrap();
	let upload = world.rooms.attach(&entrance.room, alice, description, start).unwrap();
	assert_eq!(world.rooms.next_upload_deadline(), Some(start + UPLOAD_IDLE_MS));
	let (_, posted) = world.rooms.post_files(&entrance.room, alice, "", 123, start).unwrap();
	assert_eq!(
		world.rooms.history(&entrance.room, alice).unwrap().next().unwrap().at,
		123
	);
	let blob = match &posted.effects.tells[0].notice {
		Notice::Line { files, .. } => files[0].clone(),
		_ => panic!("a file line"),
	};
	let write_at = start + UPLOAD_IDLE_MS - 1;
	world
		.rooms
		.upload_verb(upload, "write", &[Value::Bytes(&[1])], write_at)
		.unwrap();
	assert_eq!(world.rooms.next_upload_deadline(), Some(write_at + UPLOAD_IDLE_MS));
	// The original deadline is now harmless: successful progress renewed it.
	world.rooms.advance(start + UPLOAD_IDLE_MS);
	match world
		.rooms
		.blob_verb(
			&blob,
			"read",
			&[Value::Natural(0), Value::Natural(1)],
			start + UPLOAD_IDLE_MS,
		)
		.unwrap()
	{
		ReadOutcome::Ready(bytes) => assert_eq!(bytes, &[1]),
		ReadOutcome::Waiting(_) => panic!("written bytes must be ready"),
	}
	// Timer delivery may be delayed. A write at expiry must still be refused,
	// and must never revive the old upload with a newly renewed deadline.
	assert!(
		world
			.rooms
			.upload_verb(upload, "write", &[Value::Bytes(&[2])], write_at + UPLOAD_IDLE_MS)
			.is_err()
	);
	assert!(
		world
			.rooms
			.blob_verb(
				&blob,
				"read",
				&[Value::Natural(0), Value::Natural(1)],
				write_at + UPLOAD_IDLE_MS
			)
			.is_err()
	);
}

#[test]
fn posting_cannot_publish_a_reservation_that_expired_before_timer_delivery() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	let description = FileDescription::parse("late.bin", "", 3, 0, 0).unwrap();
	world.rooms.attach(&entrance.room, alice, description, 7).unwrap();
	assert!(
		world
			.rooms
			.post_files(&entrance.room, alice, "", 123, 7 + UPLOAD_IDLE_MS)
			.is_err()
	);
}
