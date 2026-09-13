use super::arguments::from_fixture;
use rooms_application::directory::{self, Error, Event, creation::RecoveryKey, queue::Queue};
use serde_json::Value;

pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/directory-client.json")).unwrap();
	for row in fixture["lists"].as_array().unwrap() {
		let raw = from_fixture(&row["input"]);
		let result = directory::rooms(&&raw);
		assert_eq!(result.is_err(), row["error"] == true, "{}", row["input"]);
		if let Ok(result) = result {
			assert_eq!(serde_json::to_value(result).unwrap(), row["result"]);
		}
	}
	for row in fixture["snapshots"].as_array().unwrap() {
		let raw = from_fixture(&row["input"]);
		let result = directory::snapshot(&&raw);
		assert_eq!(result.is_err(), row["error"] == true, "{}", row["input"]);
		if let Ok(result) = result {
			assert_eq!(serde_json::to_value(result).unwrap(), row["result"]);
		}
	}
	for row in fixture["events"].as_array().unwrap() {
		let raw = from_fixture(&row["input"]);
		assert_eq!(serde_json::to_value(directory::event(&&raw)).unwrap(), row["result"]);
	}
	for row in fixture["keys"].as_array().unwrap() {
		assert_eq!(
			RecoveryKey::parse(row["input"].as_str().unwrap().into()).is_ok(),
			row["accepted"].as_bool().unwrap()
		);
	}
	let mut queue = Queue::default();
	for i in 0..directory::MAX_ROWS {
		queue.push(Event::Truncated(i as u64)).unwrap();
	}
	assert!(matches!(queue.pop(), Ok(Some(Event::Truncated(0)))));
	queue.push(Event::Truncated(256)).unwrap();
	assert_eq!(queue.push(Event::Truncated(257)).unwrap_err(), Error::Overflow);
	assert!(matches!(queue.pop(), Err(Error::Overflow)));
	queue.close();
	assert!(matches!(queue.pop(), Err(Error::Overflow)));
	let mut queue = Queue::default();
	queue.close();
	assert!(matches!(queue.pop(), Err(Error::Closed)));
	assert_eq!(queue.push(Event::Truncated(0)).unwrap_err(), Error::Closed);
}
