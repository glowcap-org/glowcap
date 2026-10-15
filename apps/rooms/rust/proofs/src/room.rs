//! The same Rooms behavior scenarios execute on the host and in browser Wasm.
use rooms_application::room::{
	line::{Line, LineError, MAX_LINE_BYTES, MAX_MESSAGE_FILES},
	message::{ChangeKind, LineId, LineMarker},
	policy::RoomPolicy,
};
use serde_json::{Value, json};
use std::{cell::Cell, rc::Rc};

use crate::arguments::{Arg, from_fixture, text};

pub fn run() {
	current_owner_fixtures();
	file_custody();
	refusal_preserves_owners();
	terminal_withdrawal();
	ids_and_constructor();
	maximum_selection();
	marker_refusals();
	nested_argument_custody();
}

fn current_owner_fixtures() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/room-protocol.json")).unwrap();
	assert_eq!(fixture["limits"]["lineBytes"], MAX_LINE_BYTES);
	assert_eq!(fixture["limits"]["messageFiles"], MAX_MESSAGE_FILES);
	for row in fixture["policies"].as_array().unwrap() {
		let modes: Vec<_> = row["modes"]
			.as_array()
			.unwrap()
			.iter()
			.map(|s| s.as_str().unwrap())
			.collect();
		let policy = RoomPolicy::parse(&modes);
		assert_eq!(policy.is_some(), row["valid"].as_bool().unwrap());
		assert_eq!(
			policy.and_then(RoomPolicy::public_membership).map(|kind| kind.as_str()),
			row["offers"].as_str()
		);
		if let Some(policy) = policy {
			assert_eq!(policy.modes().as_slice(), modes);
			assert_eq!(policy.is_listed(), modes[0] == "listed");
		}
	}
	assert!(RoomPolicy::parse(&["listed", "open"]).is_none());
	assert!(RoomPolicy::parse(&["listed", "open", "open", "extra"]).is_none());
	for row in fixture["markers"].as_array().unwrap() {
		let args: Vec<_> = row["args"].as_array().unwrap().iter().map(from_fixture).collect();
		let marker = LineMarker::read(&args);
		assert_eq!(marker.map(|m| m.id.get()), row["id"].as_u64());
		let tag = marker.map(|m| {
			if m.kind == ChangeKind::Said {
				"said"
			} else {
				m.kind.wire_tag()
			}
		});
		assert_eq!(tag, row["change"].as_str());
	}
	for sequence in fixture["lines"].as_array().unwrap() {
		let mut line = Line::<()>::new(LineId::new(7).unwrap(), "ada".into(), vec![]).unwrap();
		for step in sequence.as_array().unwrap() {
			let args: Vec<_> = step["args"].as_array().unwrap().iter().map(from_fixture).collect();
			let outcome = line.dispatch(step["verb"].as_str().unwrap(), &args, &mut vec![]);
			assert_eq!(outcome.is_ok(), step["accepted"].as_bool().unwrap());
			assert_eq!(
				outcome.as_ref().err().map(ToString::to_string),
				step["error"].as_str().map(String::from)
			);
			let notices = match outcome {
				Ok(Some(change)) => {
					assert!(change.files.is_empty() && change.retired.is_empty());
					let incoming = [
						text(change.from),
						text(change.text),
						text(change.kind.wire_tag()),
						Arg::Integer(change.id.get().into()),
					];
					assert_eq!(
						LineMarker::read(&incoming),
						Some(LineMarker {
							id: change.id,
							kind: change.kind
						})
					);
					json!([[change.from, change.text, change.kind.wire_tag(), {"integer": change.id.get().to_string()}]])
				}
				_ => json!([]),
			};
			assert_eq!(notices, step["notifications"]);
		}
	}
}

#[derive(Debug)]
struct File {
	id: u8,
	bytes: Box<[u8]>,
	drops: Rc<Cell<usize>>,
}

impl Drop for File {
	fn drop(&mut self) {
		self.drops.set(self.drops.get() + 1);
	}
}

fn file(id: u8, drops: &Rc<Cell<usize>>) -> File {
	File {
		id,
		bytes: vec![id; 65536].into_boxed_slice(),
		drops: drops.clone(),
	}
}

