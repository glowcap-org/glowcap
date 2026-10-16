use super::*;
use crate::{room::carries::Carries, server::irc::protocol::parse_line};

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
	assert!(
		tells(&effects, 1)
			.iter()
			.any(|notice| matches!(notice, Notice::Leave { nick, .. } if nick == "reader"))
	);
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
fn exhausted_line_identity_refuses_before_a_post_is_admitted() {
	let mut room = room();
	room.subscribe(1, "reader", "inbox", MembershipKind::Participant, "", 400, &no_view)
		.unwrap();
	room.next_line = 1_u64 << 53;
	let refused = room.prepare_post(1, "never admitted").unwrap_err();
	assert_eq!(refused.reason(), "IRC bridge line identifiers exhausted");
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
	// IRC keeps no link previews and relays no typing, and a client returns
	// from joining on the roster, so this arrives before it.
	assert_eq!(heard[1], &Notice::Carries(Carries::NOTHING));
	assert!(matches!(heard[2], Notice::LineBytes { bytes: 400, .. }));
	assert!(matches!(heard[3], Notice::Bridge { .. }));
	assert!(matches!(heard[4], Notice::Roster { .. }));
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
		matches!(&tells(&effects, 1)[0], Notice::Line { from, text, line: id } if from == "irc/alice" && text == "/me dances" && id.get() == 1)
	);
	let effects = room
		.observe(&line(":alice!u@h TOPIC #news :ship day"), &no_seat, &no_view)
		.unwrap();
	assert!(
		matches!(&tells(&effects, 1)[0], Notice::Subject { subject, changed: true } if subject.description() == "ship day")
	);
	// A topic the room cannot hold as a subject is said as a plain line.
	let effects = room
		.observe(
			&line(":alice!u@h TOPIC #news :ocapn://peer.tcp/s/x the board"),
			&no_seat,
			&no_view,
		)
		.unwrap();
	assert!(
		matches!(&tells(&effects, 1)[0], Notice::Announcement(said) if said.ends_with("ocapn://peer.tcp/s/x the board"))
	);
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
	let effects = room.commit_post(&post);
	assert!(
		matches!(&tells(&effects, 1)[0], Notice::Line { from, text, line: id } if from == "reader" && text == "hello" && id.get() == 2)
	);
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

#[test]
fn the_channels_subject_reaches_every_arrival_and_clears_when_the_channel_has_none() {
	let subject = |notice: &&Notice| match notice {
		Notice::Subject { subject, .. } => Some(String::from(subject.description())),
		_ => None,
	};
	let mut room = room();
	room.subscribe(1, "reader", "one", MembershipKind::Participant, "note", 400, &no_view)
		.unwrap();
	room.relay().connected();
	room.observe(&line(":gwbot!u@h JOIN :#news"), &no_seat, &no_view)
		.unwrap();
	let effects = room
		.observe(&line(":s 332 gwbot #news :ship day"), &no_seat, &no_view)
		.unwrap();
	assert_eq!(
		tells(&effects, 1).iter().filter_map(subject).collect::<Vec<_>>(),
		["ship day"]
	);
	let effects = room
		.observe(&line(":s 366 gwbot #news :end"), &no_seat, &no_view)
		.unwrap();
	assert!(tells(&effects, 1).iter().all(|notice| subject(notice).is_none()));
	// A later arrival hears the subject the channel already has.
	let effects = room
		.subscribe(2, "late", "two", MembershipKind::Participant, "note", 400, &no_view)
		.unwrap();
	assert_eq!(
		tells(&effects, 2).iter().filter_map(subject).collect::<Vec<_>>(),
		["ship day"]
	);
	// The same topic again says nothing.
	let effects = room
		.observe(&line(":alice!u@h TOPIC #news :ship day"), &no_seat, &no_view)
		.unwrap();
	assert!(tells(&effects, 1).is_empty());
	// Rejoined, the channel says no topic before its names end: it has none.
	room.disconnected(&no_view);
	room.relay().connected();
	room.observe(&line(":gwbot!u@h JOIN :#news"), &no_seat, &no_view)
		.unwrap();
	let effects = room
		.observe(&line(":s 366 gwbot #news :end"), &no_seat, &no_view)
		.unwrap();
	assert_eq!(tells(&effects, 2).iter().filter_map(subject).collect::<Vec<_>>(), [""]);
	// A topic the room cannot hold takes the one before it down.
	room.observe(&line(":alice!u@h TOPIC #news :seeds"), &no_seat, &no_view)
		.unwrap();
	let effects = room
		.observe(
			&line(":alice!u@h TOPIC #news :ocapn://peer.tcp/s/x board"),
			&no_seat,
			&no_view,
		)
		.unwrap();
	let told = tells(&effects, 1);
	assert!(matches!(told[0], Notice::Announcement(_)));
	assert_eq!(told.iter().filter_map(subject).collect::<Vec<_>>(), [""]);
	// A rejoin that says the same refused topic again repeats nothing.
	room.disconnected(&no_view);
	room.relay().connected();
	room.observe(&line(":gwbot!u@h JOIN :#news"), &no_seat, &no_view)
		.unwrap();
	let effects = room
		.observe(
			&line(":s 332 gwbot #news :ocapn://peer.tcp/s/x board"),
			&no_seat,
			&no_view,
		)
		.unwrap();
	assert!(tells(&effects, 1).is_empty());
	// IRC formatting stays in a subject, as it does in a line.
	let effects = room
		.observe(&line(":alice!u@h TOPIC #news :\u{2}ship\u{2} day"), &no_seat, &no_view)
		.unwrap();
	assert_eq!(
		tells(&effects, 1).iter().filter_map(subject).collect::<Vec<_>>(),
		["\u{2}ship\u{2} day"]
	);
}
