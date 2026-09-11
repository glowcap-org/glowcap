use super::arguments::from_fixture;
use rooms_application::directory::registration::{self, Custody, Error, Id, Kind, Notice};
use serde_json::{json, Value};
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/registration-client.json")).unwrap();
	for row in fixture["ids"].as_array().unwrap() {
		assert_eq!(
			Id::parse(row["input"].as_str().unwrap()).is_ok(),
			row["accepted"].as_bool().unwrap()
		);
	}
	for row in fixture["notices"].as_array().unwrap() {
		let args: Vec<_> = row["args"].as_array().unwrap().iter().map(from_fixture).collect();
		let result = registration::notice(row["verb"].as_str().unwrap(), |i| args.get(i));
		assert_eq!(result.is_err(), row["error"] == true);
		match result {
			Ok(Some(Notice::Registered(id))) => assert_eq!(id.as_str(), row["ack"].as_str().unwrap()),
			Ok(Some(Notice::Event(event))) => {
				let kind = match event.kind {
					Kind::MintInboxFor => "mintInboxFor",
					Kind::DirectRequested => "directRequested",
					Kind::Introducible => "introducible",
				};
				assert_eq!(
					json!({"kind":kind,"peer":event.peer.text(),"id":event.registration.as_str()}),
					row["event"]
				);
			}
			Ok(None) => assert!(row["event"].is_null()),
			Err(_) => {}
		}
	}
	// The directory's real nickname ceiling bounds retained control notices
	// too, including astral characters that occupy two UTF-16 units each.
	for (peer, accepted) in [("😀".repeat(16), true), ("😀".repeat(16) + "x", false)] {
		let values = json!(["introducible", peer, "11111111-1111-4111-8111-111111111111"]);
		let args: Vec<_> = values.as_array().unwrap().iter().map(from_fixture).collect();
		assert_eq!(registration::notice("notify", |i| args.get(i)).is_ok(), accepted);
	}
	let mut custody = Custody::default();
	assert!(custody.name().unwrap().is_none());
	custody.begin().unwrap();
	assert_eq!(custody.begin(), Err(Error::Busy));
	custody.replace(1).unwrap();
	assert_eq!(custody.name(), Err(Error::Busy));
	custody.finish().unwrap();
	assert_eq!(custody.name().unwrap(), Some(&1));
	// Failed replacement retains the predecessor; acknowledgement failure
	// after a capability commit retains the actual new capability instead.
	custody.begin().unwrap();
	custody.finish().unwrap();
	assert_eq!(custody.name().unwrap(), Some(&1));
	custody.begin().unwrap();
	custody.replace(2).unwrap();
	custody.finish().unwrap();
	assert_eq!(custody.take().unwrap(), Some(2));
	assert_eq!(custody.finish(), Err(Error::NoPending));
	custody.begin().unwrap();
	custody.close();
	assert_eq!(custody.replace(3), Err(Error::Ended));
	custody.finish().unwrap();
	assert_eq!(custody.begin(), Err(Error::Ended));
	let event = || registration::Event {
		kind: Kind::Introducible,
		peer: rooms_application::fields::Text::new("bob".into()).unwrap(),
		registration: Id::parse("11111111-1111-4111-8111-111111111111").unwrap(),
	};
	let mut events = registration::Events::default();
	events.push(event()).unwrap();
	assert_eq!(events.pop().unwrap().unwrap().kind, Kind::Introducible);
	assert!(events.pop().unwrap().is_none());
	for _ in 0..registration::MAX_EVENTS {
		events.push(event()).unwrap();
	}
	assert_eq!(events.push(event()), Err(Error::Overflow));
	assert!(matches!(events.pop(), Err(Error::Overflow)));
	assert_eq!(events.push(event()), Err(Error::Overflow));
}
