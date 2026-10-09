//! Exact discovery cleanup cannot retire another connection or its successor.
use super::*;

#[test]
fn discovery_cancellation_is_exact_idempotent_and_does_not_require_registration() {
	let mut directory = Dir::default();
	directory
		.watch(1, "first", Shape::Publication, core::iter::empty())
		.unwrap();
	assert!(directory.unwatch(2, &"first").is_none());
	assert!(directory.unwatch(1, &"wrong").is_none());
	let (_, old) = directory
		.watch(1, "successor", Shape::Publication, core::iter::empty())
		.unwrap();
	assert_eq!(old.unwrap().capability, "first");
	assert!(directory.unwatch(1, &"first").is_none());
	assert_eq!(directory.watchers().count(), 1);
	assert_eq!(directory.unwatch(1, &"successor").unwrap().capability, "successor");
	assert!(directory.unwatch(1, &"successor").is_none());
	assert_eq!(directory.watchers().count(), 0);
	assert_eq!(directory.registered_nick(1), None);
}
