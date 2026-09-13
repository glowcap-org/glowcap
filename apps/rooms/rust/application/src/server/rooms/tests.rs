//! The room policy read as values: entrances, seating, presence, lines,
//! files, invitations, and what each asks the adapter to do.
use super::*;
use crate::{
	directory::{Event, RoomChange, creation::RecoveryKey, registration::Id},
	failure::FailureCode,
	room::{carries::Carries, message::ChangeKind, policy::RoomPolicy},
	server::{directory::Directory, document::Document, history, links::Authority},
};
use alloc::{format, vec};
use support::*;

mod file_clock;
mod support;

#[test]
fn opening_and_entering_seat_members_and_announce_the_room() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	assert_eq!(entrance.gate, Gate::Always);
	assert!(world.rooms.listed().next().is_none(), "an empty room is not listed");
	let seated = world.join(1, &entrance, "Alice");
	assert_eq!(seated.kind, MembershipKind::Participant);
	let heard = notices(&seated.effects, 1);
	// What the room carries comes before the occupancy that marks arrival, so
	// a client that returns from joining on that mark already holds it.
	assert_eq!(heard[0], &Notice::Carries(Carries::EVERYTHING));
	assert_eq!(heard[1], &Notice::Listed(true));
	assert!(matches!(heard[2], Notice::Join { nick, count: 1 } if nick == "Alice"));
	assert_eq!(heard[3], &Notice::Roster(vec!["Alice".into()]));
	assert!(
		matches!(&seated.effects.events[0], Event::Room { kind: RoomChange::Opened, entry } if entry.count.as_ref().unwrap().get() == 1)
	);
	assert_eq!(world.rooms.listed().count(), 1);
	// A second member enters by name and both hear the join.
	let bob_entrance = world.rooms.enter("garden", &world.authority).unwrap();
	assert_eq!(bob_entrance.gate, Gate::Public);
	let seated = world.join(2, &bob_entrance, "Bob");
	assert!(matches!(notices(&seated.effects, 1)[0], Notice::Join { nick, count: 2 } if nick == "Bob"));
	assert_eq!(
		notices(&seated.effects, 2).last(),
		Some(&&Notice::Roster(vec!["Alice".into(), "Bob".into()]))
	);
	assert!(matches!(
		&seated.effects.events[0],
		Event::Room {
			kind: RoomChange::Count,
			..
		}
	));
	// The name is taken, case-insensitively, and by publication too.
	let refused = world
		.rooms
		.open(3, open("GARDEN", RoomPolicy::Open), fresh(30), &world.authority)
		.unwrap_err();
	assert_eq!(refused.code, Some(FailureCode::RoomExists));
	let entry_id = alloc::string::String::from(world.rooms.listed().next().unwrap().id.text().as_str().unwrap());
	assert_eq!(world.rooms.enter_publication(&entry_id).unwrap().room, entrance.room);
	assert_eq!(
		world.rooms.enter("Nowhere", &world.authority).unwrap_err().code,
		Some(FailureCode::NoSuchRoom)
	);
}

