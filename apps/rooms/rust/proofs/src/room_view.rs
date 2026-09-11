//! Presence reduction belongs to the shared application, before UI projection.
use rooms_application::{
	room::inbox::metadata::{Presence, Seat},
	session::{
		room_view::apply,
		snapshot::views::{RoomView, SeatPhase},
	},
};

pub fn run() {
	let mut view: RoomView = serde_json::from_str(
		r#"{
		"conversationId": "room", "membershipKind": "participant",
		"policy": ["listed", "open", "open"], "members": [],
		"topic": null, "lineBytes": null
	}"#,
	)
	.unwrap();
	let roster = Presence::Roster {
		names: vec!["alice", "irc/bo"],
	};
	apply(&mut view, Some(&roster), None);
	for (state, expected) in [
		("connecting", SeatPhase::Connecting),
		("linked", SeatPhase::Linked),
		("failed", SeatPhase::Failed),
		("rooms", SeatPhase::Rooms),
	] {
		apply(&mut view, Some(&seat("alice", state)), None);
		assert_eq!(view.members.as_slice().len(), 2);
		let held = view.members.as_slice()[0].1.seat.as_ref().unwrap();
		assert_eq!(held.state, expected);
		assert_eq!(held.nick.text().as_str(), Some("alice_irc"));
		apply(&mut view, Some(&seat("nobody", "linked")), None);
		assert_eq!(view.members.as_slice().len(), 2, "a seat cannot mint membership");
	}
	apply(
		&mut view,
		Some(&Presence::Away {
			name: "alice",
			reason: "lunch",
		}),
		None,
	);
	apply(&mut view, Some(&roster), None);
	let alice = &view.members.as_slice()[0].1;
	assert!(alice.seat.is_none(), "a new roster must retire stale seat state");
	assert_eq!(alice.away.text().as_str(), Some("lunch"));
}

fn seat(name: &'static str, state: &'static str) -> Presence<&'static str> {
	Presence::Seat(Box::new(Seat {
		name,
		state,
		nick: "alice_irc",
		network: "Libera",
		badge: "SEAT",
		said: "seat state",
	}))
}
