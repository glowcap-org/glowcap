//! Event time governs files even before the host delivers an idle timer.
use super::*;
use crate::files::{FileDescription, ReadOutcome, UPLOAD_IDLE_MS};

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
