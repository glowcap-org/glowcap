use rooms_application::{
	directory::{Event, Member, MemberChange, RoomChange, RoomInfo, Snapshot},
	fields::{Nullable, Text},
	room::policy::MembershipKind,
	session::directory::{DirectoryView, MAX_ROWS},
};
use serde_json::Value;
const FIRST: &str = "11111111-1111-4111-8111-111111111111";
const SECOND: &str = "22222222-2222-4222-8222-222222222222";
fn text<const N: usize, const E: bool>(s: &str) -> Text<N, E> {
	Text::new(s.into()).unwrap()
}
fn member(name: &str, registration: &str) -> Member {
	Member {
		name: text(name),
		registration_id: registration.into(),
	}
}
fn peer_event(name: &str, registration: &str, kind: MemberChange) -> Event {
	Event::Member {
		kind,
		peer: member(name, registration),
		count: 1,
	}
}
fn snapshot(rooms: Vec<RoomInfo>) -> Snapshot {
	Snapshot {
		rooms,
		peers: vec![],
		omitted: 0,
	}
}
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/directory-view.json")).unwrap();
	assert_eq!(fixture["limit"], MAX_ROWS);
	let initial: Vec<RoomInfo> = serde_json::from_str(&fixture["initial"].to_string()).unwrap();
	let mut view = DirectoryView::new(text("directory"), snapshot(initial.clone()));
	for row in fixture["trace"].as_array().unwrap() {
		let event = &row["event"];
		let event = match event["kind"].as_str().unwrap() {
			"truncated" => Event::Truncated(1),
			"registered" | "unregistered" => peer_event(
				event["name"].as_str().unwrap(),
				event["registrationId"].as_str().unwrap(),
				if event["kind"] == "registered" {
					MemberChange::Registered
				} else {
					MemberChange::Unregistered
				},
			),
			kind => Event::Room {
				kind: match kind {
					"opened" => RoomChange::Opened,
					"closed" => RoomChange::Closed,
					_ => RoomChange::Count,
				},
				entry: serde_json::from_str(&event["entry"].to_string()).unwrap(),
			},
		};
		assert_eq!(view.apply(event).view, row["changed"].as_bool().unwrap());
		assert_eq!(serde_json::to_value(view.snapshot(MAX_ROWS)).unwrap(), row["snapshot"]);
	}
	let mut view = DirectoryView::new(text("a"), snapshot(initial.clone()));
	let other = DirectoryView::new(text("b"), snapshot(initial.clone()));
	let mut room = initial[0].clone();
	room.offers = Nullable::Value(MembershipKind::Observer);
	assert!(
		view.apply(Event::Room {
			kind: RoomChange::Count,
			entry: room
		})
		.view
	);
	assert_eq!(
		other.room(&"garden".into()).unwrap().offers,
		Nullable::Value(MembershipKind::Participant)
	);
	for i in 0..MAX_ROWS {
		assert!(
			view.apply(peer_event(&format!("peer-{i}"), FIRST, MemberChange::Registered))
				.view
		);
	}
	assert!(view.apply(peer_event("PEER-0", SECOND, MemberChange::Registered)).view);
	assert!(!view.apply(peer_event("peer-0", FIRST, MemberChange::Unregistered)).view);
	assert_eq!(view.peer(&"peer-0".into()).unwrap().registration_id, SECOND.into());
	assert_eq!(view.snapshot(MAX_ROWS).peers().len(), MAX_ROWS - initial.len());
	assert!(view.snapshot(MAX_ROWS).truncated);
	assert_eq!(view.snapshot(1).rooms.len(), 1);
	assert_eq!(view.snapshot(usize::MAX).peers().len(), MAX_ROWS - initial.len());
	let rooms = (0..MAX_ROWS + 1)
		.map(|i| {
			let mut room = initial[0].clone();
			room.id = text(&format!("room-{i}"));
			room
		})
		.collect();
	let mut full = DirectoryView::new(text("full"), snapshot(rooms));
	assert!(full.snapshot(MAX_ROWS).truncated);
	assert_eq!(full.snapshot(MAX_ROWS).rooms.len(), MAX_ROWS);
	assert!(!full.apply(Event::Truncated(9)).view);
	assert!(full.room(&format!("room-{MAX_ROWS}").into()).is_none());
	// Case conversion preserves contextual Unicode lowercase rules.
	let mut unicode = DirectoryView::new(text("unicode"), snapshot(vec![]));
	unicode.apply(peer_event("ΟΣ", FIRST, MemberChange::Registered));
	assert!(unicode.peer(&"ος".into()).is_some());
	assert!(unicode.peer(&"οσ".into()).is_none());
}