#[test]
fn a_name_is_one_persons_and_a_reconnect_replaces_quietly() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	world.join(1, &entrance, "Alice");
	let refused = world
		.rooms
		.subscribe(
			2,
			&entrance,
			"alice",
			"i",
			None,
			"s",
			None,
			&mut world.directory,
			same,
			&world.authority,
			None,
		)
		.unwrap_err();
	assert_eq!(refused.refusal.code, Some(FailureCode::NickTaken));
	assert_eq!(refused.returned, vec!["i", "s"]);
	// A name held for direct messages by another connection is refused too.
	world
		.directory
		.register(
			3,
			crate::server::directory::Register {
				nick: "Carol".into(),
				allocation: crate::directory::registration::NicknameAllocation::Exact,
				locator: "x".into(),
				own_locator: true,
				webrtc: None,
				inbox: "c-inbox",
				voucher: None,
				claimant: None,
			},
			id(3),
			0,
		)
		.unwrap();
	let refused = world
		.rooms
		.subscribe(
			2,
			&entrance,
			"carol",
			"i",
			None,
			"s",
			None,
			&mut world.directory,
			same,
			&world.authority,
			None,
		)
		.unwrap_err();
	assert_eq!(refused.refusal.code, Some(FailureCode::NickTaken));
	// The same peer on a new connection takes its seat back without a word.
	let seated = world
		.rooms
		.subscribe(
			4,
			&entrance,
			"Alice",
			"i2",
			None,
			"s2",
			None,
			&mut world.directory,
			|a, b| (a, b) == (1, 4),
			&world.authority,
			None,
		)
		.unwrap();
	assert!(
		seated
			.effects
			.releases
			.iter()
			.any(|r| r.connection == 1 && r.capability == "Alice-inbox")
	);
	assert!(
		!seated
			.effects
			.tells
			.iter()
			.any(|t| matches!(t.notice, Notice::Join { .. } | Notice::Leave { .. }))
	);
	assert_eq!(world.rooms.nick_of(&entrance.room, 4), Some("Alice"));
	assert_eq!(world.rooms.nick_of(&entrance.room, 1), None);
	// Re-entering on the same connection under a new name is a rename.
	let seated = world.join(4, &entrance, "Alicia");
	assert!(matches!(notices(&seated.effects, 4)[1], Notice::Listed(true)));
	assert!(
		seated
			.effects
			.tells
			.iter()
			.any(|t| matches!(&t.notice, Notice::Leave { nick, .. } if nick == "Alice"))
	);
	assert!(
		seated
			.effects
			.tells
			.iter()
			.any(|t| matches!(&t.notice, Notice::Join { nick, .. } if nick == "Alicia"))
	);
}

#[test]
fn leaving_and_disconnecting_close_an_emptied_room() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	let seated = world.join(2, &entrance, "Bob");
	// Seating and leaving each name the connection whose presence changed,
	// so the adapter states it on the live trace.
	assert_eq!(seated.effects.presence, vec![2]);
	let bob = seated.membership;
	let effects = world.rooms.leave(&entrance.room, bob).unwrap();
	assert_eq!(effects.presence, vec![2]);
	assert!(effects.releases.contains(&Release {
		connection: 2,
		capability: "Bob-inbox"
	}));
	assert!(matches!(notices(&effects, 1)[0], Notice::Leave { nick, count: 1 } if nick == "Bob"));
	assert!(matches!(
		&effects.events[0],
		Event::Room {
			kind: RoomChange::Count,
			..
		}
	));
	assert_eq!(
		world.rooms.leave(&entrance.room, bob).unwrap_err().code,
		Some(FailureCode::NotRoomMember)
	);
	let effects = world.rooms.connection_closed(1);
	assert_eq!(effects.presence, vec![1]);
	assert!(
		matches!(&effects.events[0], Event::Room { kind: RoomChange::Closed, entry } if entry.name.text().as_str() == Some("Garden"))
	);
	assert_eq!(world.rooms.member_count(&entrance.room), 0);
	assert!(world.rooms.listed().next().is_none());
	assert_eq!(
		world.rooms.membership_kind(&entrance.room, alice).unwrap_err().code,
		Some(FailureCode::NotRoomMember)
	);
	// An opened room nobody entered goes with its opener.
	world.open(5, "Empty", RoomPolicy::Open);
	assert!(world.rooms.public_name_taken("empty"));
	world.rooms.connection_closed(5);
	assert!(!world.rooms.public_name_taken("empty"));
}

