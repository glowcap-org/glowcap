//! Exact registration retirement cannot withdraw a successor's name or inbox.
use super::*;

#[test]
fn retirement_releases_exact_custody_once_and_preserves_replacements() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "alice-inbox");
	registered(&mut dir, 2, "Bob", "bob-inbox");
	dir.offer_inbox(2, "Alice", id(1).as_str(), "opening", "for-alice")
		.unwrap();
	let retired = dir.retire_registration(&id(1));
	assert_eq!(dir.registered_nick(1), None);
	assert!(!dir.registration_known(&id(1)));
	assert_eq!(retired.releases.len(), 2);
	assert_eq!(retired.events.len(), 1);
	assert_eq!(member_event(&retired.events[0]), Some((false, "Alice", 0)));
	assert!(dir.retire_registration(&id(1)).events.is_empty());
	assert!(dir.retire_registration(&id(1)).releases.is_empty());
	dir.register(1, request("Alice", "replacement-inbox"), id(3), 0)
		.unwrap();
	let repeated = dir.retire_registration(&id(1));
	assert!(repeated.events.is_empty() && repeated.releases.is_empty());
	assert_eq!(dir.member_registration("Alice").unwrap(), id(3));
	assert_eq!(dir.registered_nick(1), Some("Alice"));
	assert_eq!(dir.registered_nick(2), Some("Bob"));
	assert!(dir.voucher(&id(1), [1; NAME_VOUCHER_BYTES]).is_err());
	assert!(dir.voucher(&id(3), [2; NAME_VOUCHER_BYTES]).is_ok());
}
