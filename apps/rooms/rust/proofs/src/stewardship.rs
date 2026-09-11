use rooms_application::room::stewardship::{Acquisition, Error, Kind, Publication, Stewardship};
use serde_json::{json, Value};
use std::{cell::Cell, rc::Rc};

pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/stewardship.json")).unwrap();
	let publication =
		|kind: &str| Publication::new(fixture["links"][kind].as_str().unwrap().into(), kind.into()).unwrap();
	let grant = || Acquisition::Steward {
		room: publication("room"),
		publication: publication("steward"),
		reference: (),
	};
	let mut state = Stewardship::default();
	for row in fixture["trace"].as_array().unwrap() {
		let action = row["action"][0].as_str().unwrap();
		let mut result = Value::Null;
		let mut accepted = true;
		let mut acquisition = None;
		match action {
			"claim" => {
				result = json!(state.held() || state.manager().is_some());
				if !state.held() && state.manager().is_some() {
					acquisition = Some(grant());
				}
			}
			"link" => acquisition = Some(Acquisition::Room(publication("room"))),
			"manager" => acquisition = Some(Acquisition::Manager(publication("manager"))),
			"take" => {
				if !state.held() {
					acquisition = Some(grant());
				}
			}
			"release" => state.release(),
			"drop" => state.drop_steward(),
			"dropManager" => state.drop_manager(),
			"kick" => accepted = state.reference().is_ok(),
			"forget" => state.forget(
				match row["action"][1].as_str().unwrap() {
					"room" => Kind::Room,
					"steward" => Kind::Steward,
					"manager" => Kind::Manager,
					_ => unreachable!(),
				},
				row["action"][2].as_str().unwrap(),
			),
			_ => unreachable!(),
		}
		if let Some(acquisition) = acquisition {
			let attempt = state.begin().unwrap();
			state.accept(attempt, acquisition).unwrap();
		}
		assert_eq!(accepted, row["accepted"].as_bool().unwrap());
		assert_eq!(result, row["result"]);
		assert_eq!(
			json!({"room":state.room().map(Publication::link),"manager":state.manager().map(Publication::link),
            "steward":state.steward().map(Publication::link),"held":state.held()}),
			row["state"],
			"{action}"
		);
	}
	acquisition_custody();
}
struct Guard(Rc<Cell<u32>>);
impl Drop for Guard {
	fn drop(&mut self) {
		self.0.set(self.0.get() + 1);
	}
}
fn acquisition_custody() {
	let drops = Rc::new(Cell::new(0));
	let publication = |name: &str| Publication::new(name.into(), name.into()).unwrap();
	let grant = || Acquisition::Steward {
		room: publication("room"),
		publication: publication("moderator"),
		reference: Guard(drops.clone()),
	};
	let mut first = Stewardship::default();
	let mut second = Stewardship::default();
	let attempt = first.begin().unwrap();
	assert!(matches!(first.begin(), Err(Error::Busy)));
	drop(attempt); // cancelled observation frees its admission
	let attempt = first.begin().unwrap();
	first.accept(attempt, grant()).unwrap();
	// Publication tokens are compared within their authority kind. Even equal
	// token text cannot turn manager retirement into moderator retirement.
	let attempt = first.begin().unwrap();
	first
		.accept(attempt, Acquisition::Manager(publication("room")))
		.unwrap();
	first.forget(Kind::Manager, "room");
	assert!(first.manager().is_none() && first.held() && first.room().is_some());
	let attempt = second.begin().unwrap();
	second.accept(attempt, grant()).unwrap();
	let pending = first.begin().unwrap();
	first.forget(Kind::Steward, "older-generation");
	assert!(first.held()); // stale notice cannot erase current authority
	assert!(matches!(first.begin(), Err(Error::Busy))); // invalidation doesn't reopen an occupied seat
	assert_eq!(first.accept(pending, grant()), Err(Error::Retired));
	assert_eq!(drops.get(), 1); // refused candidate dropped exactly once
	let pending = first.begin().unwrap();
	assert_eq!(second.accept(pending, grant()), Err(Error::Retired)); // owner-bound ticket
	assert!(first.held() && second.held());
	first.forget(Kind::Room, "room");
	assert!(!first.held() && second.held());
	assert!(matches!(first.reference(), Err(Error::StewardRetired)));
	second.release();
	assert!(second.steward().is_some() && second.room().is_some());
	assert_eq!(drops.get(), 4);
	let attempt = first.begin().unwrap();
	first.drop_steward();
	assert_eq!(first.accept(attempt, grant()), Err(Error::Retired));
	assert_eq!(drops.get(), 5);
}