fn ids(files: &[File]) -> Vec<u8> {
	files.iter().map(|file| file.id).collect()
}

fn file_custody() {
	let drops = Rc::new(Cell::new(0));
	let files: Vec<_> = (0..3).map(|id| file(id, &drops)).collect();
	let pointers: Vec<_> = files.iter().map(|f| f.bytes.as_ptr()).collect();
	let mut line = Line::new(LineId::new(1).unwrap(), "author".into(), files).unwrap();
	let mut staged = vec![file(3, &drops)];
	let staged_pointer = staged[0].bytes.as_ptr();
	let args = [text("another holder's caption"), Arg::Integer(2), Arg::Integer(0)];
	let change = line.dispatch("refile", &args, &mut staged).unwrap().unwrap();
	assert_eq!(change.from, "author");
	assert_eq!(change.kind.wire_tag(), "refiled");
	assert_eq!(ids(change.files), [2, 0, 3]);
	assert_eq!(ids(&change.retired), [1]);
	assert_eq!(change.files[0].bytes.as_ptr(), pointers[2]);
	assert_eq!(change.files[1].bytes.as_ptr(), pointers[0]);
	assert_eq!(change.files[2].bytes.as_ptr(), staged_pointer);
	assert!(staged.is_empty());
	assert_eq!(drops.get(), 0);
	drop(change);
	assert_eq!(drops.get(), 1);

	let edit = [text("caption only")];
	let change = line.dispatch("edit", &edit, &mut staged).unwrap().unwrap();
	assert!(change.files.is_empty() && change.retired.is_empty());
	drop(change);
	assert_eq!(ids(line.files()), [2, 0, 3]);
	let change = line.dispatch::<Arg>("withdraw", &[], &mut staged).unwrap().unwrap();
	assert_eq!(ids(&change.retired), [2, 0, 3]);
	assert!(change.files.is_empty());
	drop(change);
	assert_eq!(drops.get(), 4);
	drop(line);
	assert_eq!(drops.get(), 4);
}

fn refusal_preserves_owners() {
	let drops = Rc::new(Cell::new(0));
	let mut line = Line::new(
		LineId::new(2).unwrap(),
		"ada".into(),
		vec![file(0, &drops), file(1, &drops)],
	)
	.unwrap();
	let mut staged = vec![file(2, &drops)];
	let cases = [
		(
			vec![text("caption"), Arg::Integer(0), Arg::Integer(0)],
			LineError::DuplicateFile(0),
		),
		(
			vec![text("caption"), Arg::Integer(-1)],
			LineError::FileIndexOutOfRange(-1),
		),
		(
			vec![text("caption"), Arg::Integer(i128::MAX)],
			LineError::FileIndexOutOfRange(i128::MAX),
		),
		(
			vec![text("caption"), Arg::Integer(2)],
			LineError::FileIndexOutOfRange(2),
		),
		(vec![text("caption"), Arg::Other], LineError::FileIndexType),
		(
			vec![text(&"🙂".repeat(MAX_LINE_BYTES / 4 + 1))],
			LineError::CaptionTooLong,
		),
		(vec![], LineError::CaptionRequired),
	];
	for (args, expected) in cases {
		assert_eq!(line.dispatch("refile", &args, &mut staged).unwrap_err(), expected);
		assert_eq!(ids(line.files()), [0, 1]);
		assert_eq!(ids(&staged), [2]);
		assert_eq!(drops.get(), 0);
		assert!(!line.is_withdrawn());
	}
	staged.extend((3..10).map(|id| file(id, &drops)));
	let args = [text("caption"), Arg::Integer(0)];
	assert_eq!(
		line.dispatch("refile", &args, &mut staged).unwrap_err(),
		LineError::TooManyFiles
	);
	assert_eq!(ids(line.files()), [0, 1]);
	assert_eq!(staged.len(), 8);
	assert_eq!(drops.get(), 0);
	// Exactly the maximum is valid when keeping none of the current files.
	let args = [text("")];
	let change = line.dispatch("refile", &args, &mut staged).unwrap().unwrap();
	assert_eq!(change.files.len(), 8);
	assert_eq!(change.kind.wire_tag(), "refiled");
	drop(change);
	assert!(!line.is_withdrawn());
	assert_eq!(drops.get(), 2);
	drop(line);
	assert_eq!(drops.get(), 10);
}

