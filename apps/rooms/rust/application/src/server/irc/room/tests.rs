use super::*;
use crate::server::irc::protocol::parse_line;

fn line(text: &str) -> Message {
	parse_line(text).unwrap()
}
fn room() -> Room<u32, &'static str> {
	Room::new("fixture", "#news", "gwbot", "pub-1", "127.0.0.1:1").unwrap()
}
fn no_view(_: u32) -> Option<View> {
	None
}
fn no_seat(_: &str) -> bool {
	false
}
fn tells<'a>(effects: &'a Effects<u32, &'static str>, connection: u32) -> Vec<&'a Notice> {
	effects
		.tells
		.iter()
		.filter(|(c, _, _)| *c == connection)
		.map(|(_, _, n)| n)
		.collect()
}

#[test]
fn replacing_a_reader_preserves_feed_demand_and_releases_its_old_inbox() {
	let mut room = room();
	room.subscribe(1, "reader", "old", MembershipKind::Participant, "note", 400, &no_view)
		.unwrap();
	room.relay().connected();
	room.observe(&line(":gwbot!u@h JOIN :#news"), &no_seat, &no_view)
		.unwrap();
	let effects = room
		.subscribe(1, "renamed", "new", MembershipKind::Observer, "note", 400, &no_view)
		.unwrap();
	assert!(effects.relay.is_empty(), "replacement emitted a feed PART/JOIN");
	assert_eq!(effects.releases, [(1, "old")]);
	assert_eq!(effects.presence, [1]);
	assert_eq!(room.membership_kind(1).unwrap(), MembershipKind::Observer);
	assert!(tells(&effects, 1)
		.iter()
		.any(|notice| matches!(notice, Notice::Leave { nick, .. } if nick == "reader")));
	assert!(room.prepare_post(1, "read only").is_err());
}

#[test]
fn the_room_is_built_on_ircs_terms() {
	assert!(Room::<u32, u8>::new("bad name", "#c", "n", "p", "o").is_err());
	assert!(Room::<u32, u8>::new("net", "chan", "n", "p", "o").is_err());
	assert!(Room::<u32, u8>::new("net", "#a b", "n", "p", "o").is_err());
	let room = room();
	assert_eq!(room.name(), "fixture/#news");
	assert_eq!(room.info().kind, PublicationKind::Bridge);
	assert!(room.line_bytes() > 300);
}

#[test]
fn a_reader_is_seated_told_the_room_and_hears_the_channel() {
	let mut room = room();
	let refused = room
		.subscribe(
			1,
			"irc/fake",
			"inbox",
			MembershipKind::Participant,
			"note",
			400,
			&no_view,
		)
		.unwrap_err();
	assert!(refused.detail.contains("reserved"));
	let effects = room
		.subscribe(1, "reader", "inbox", MembershipKind::Participant, "note", 400, &no_view)
		.unwrap();
	let heard = tells(&effects, 1);
	assert!(matches!(heard[0], Notice::Join { .. }));
	assert!(matches!(heard[1], Notice::LineBytes { bytes: 400, .. }));
	assert!(matches!(heard[2], Notice::Bridge { .. }));
	assert!(matches!(heard[3], Notice::Roster { .. }));
	assert!(effects.count_changed);
	// The feed joins, and the channel's names arrive as irc/ members.
	room.relay().connected();
	room.observe(&line(":gwbot!u@h JOIN :#news"), &no_seat, &no_view)
		.unwrap();
	room.observe(
		&line(":s 353 gwbot = #news :gwbot @alice reader"),
		&|nick| nick == "reader",
		&no_view,
	)
	.unwrap();
	let effects = room
		.observe(&line(":s 366 gwbot #news :end"), &no_seat, &no_view)
		.unwrap();
	let Notice::Roster { names, .. } = &tells(&effects, 1)[0] else {
		panic!("no roster");
	};
	assert_eq!(names, &["irc/alice", "reader"]);
	let effects = room
		.observe(
			&line(":alice!u@h PRIVMSG #news :\u{1}ACTION dances\u{1}"),
			&no_seat,
			&no_view,
		)
		.unwrap();
	assert!(
		matches!(&tells(&effects, 1)[0], Notice::Line { from, text } if from == "irc/alice" && text == "/me dances")
	);
	let effects = room
		.observe(&line(":alice!u@h TOPIC #news :ship day"), &no_seat, &no_view)
		.unwrap();
	assert!(matches!(&tells(&effects, 1)[0], Notice::Topic(topic) if topic == "ship day"));
	let effects = room.observe(&line(":alice!u@h NICK :al"), &no_seat, &no_view).unwrap();
	assert!(matches!(&tells(&effects, 1)[0], Notice::Leave { said, .. } if said == "irc/alice is now irc/al"));
	// The seated member's own echo is not a second arrival.
	let effects = room
		.observe(
			&line(":reader!u@h PRIVMSG #news :hi"),
			&|nick| nick == "reader",
			&no_view,
		)
		.unwrap();
	assert!(effects.tells.is_empty());
	let effects = room.observe(&line(":al!u@h QUIT :bye"), &no_seat, &no_view).unwrap();
	assert!(matches!(&tells(&effects, 1)[0], Notice::Leave { nick, .. } if nick == "irc/al"));
	let post = room.prepare_post(1, "hello").unwrap();
	assert_eq!(post.from, "reader");
	assert!(room.prepare_post(2, "x").is_err());
	let effects = room.away(1, "lunch").unwrap();
	assert!(matches!(&tells(&effects, 1)[0], Notice::Away { why, .. } if why == "lunch"));
	let effects = room.retire(1, Some("parted"));
	assert!(matches!(tells(&effects, 1)[0], Notice::Ended(_)));
	assert_eq!(effects.releases, [(1, "inbox")]);
	assert!(!room.is_member(1));
}

#[test]
fn a_disconnect_clears_the_irc_roster_once() {
	let mut room = room();
	room.subscribe(1, "reader", "inbox", MembershipKind::Participant, "", 1, &no_view)
		.unwrap();
	room.relay().connected();
	room.observe(&line(":gwbot!u@h JOIN :#news"), &no_seat, &no_view)
		.unwrap();
	room.observe(&line(":alice!u@h JOIN :#news"), &no_seat, &no_view)
		.unwrap();
	let effects = room.disconnected(&no_view);
	assert!(
		matches!(&tells(&effects, 1)[0], Notice::Roster { said, names } if said == "the IRC connection ended" && names == &["reader"])
	);
	assert!(room.disconnected(&no_view).tells.is_empty());
}
