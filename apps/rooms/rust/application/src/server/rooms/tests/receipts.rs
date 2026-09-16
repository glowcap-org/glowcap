//! Receipt delivery changes one subscriber's representation, never authority.
use super::*;
use crate::room::receipt;
use alloc::string::String;

#[derive(Debug, PartialEq)]
enum Encoded {
	Text(String),
	Integer(u64),
	Boolean(bool),
}
struct Encoder;
impl wire::DataEncoder for Encoder {
	type Value = Encoded;
	fn text(&mut self, value: String) -> Encoded {
		Encoded::Text(value)
	}
	fn integer(&mut self, value: u64) -> Encoded {
		Encoded::Integer(value)
	}
	fn boolean(&mut self, value: bool) -> Encoded {
		Encoded::Boolean(value)
	}
}
impl wire::Encoder for Encoder {
	type Error = core::convert::Infallible;
	fn blob(&mut self, _: &crate::files::Blob) -> Result<Encoded, Self::Error> {
		panic!("text receipt has no file")
	}
}

#[test]
fn rejected_delivery_releases_only_the_calling_subscribers_request() {
	let mut world = World::new(true);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	world.join(2, &entrance, "Bob");
	let effects = world
		.rooms
		.reject_delivery(&entrance.room, alice, Delivery { caller: 1, request: 7 });
	assert_eq!(effects.tells.len(), 1);
	let heard = notices(&effects, 1);
	assert_eq!(wire::verb(heard[0]), receipt::REJECTED);
	assert_eq!(
		wire::arguments(heard[0], &mut Encoder).unwrap(),
		vec![Encoded::Integer(7)]
	);
	assert!(
		world
			.rooms
			.reject_delivery(&entrance.room, alice, Delivery { caller: 2, request: 7 })
			.tells
			.is_empty()
	);
}

#[test]
fn receipts_omit_text_only_for_the_subscriber_that_retained_it() {
	let mut world = World::new(true);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	world.join(2, &entrance, "Bob");
	for size in [0, 1, 16, 256, 8192] {
		for request in [0, receipt::MAX_REQUEST] {
			let text = "x".repeat(size);
			let (_, mutation) = world
				.rooms
				.post_delivered(
					&entrance.room,
					alice,
					&text,
					Default::default(),
					1,
					Some(Delivery { caller: 1, request }),
				)
				.unwrap();
			let heard = notices(&mutation.effects, 1);
			assert_eq!(heard.len(), 1);
			assert_eq!(wire::verb(heard[0]), receipt::TAG);
			let Notice::Receipt { id, .. } = heard[0] else {
				panic!("sender receipt")
			};
			assert_eq!(
				wire::arguments(heard[0], &mut Encoder).unwrap(),
				vec![
					Encoded::Integer(request),
					Encoded::Integer(id.get()),
					Encoded::Text("Alice".into()),
					Encoded::Boolean(false),
					Encoded::Boolean(false)
				]
			);
			assert!(matches!(notices(&mutation.effects, 2)[0], Notice::Line { line, .. } if line.text == text));
		}
	}
	for delivery in [None, Some(Delivery { caller: 2, request: 7 })] {
		let (_, mutation) = world
			.rooms
			.post_delivered(&entrance.room, alice, "delegated", Default::default(), 2, delivery)
			.unwrap();
		for connection in [1, 2] {
			assert!(
				matches!(notices(&mutation.effects, connection)[0], Notice::Line { line, .. } if line.from == "Alice" && line.text == "delegated")
			);
		}
	}
}

#[test]
fn a_receipted_line_keeps_delegated_edit_and_withdraw_broadcasts() {
	let mut world = World::new(true);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	world.join(2, &entrance, "Bob");
	let (line, _) = world
		.rooms
		.post_delivered(
			&entrance.room,
			alice,
			"original",
			Default::default(),
			1,
			Some(Delivery { caller: 1, request: 0 }),
		)
		.unwrap();
	for (verb, args, expected) in [
		("edit", vec![Value::Text("changed")], ChangeKind::Edited),
		("withdraw", vec![], ChangeKind::Withdrawn),
	] {
		let mutation = world.rooms.line_verb(2, line, verb, &args, 0).unwrap();
		for connection in [1, 2] {
			assert!(
				matches!(notices(&mutation.effects, connection)[0], Notice::Line { marker: Some((kind, _)), .. } if *kind == expected)
			);
		}
	}
}

#[test]
fn file_receipts_carry_the_rooms_normalized_caption() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	world.join(2, &entrance, "Bob");
	for (caption, normalized, expected) in [("", true, "picture.png"), ("caption", false, "caption")] {
		let description = crate::files::FileDescription::parse("picture.png", "image/png", 3, 2, 2).unwrap();
		world.rooms.attach(&entrance.room, alice, description, 0).unwrap();
		let (_, mutation) = world
			.rooms
			.post_files_delivered(
				&entrance.room,
				alice,
				caption,
				Default::default(),
				1,
				0,
				Some(Delivery { caller: 1, request: 1 }),
			)
			.unwrap();
		assert!(
			matches!(notices(&mutation.effects, 1)[0], Notice::Receipt { normalized: changed, line, files, .. } if *changed == normalized && line.text == expected && files.len() == 1)
		);
		assert!(
			matches!(notices(&mutation.effects, 2)[0], Notice::Line { line, files, .. } if line.text == expected && files.len() == 1)
		);
	}
}
