//! Captured TypeScript event admission plus capability custody on refusal.
use crate::arguments::{Arg, from_fixture, text};
use rooms_application::session::event::{Event, Presence};
use std::{cell::Cell, rc::Rc};

pub fn run() {
	use rooms_application::archive::change::Change;
	assert_eq!(Change::read(&[] as &[Arg]).unwrap(), Change::All);
	for kind in ["room", "direct"] {
		assert!(Change::read(&[text(kind), text("directory"), text("conversation")]).is_ok());
	}
	for args in [
		vec![text("room")],
		vec![text("standing"), text("directory"), text("conversation")],
		vec![text("room"), text(""), text("conversation")],
		vec![
			text("room"),
			text("directory"),
			text(&"a".repeat(rooms_application::archive::MAX_CONVERSATION_BYTES + 1)),
		],
		vec![text("room"), text(&"é".repeat(4097)), text("conversation")],
		vec![text("room"), Arg::Integer(3), text("conversation")],
	] {
		assert!(Change::read(&args).is_err());
	}

	let fixture: serde_json::Value = serde_json::from_str(include_str!("../fixtures/session-events.json")).unwrap();
	for case in fixture["rows"].as_array().unwrap() {
		let args: Vec<_> = case["raw"].as_array().unwrap().iter().map(from_fixture).collect();
		let result = Event::read(&args);
		assert_eq!(
			result.is_ok(),
			case["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			case["name"],
			result.as_ref().err()
		);
		if case["name"] == "presence-surrogate" {
			let Some(Presence::Typing { name, on: false }) = result.unwrap().presence else {
				panic!("typing metadata");
			};
			assert_eq!(name.text().utf16().collect::<Vec<_>>(), [97, 0xd800, 98]);
		} else if case["name"] == "facts-surrogate" {
			assert_eq!(
				result
					.unwrap()
					.facts
					.unwrap()
					.subject
					.unwrap()
					.description()
					.utf16()
					.collect::<Vec<_>>(),
				[97, 0xd800, 98]
			);
		}
	}
	let baseline = &fixture["rows"][0]["raw"];
	let drops = Rc::new(Cell::new(0));
	let make = || {
		let mut args: Vec<_> = baseline.as_array().unwrap().iter().map(from_fixture).collect();
		args.extend([
			text("file"),
			text("hello.txt"),
			text("text/plain"),
			Arg::Integer(5),
			Arg::Capability(drops.clone()),
			Arg::Integer(0),
			Arg::Integer(0),
		]);
		args
	};
	let args = make();
	let event = Event::read(&args).unwrap();
	assert!(event.previews.is_empty());
	assert_eq!(Rc::strong_count(&drops), 3, "accepted event retains the supplied guard");
	drop(args);
	assert_eq!(Rc::strong_count(&drops), 2, "event outlives the delivery frame");
	drop(event);
	assert_eq!(Rc::strong_count(&drops), 1);
	let mut preview_args: Vec<_> = baseline.as_array().unwrap().iter().map(from_fixture).collect();
	preview_args[4] = text("see https://example.test/page");
	preview_args[15] = text(r#"["https://example.test/page"]"#);
	let preview_event = Event::read(&preview_args).unwrap();
	assert_eq!(preview_event.previews.urls(), ["https://example.test/page"]);
	preview_args[15] = text(r#"["https://elsewhere.test/"]"#);
	assert!(Event::read(&preview_args).is_err());
	for index in [6, 12, 14] {
		let mut args = make();
		match index {
			6 => {
				args[6] = Arg::Null;
				args[7] = text("refiled");
			}
			12 => args[12] = Arg::Boolean(true),
			14 => args[14] = text("{\"subject\":null}"),
			_ => unreachable!(),
		}
		assert!(Event::read(&args).is_err());
		assert_eq!(Rc::strong_count(&drops), 2, "refused notices retain no capability");
		drop(args);
		assert_eq!(Rc::strong_count(&drops), 1);
	}
	let mut args = make();
	args.extend([
		text("file"),
		text(""),
		text("text/plain"),
		Arg::Integer(5),
		Arg::Capability(drops.clone()),
		Arg::Integer(0),
		Arg::Integer(0),
	]);
	assert!(Event::read(&args).is_err());
	assert_eq!(
		Rc::strong_count(&drops),
		3,
		"invalid later file releases any earlier tentative retains"
	);
	drop(args);
	assert_eq!(Rc::strong_count(&drops), 1);
}
#[test]
fn captured_session_event_contract() {
	run();
}