#[test]
fn lines_are_said_edited_and_withdrawn_with_history_kept() {
	let mut world = World::new(true);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	world.join(2, &entrance, "Bob");
	let (line, effects) = world.rooms.post(&entrance.room, alice, "hello", 5).unwrap();
	assert_eq!(effects.effects.tells.len(), 2);
	assert!(
		matches!(&effects.effects.tells[0].notice, Notice::Line { line, marker: Some((ChangeKind::Said, id)), files } if line.from == "Alice" && line.text == "hello" && id.get() == 1 && files.is_empty())
	);
	assert!(
		matches!(effects.persist.as_ref().unwrap(), history::Persist::Append { room, .. } if room == entrance.room.as_str())
	);
	let args = [Value::Text("hi there")];
	let effects = world.rooms.line_verb(1, line, "edit", &args, 0).unwrap();
	assert!(
		matches!(&effects.effects.tells[1].notice, Notice::Line { marker: Some((ChangeKind::Edited, _)), line, .. } if line.text == "hi there")
	);
	assert!(
		matches!(effects.persist.as_ref().unwrap(), history::Persist::Replace { tail, .. } if tail[0].text == "hi there")
	);
	let kept: alloc::vec::Vec<_> = world.rooms.history(&entrance.room, alice).unwrap().collect();
	assert_eq!(kept.len(), 1);
	assert_eq!(kept[0].text, "hi there");
	let effects = world.rooms.line_verb(2, line, "withdraw", &[] as &[Value], 0).unwrap();
	assert!(matches!(
		&effects.effects.tells[0].notice,
		Notice::Line {
			marker: Some((ChangeKind::Withdrawn, _)),
			..
		}
	));
	assert!(matches!(effects.persist.as_ref().unwrap(), history::Persist::Replace { tail, .. } if tail.is_empty()));
	// A withdrawn line's row is gone, so its reference answers nothing more:
	// a second withdraw and an edit meet the same refusal a line evicted
	// from history meets.
	assert!(!world.rooms.line_answers(line));
	assert_eq!(
		world
			.rooms
			.line_verb(1, line, "withdraw", &[] as &[Value], 0)
			.unwrap_err()
			.reason(),
		"that line can no longer be changed"
	);
	assert_eq!(
		world.rooms.line_verb(1, line, "edit", &args, 0).unwrap_err().reason(),
		"that line can no longer be changed"
	);
	let long = "x".repeat(crate::room::line::MAX_LINE_BYTES + 1);
	assert!(world.rooms.post(&entrance.room, alice, &long, 6).is_err());
	// Observers cannot speak, and history is not a method without retention.
	let mut quiet = World::new(false);
	let entrance = quiet.open(1, "Hall", RoomPolicy::Moderated);
	let seat = quiet.join(1, &entrance, "Alice").membership;
	assert_eq!(
		quiet.rooms.history(&entrance.room, seat).err().unwrap().reason(),
		"room membership has no method history"
	);
	let observer = quiet.rooms.enter("Hall", &quiet.authority).unwrap();
	assert_eq!(observer.kind, MembershipKind::Observer);
	let seat = quiet.join(2, &observer, "Bob").membership;
	assert_eq!(
		quiet.rooms.post(&entrance.room, seat, "x", 1).unwrap_err().code,
		Some(FailureCode::ReadOnlyMembership)
	);
}

#[test]
fn files_are_staged_posted_and_read_through_the_store() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	world.join(2, &entrance, "Bob");
	assert_eq!(
		world
			.rooms
			.post_files(&entrance.room, alice, "", 1, 0)
			.unwrap_err()
			.code,
		Some(FailureCode::UploadIncomplete)
	);
	let description = crate::files::FileDescription::parse("pic.png", "image/png", 3, 2, 2).unwrap();
	let upload = world.rooms.attach(&entrance.room, alice, description, 0).unwrap();
	let (line, effects) = world.rooms.post_files(&entrance.room, alice, "", 1, 0).unwrap();
	assert!(
		matches!(&effects.effects.tells[0].notice, Notice::Line { line, files, .. } if line.text == "pic.png" && files.len() == 1)
	);
	world
		.rooms
		.upload_verb(upload, "write", &[Value::Bytes(&[1, 2, 3])], 0)
		.unwrap();
	let blob = match &effects.effects.tells[1].notice {
		Notice::Line { files, .. } => files[0].clone(),
		_ => panic!("a file line"),
	};
	match world
		.rooms
		.blob_verb(&blob, "read", &[Value::Natural(0), Value::Natural(10)], 0)
		.unwrap()
	{
		crate::files::ReadOutcome::Ready(bytes) => assert_eq!(bytes, &[1, 2, 3]),
		crate::files::ReadOutcome::Waiting(_) => panic!("the bytes are there"),
	}
	// A refile down to nothing withdraws; the file goes with it.
	let effects = world.rooms.line_verb(1, line, "refile", &[Value::Text("")], 0).unwrap();
	assert!(matches!(
		&effects.effects.tells[0].notice,
		Notice::Line {
			marker: Some((ChangeKind::Withdrawn, _)),
			..
		}
	));
	assert!(
		world
			.rooms
			.blob_verb(&blob, "read", &[Value::Natural(0), Value::Natural(10)], 0)
			.is_err()
	);
	// A spent upload is refused, and the idle clock reclaims a quiet one.
	assert!(
		world
			.rooms
			.upload_verb(upload, "write", &[Value::Bytes(&[1])], 0)
			.is_err()
	);
	let description = crate::files::FileDescription::parse("slow.bin", "", 5, 0, 0).unwrap();
	let quiet = world.rooms.attach(&entrance.room, alice, description, 0).unwrap();
	assert!(world.rooms.next_upload_deadline().is_some());
	world.rooms.advance(crate::files::UPLOAD_IDLE_MS + 1);
	assert_eq!(
		world
			.rooms
			.upload_verb(quiet, "discard", &[] as &[Value], crate::files::UPLOAD_IDLE_MS + 1)
			.unwrap_err()
			.code,
		Some(FailureCode::UploadIncomplete)
	);
}

