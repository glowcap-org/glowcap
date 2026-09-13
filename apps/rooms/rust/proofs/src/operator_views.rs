//! Actual TypeScript response captures pin operator and operations admission.
use crate::arguments::{Arg, from_fixture};
use rooms_application::{
	server::operations::operator::{Category, view},
	session::operations::{Capability, Snapshot},
};
use serde_json::Value;
use std::{cell::Cell, rc::Rc};

pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/operator-views.json")).unwrap();
	for case in fixture["pages"].as_array().unwrap() {
		let value = from_fixture(&case["raw"]);
		let category = Category::parse(case["category"].as_str().unwrap()).unwrap();
		let result = view::read_page(category, &&value);
		assert_eq!(
			result.is_ok(),
			case["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			case["name"],
			result.as_ref().err()
		);
	}
	let whole = from_fixture(&fixture["whole"]);
	let decoded = view::read_snapshot(&&whole).unwrap();
	assert_eq!(
		serde_json::from_str::<Value>(&decoded.encode().unwrap()).unwrap(),
		serde_json::from_str::<Value>(fixture["expected"].as_str().unwrap()).unwrap()
	);
	for case in fixture["snapshots"].as_array().unwrap() {
		let result = view::Snapshot::decode(case["raw"].as_str().unwrap());
		assert_eq!(
			result.is_ok(),
			case["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			case["name"],
			result.as_ref().err()
		);
		if case["name"] == "surrogate-label" {
			assert_eq!(
				result.unwrap().links.as_slice()[0]
					.label
					.text()
					.utf16()
					.collect::<Vec<_>>(),
				[97, 0xd800, 98]
			);
		}
	}
	for case in fixture["operations"].as_array().unwrap() {
		let capability = match case["capability"].as_str().unwrap() {
			"listeners" => Capability::Listeners,
			"diagnostics" => Capability::Diagnostics,
			"trace" => Capability::Trace,
			"peering" => Capability::Peering,
			"irc" => Capability::Irc,
			_ => unreachable!(),
		};
		let result = Snapshot::decode(capability, case["raw"].as_str().unwrap());
		assert_eq!(
			result.is_ok(),
			case["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			case["name"],
			result.as_ref().err()
		);
	}
	let drops = Rc::new(Cell::new(0));
	let rejected = Arg::List(vec![
		Arg::Integer(1),
		Arg::Null,
		Arg::List(vec![Arg::List(vec![Arg::Capability(drops.clone())])]),
		Arg::Integer(1),
	]);
	assert!(view::read_page(Category::Links, &&rejected).is_err());
	assert_eq!(Rc::strong_count(&drops), 2);
	drop(rejected);
	assert_eq!(drops.get(), 1);
	assert_eq!(Rc::strong_count(&drops), 1);
}
#[test]
fn captured_operator_and_operations_views() {
	run();
}
