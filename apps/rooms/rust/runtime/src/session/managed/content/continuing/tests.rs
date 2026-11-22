//! The private continuation admits exactly the session's own follow-up
//! writes: one row's inbox for a direct conversation, a directory, or a room,
//! and the retirement of a lost connection. Any other change is refused.
use super::admits;
use rooms_application::content::session::{custody, workspace};
use serde_json::json;

fn key(slot: u64) -> String {
	format!("{slot:016x}{:016x}", 1)
}
fn typed<K>(slot: u64) -> custody::FieldKey<K> {
	custody::FieldKey::new(core::num::NonZeroU64::new(slot).unwrap(), core::num::NonZeroU64::MIN)
}
fn coordinate(role: custody::Role, slot: u64) -> custody::Coordinate {
	custody::Coordinate::new(role, typed::<custody::DirectInbox>(slot))
}
fn current() -> workspace::Intent {
	workspace::Intent::decode(
		&json!({"version":1,
			"directories":[{"id":"d","access":key(1),"name":key(2),"source":key(3),"inbox":key(4),"home":true,
				"nick":"bot","nickAllocation":"exact","standing":null}],
			"conversations":[
				{"kind":"room","id":"r","directory":"d","name":"n","seat":key(5),"inbox":key(6),"source":key(3),
					"access":key(7),"control":null,"reconnect":"requested","standing":null,"draft":""},
				{"kind":"direct","id":"m","directory":"d","peer":"Ann","access":key(9),"source":key(3),"inbox":key(8),
					"closed":false,"draft":"kept"}],
			"invitations":[],"active":null,"standing":"","ignored":[],"keepHistory":false,"connection":"fastest",
			"archive":null,"archiveControl":null,"operators":[],"peering":[]})
		.to_string(),
	)
	.unwrap()
}
fn room(intent: &mut workspace::Intent) -> &mut workspace::Room {
	match &mut intent.conversations.as_mut_slice()[0] {
		workspace::Conversation::Room(row) => row,
		workspace::Conversation::Direct(_) => unreachable!("the room is first"),
	}
}
fn direct(intent: &mut workspace::Intent) -> &mut workspace::Direct {
	match &mut intent.conversations.as_mut_slice()[1] {
		workspace::Conversation::Direct(row) => row,
		workspace::Conversation::Room(_) => unreachable!("the direct row is second"),
	}
}

#[test]
fn one_inbox_install_is_admitted_for_each_supervised_row() {
	use custody::Role::{DirectInbox, DirectoryInbox, RoomInbox};
	let current = current();
	let mut next = current.clone();
	direct(&mut next).inbox = Some(typed(20));
	let (import, prior) = (coordinate(DirectInbox, 20), coordinate(DirectInbox, 8));
	assert!(admits(&current, &next, &[import], &[]));
	assert!(admits(&current, &next, &[import], &[prior]));
	let mut next = current.clone();
	next.directories.as_mut_slice()[0].inbox = Some(typed(21));
	assert!(admits(
		&current,
		&next,
		&[coordinate(DirectoryInbox, 21)],
		&[coordinate(DirectoryInbox, 4)]
	));
	let mut next = current.clone();
	room(&mut next).inbox = Some(typed(22));
	assert!(admits(
		&current,
		&next,
		&[coordinate(RoomInbox, 22)],
		&[coordinate(RoomInbox, 6)]
	));
	assert!(
		admits(&current, &current, &[import], &[]),
		"an exact replay changes nothing"
	);
}

#[test]
fn a_lost_connection_retires_through_the_shared_clearing() {
	let current = current();
	let mut next = current.clone();
	direct(&mut next).retire_connection();
	room(&mut next).retire_connection();
	next.directories.as_mut_slice()[0].retire_connection();
	assert!(admits(&current, &next, &[], &[]));
	assert!(!admits(
		&current,
		&next,
		&[],
		&[coordinate(custody::Role::DirectInbox, 8)]
	));
}

#[test]
fn any_other_change_is_refused() {
	use custody::Role::{DirectAccess, DirectInbox, RoomInbox};
	let current = current();
	let mut next = current.clone();
	direct(&mut next).inbox = Some(typed(20));
	let import = coordinate(DirectInbox, 20);
	assert!(
		!admits(&current, &next, &[coordinate(RoomInbox, 20)], &[]),
		"the import names another role"
	);
	assert!(
		!admits(&current, &next, &[import, coordinate(RoomInbox, 22)], &[]),
		"a second import"
	);
	assert!(
		!admits(&current, &next, &[import], &[coordinate(DirectInbox, 30)]),
		"an unrelated release"
	);
	direct(&mut next).draft = workspace::Field::default();
	assert!(
		!admits(&current, &next, &[import], &[]),
		"an install that also edits a draft"
	);
	let mut next = current.clone();
	direct(&mut next).access = Some(typed(20));
	assert!(
		!admits(&current, &next, &[coordinate(DirectAccess, 20)], &[]),
		"a route is not an inbox"
	);
	let mut next = current.clone();
	direct(&mut next).closed = true;
	assert!(
		!admits(&current, &next, &[], &[]),
		"closing a row keeps the route it held"
	);
}