#[test]
fn invitations_admit_one_claimant_and_end_with_their_minter() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Secret", RoomPolicy::Private);
	assert!(!world.rooms.public_name_taken("secret"));
	let alice = world.join(1, &entrance, "Alice").membership;
	let invitation = world
		.rooms
		.mint_invitation(&entrance.room, alice, MembershipKind::Observer)
		.unwrap();
	assert!(world.rooms.claim_invitation(invitation, "short").is_err());
	let receipt = "0123456789abcdef0123456789abcdef";
	let claimed = world.rooms.claim_invitation(invitation, receipt).unwrap();
	assert_eq!(claimed.kind, MembershipKind::Observer);
	assert!(matches!(claimed.gate, Gate::Invitation(_)));
	assert_eq!(
		world
			.rooms
			.claim_invitation(invitation, "ffffffffffffffffffffffffffffffff")
			.unwrap_err()
			.reason(),
		"this room invitation was claimed already"
	);
	// The same receipt claims again after a lost answer; one seat is admitted.
	let again = world.rooms.claim_invitation(invitation, receipt).unwrap();
	let seated = world.join(2, &again, "Bob");
	assert_eq!(seated.kind, MembershipKind::Observer);
	let refused = world
		.rooms
		.subscribe(
			3,
			&claimed,
			"Carol",
			"i",
			None,
			"s",
			None,
			&mut world.directory,
			same,
			&world.authority,
			None,
		)
		.unwrap_err();
	assert_eq!(refused.refusal.code, Some(FailureCode::NoSuchRoom));
	// The minter leaving retires what it let in.
	let other = world
		.rooms
		.mint_invitation(&entrance.room, alice, MembershipKind::Participant)
		.unwrap();
	world.rooms.leave(&entrance.room, alice).unwrap();
	assert_eq!(
		world.rooms.claim_invitation(other, receipt).unwrap_err().reason(),
		"this room invitation has ended"
	);
}

#[test]
fn presence_topic_away_typing_and_kick_say_the_rooms_word() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	let effects = world.rooms.away(&entrance.room, alice, "lunch").unwrap();
	assert!(matches!(&effects.tells[0].notice, Notice::Away { nick, why } if nick == "Alice" && why == "lunch"));
	assert!(
		world
			.rooms
			.away(&entrance.room, alice, "lunch")
			.unwrap()
			.tells
			.is_empty()
	);
	// A public room's topic is remembered under its name, link or no link.
	let remembered = world
		.rooms
		.prepare_topic(&entrance.room, "seeds", &world.authority)
		.unwrap()
		.expect("a change")
		.expect("persisted first");
	assert_eq!(remembered.topic("Garden"), Some("seeds"));
	world.authority = remembered;
	let effects = world.rooms.commit_topic(&entrance.room, "seeds");
	assert!(matches!(&effects.tells[0].notice, Notice::Topic { text, changed: true } if text == "seeds"));
	assert_eq!(
		world
			.rooms
			.prepare_topic(&entrance.room, "seeds", &world.authority)
			.unwrap(),
		None
	);
	assert_eq!(world.rooms.durable_name(&entrance.room), Some("Garden"));
	// An arrival is told who is away and what the room is about.
	let bob = world.join(2, &entrance, "Bob");
	let heard = notices(&bob.effects, 2);
	assert!(
		heard
			.iter()
			.any(|n| matches!(n, Notice::Away { nick, .. } if nick == "Alice"))
	);
	assert!(
		heard
			.iter()
			.any(|n| matches!(n, Notice::Topic { text, changed: false } if text == "seeds"))
	);
	let effects = world.rooms.typing(&entrance.room, bob.membership, true).unwrap();
	assert_eq!(effects.tells.len(), 1, "the typer is not told");
	assert_eq!(effects.tells[0].connection, 1);
	let effects = world.rooms.kick(&entrance.room, "bob").unwrap();
	assert!(matches!(&effects.tells[0].notice, Notice::Said(text) if text == "Bob was asked to leave"));
	assert!(
		effects.tells.iter().any(|t| t.connection == 2
			&& matches!(&t.notice, Notice::Ended(text) if text == "You were asked to leave #Garden."))
	);
	assert_eq!(world.rooms.member_count(&entrance.room), 1);
	assert_eq!(
		world.rooms.kick(&entrance.room, "nobody").unwrap_err().reason(),
		"nobody here answers to \"nobody\""
	);
}

