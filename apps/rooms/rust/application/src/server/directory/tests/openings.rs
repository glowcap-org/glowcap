//! Each opening has its own offer, and consumption returns bounded capacity.
use super::*;

#[test]
fn direct_openings_cannot_inherit_or_consume_sibling_offers() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	registered(&mut dir, 2, "Bob", "b-inbox");
	dir.offer_inbox(1, "Bob", id(2).as_str(), "first", "first-inbox")
		.unwrap();
	assert!(
		matches!(dir.introduce(2, "Alice", id(1).as_str(), "second").unwrap(), Introduction::Pending(Tell { notice: Notice::MintInboxFor { opening, .. }, .. }) if opening == "second")
	);
	dir.offer_inbox(1, "Bob", id(2).as_str(), "second", "second-inbox")
		.unwrap();
	assert_eq!(
		dir.introduce(2, "Alice", id(1).as_str(), "first"),
		Ok(Introduction::Inbox("first-inbox"))
	);
	assert_eq!(
		dir.introduce(2, "Alice", id(1).as_str(), "second"),
		Ok(Introduction::Inbox("second-inbox"))
	);
	assert!(
		dir.registry
			.faces()
			.find(|face| face.nick == "Alice")
			.unwrap()
			.offered
			.is_empty()
	);
	assert!(
		matches!(
			dir.introduce(2, "Alice", id(1).as_str(), "first").unwrap(),
			Introduction::Pending(_)
		),
		"consumed callbacks are never cached"
	);
	// Repeated conversation churn returns capacity without retiring registration.
	for n in 0..MAX_DM_INBOXES * 2 {
		let opening = format!("opening:{n}");
		dir.offer_inbox(1, "Bob", id(2).as_str(), &opening, "fresh").unwrap();
		assert_eq!(
			dir.introduce(2, "Alice", id(1).as_str(), &opening),
			Ok(Introduction::Inbox("fresh"))
		);
	}
}

#[test]
fn pending_openings_share_the_member_bound_and_withdraw_symmetrically() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	registered(&mut dir, 2, "Bob", "b-inbox");
	for n in 0..MAX_DM_INBOXES {
		dir.offer_inbox(1, "Bob", id(2).as_str(), &format!("opening:{n}"), "held")
			.unwrap();
	}
	assert!(dir.offer_inbox(1, "Bob", id(2).as_str(), "full", "refused").is_err());
	dir.offer_inbox(1, "Bob", id(2).as_str(), "opening:0", "replacement")
		.unwrap();
	let released = dir.connection_closed(2);
	assert_eq!(released.releases.len(), MAX_DM_INBOXES + 1);
	assert!(
		dir.registry
			.faces()
			.find(|face| face.nick == "Alice")
			.unwrap()
			.offered
			.is_empty()
	);
	registered(&mut dir, 3, "Carol", "c-inbox");
	dir.offer_inbox(1, "Carol", id(3).as_str(), "available", "fresh")
		.unwrap();
}