fn terminal_withdrawal() {
	let mut line = Line::new(LineId::new(3).unwrap(), "ada".into(), vec![1_u8]).unwrap();
	let mut staged = vec![];
	let args = [text("")];
	let change = line.dispatch("refile", &args, &mut staged).unwrap().unwrap();
	assert_eq!(change.kind.wire_tag(), "withdrawn");
	assert_eq!(change.retired, [1]);
	drop(change);
	staged.push(2);
	for verb in ["edit", "refile"] {
		assert_eq!(
			line.dispatch(verb, &args, &mut staged).unwrap_err(),
			LineError::Withdrawn
		);
		assert_eq!(staged, [2]);
	}
	assert!(line.dispatch::<Arg>("withdraw", &[], &mut staged).unwrap().is_none());
	assert_eq!(
		line.dispatch("withdraw", &args, &mut staged).unwrap_err(),
		LineError::WithdrawArguments
	);
	assert_eq!(staged, [2]);
}

fn ids_and_constructor() {
	assert!(LineId::new(0).is_none());
	assert!(LineId::new(1 << 53).is_none());
	assert_eq!(LineId::new((1 << 53) - 1).unwrap().get(), (1 << 53) - 1);
	let drops = Rc::new(Cell::new(0));
	let files: Vec<_> = (0..9).map(|id| file(id, &drops)).collect();
	let returned = Line::new(LineId::new(1).unwrap(), "ada".into(), files).unwrap_err();
	assert_eq!(returned.len(), 9);
	assert_eq!(drops.get(), 0);
	drop(returned);
	assert_eq!(drops.get(), 9);
}

fn nested_argument_custody() {
	let drops = Rc::new(Cell::new(0));
	let mut line = Line::<()>::new(LineId::new(1).unwrap(), "ada".into(), vec![]).unwrap();
	for verb in ["edit", "refile", "withdraw", "unknown"] {
		let args = [text("caption"), Arg::List(vec![Arg::Capability(drops.clone())])];
		let before = drops.get();
		assert_eq!(
			line.dispatch(verb, &args, &mut vec![]).unwrap_err(),
			LineError::UnexpectedCapability
		);
		assert_eq!(drops.get(), before);
		assert!(!line.is_withdrawn());
		drop(args);
		assert_eq!(drops.get(), before + 1);
	}
}

fn maximum_selection() {
	let mut line = Line::new(LineId::new(1).unwrap(), "ada".into(), (0..8).collect::<Vec<u8>>()).unwrap();
	let mut args = vec![text("all files, reordered")];
	args.extend((0..8).rev().map(Arg::Integer));
	let mut staged = vec![];
	let change = line.dispatch("refile", &args, &mut staged).unwrap().unwrap();
	assert_eq!(change.files, [7, 6, 5, 4, 3, 2, 1, 0]);
	assert!(change.retired.is_empty());
	drop(change);
	args.push(Arg::Integer(0));
	assert_eq!(
		line.dispatch("refile", &args, &mut staged).unwrap_err(),
		LineError::DuplicateFile(0)
	);
	assert_eq!(line.files(), [7, 6, 5, 4, 3, 2, 1, 0]);
	assert_eq!(
		line.dispatch::<Arg>("missing", &[], &mut staged).unwrap_err(),
		LineError::UnknownMethod("missing".into())
	);
}

fn marker_refusals() {
	for value in [
		f64::NAN,
		f64::INFINITY,
		f64::NEG_INFINITY,
		0.0,
		-1.0,
		0.5,
		(1_u64 << 53) as f64,
	] {
		let args = [
			text("ada"),
			text("keep the display text"),
			text("line"),
			Arg::Float(value),
		];
		assert!(LineMarker::read(&args).is_none());
	}
	// An integral float is valid notification metadata, but not a file index.
	let args = [text("caption"), Arg::Float(0.0)];
	let mut line = Line::new(LineId::new(1).unwrap(), "ada".into(), vec![1_u8]).unwrap();
	assert_eq!(
		line.dispatch("refile", &args, &mut vec![]).unwrap_err(),
		LineError::FileIndexType
	);
	assert_eq!(line.files(), [1]);
}