#[test]
fn durable_entrances_rebuild_a_room_and_follow_its_authority() {
	let mut world = World::new(false);
	world.authority = world
		.authority
		.remembered("Garden", false, false, Some("kept topic"), None)
		.unwrap()
		.unwrap();
	let entrance = world
		.rooms
		.durable_entrance("Garden", MembershipKind::Participant, &world.authority);
	assert_eq!(
		entrance.gate,
		Gate::Link {
			name: "Garden".into(),
			generation: 0
		}
	);
	assert_eq!(world.rooms.called(&entrance, &world.authority), "Garden");
	assert_eq!(world.rooms.policy(&entrance, &world.authority), RoomPolicy::Open);
	let seated = world.join(1, &entrance, "Alice");
	assert!(
		notices(&seated.effects, 1)
			.iter()
			.any(|n| matches!(n, Notice::Topic { text, changed: false } if text == "kept topic"))
	);
	assert_eq!(world.rooms.listed().count(), 1);
	// Entering by name reaches the same live room now.
	assert_eq!(
		world.rooms.enter("garden", &world.authority).unwrap().room,
		entrance.room
	);
	// A revoked link closes the entrance to newcomers but not to the seated.
	world.authority = world.authority.with_room_link_revoked("Garden").unwrap();
	assert!(world.rooms.gate_open(1, &entrance, &world.authority));
	assert!(!world.rooms.gate_open(2, &entrance, &world.authority));
	let refused = world
		.rooms
		.subscribe(
			2,
			&entrance,
			"Bob",
			"i",
			None,
			"s",
			None,
			&mut world.directory,
			same,
			&world.authority,
			Some(fresh(9)),
		)
		.unwrap_err();
	assert_eq!(refused.refusal.reason(), "no-such-room: this room link was revoked");
	// A managed room enters by its public name under its generation.
	let id = "~00000000000000000000000000000007";
	world.authority = world
		.authority
		.remembered(
			id,
			false,
			true,
			None,
			Some(crate::server::links::Registration {
				name: "Yard",
				policy: RoomPolicy::Moderated,
			}),
		)
		.unwrap()
		.unwrap();
	let managed = world.rooms.enter("yard", &world.authority).unwrap();
	assert_eq!(
		managed.gate,
		Gate::Managed {
			id: id.into(),
			generation: 1
		}
	);
	assert_eq!(managed.kind, MembershipKind::Observer);
	assert_eq!(world.rooms.called(&managed, &world.authority), "Yard");
	let seated = world.join(3, &managed, "Carol");
	assert_eq!(seated.kind, MembershipKind::Observer);
	// A policy change renames the live room and tells its members.
	world.authority = world
		.authority
		.with_managed_room_policy(id, "Lawn", RoomPolicy::Open)
		.unwrap()
		.unwrap();
	let effects = world.rooms.policy_changed(id, &world.authority).unwrap();
	assert!(matches!(
		&effects.tells[0].notice,
		Notice::PolicyChanged(RoomPolicy::Open)
	));
	assert!(
		matches!(&effects.events[0], Event::Room { kind: RoomChange::Closed, entry } if entry.name.text().as_str() == Some("Yard"))
	);
	assert!(
		matches!(&effects.events[1], Event::Room { kind: RoomChange::Opened, entry } if entry.name.text().as_str() == Some("Lawn"))
	);
	assert!(
		!world.rooms.gate_open(4, &managed, &world.authority),
		"the old generation is retired"
	);
	assert!(world.rooms.enter("Lawn", &world.authority).is_ok());
	let effects = world
		.rooms
		.authority_changed(id, crate::room::stewardship::Kind::Steward, "tok");
	assert!(matches!(&effects.tells[0].notice, Notice::AuthorityChanged { token, .. } if token == "tok"));
}
