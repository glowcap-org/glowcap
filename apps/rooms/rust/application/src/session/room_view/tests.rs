//! Room membership is replaced by a roster and removed by an exact departure.
use super::*;
use crate::{
	fields::List,
	room::policy::{MembershipKind, RoomPolicy},
};

fn view() -> RoomView {
	RoomView {
		conversation_id: Text::new("room".into()).unwrap(),
		membership_kind: MembershipKind::Participant,
		policy: RoomPolicy::Open,
		members: List::default(),
		members_more: None,
		subject: Nullable::Null,
		line_bytes: Nullable::Null,
		bridge: FieldPresence::Missing,
		carries: None,
		can_set_subject: None,
		can_post_files: None,
		can_moderate: None,
	}
}
fn member<'a>(view: &'a RoomView, name: &str) -> Option<&'a Member> {
	find(&view.members.0, name).map(|index| &view.members.0[index].1)
}

#[test]
fn departure_removes_membership_and_late_updates_cannot_restore_it() {
	let mut view = view();
	apply(
		&mut view,
		Some(&Presence::Roster {
			names: alloc::vec!["ada", "bo"],
		}),
		None,
	);
	apply(
		&mut view,
		Some(&Presence::Away {
			name: "ada",
			reason: "lunch",
		}),
		None,
	);
	apply(&mut view, Some(&Presence::Leave { name: "ada" }), None);
	assert!(member(&view, "ada").is_none());
	assert!(member(&view, "bo").unwrap().online);
	apply(&mut view, Some(&Presence::Leave { name: "unknown" }), None);
	apply(
		&mut view,
		Some(&Presence::Away {
			name: "ada",
			reason: "back",
		}),
		None,
	);
	apply(
		&mut view,
		Some(&Presence::Seat(alloc::boxed::Box::new(
			crate::room::inbox::metadata::Seat {
				name: "ada",
				network: "Libera",
				state: "linked",
				nick: "ada_irc",
				badge: "IRC",
				said: "Linked",
			},
		))),
		None,
	);
	assert!(member(&view, "ada").is_none());
	assert_eq!(view.members.0.len(), 1);
	apply(&mut view, Some(&Presence::Join { name: "ada" }), None);
	let ada = member(&view, "ada").unwrap();
	assert!(ada.online);
	assert_eq!(ada.away.text().as_str(), Some(""));
	assert!(ada.seat.is_none());
}

#[test]
fn roster_replaces_membership_preserving_only_current_away_state() {
	let mut view = view();
	apply(
		&mut view,
		Some(&Presence::Roster {
			names: alloc::vec!["ada", "bo"],
		}),
		None,
	);
	apply(
		&mut view,
		Some(&Presence::Away {
			name: "bo",
			reason: "reading",
		}),
		None,
	);
	apply(
		&mut view,
		Some(&Presence::Seat(alloc::boxed::Box::new(
			crate::room::inbox::metadata::Seat {
				name: "bo",
				network: "Libera",
				state: "linked",
				nick: "bo_irc",
				badge: "IRC",
				said: "Linked",
			},
		))),
		None,
	);
	apply(
		&mut view,
		Some(&Presence::Roster {
			names: alloc::vec!["bo", "cy"],
		}),
		None,
	);
	assert!(member(&view, "ada").is_none());
	let bo = member(&view, "bo").unwrap();
	assert!(bo.online);
	assert_eq!(bo.away.text().as_str(), Some("reading"));
	assert!(bo.seat.is_none());
	assert!(member(&view, "cy").unwrap().online);
	apply::<&str>(&mut view, Some(&Presence::Roster { names: alloc::vec![] }), None);
	assert!(view.members.0.is_empty());
}

#[test]
fn departed_member_frees_capacity_for_another_join() {
	let mut view = view();
	let names: Vec<_> = (0..super::super::snapshot::views::MAX_MEMBERS)
		.map(|index| alloc::format!("member-{index}"))
		.collect();
	apply(&mut view, Some(&Presence::Roster { names }), None);
	apply(&mut view, Some(&Presence::Join { name: "extra" }), None);
	assert_eq!(view.members_more, Some(true));
	assert!(member(&view, "extra").is_none());
	apply(&mut view, Some(&Presence::Leave { name: "member-0" }), None);
	apply(&mut view, Some(&Presence::Join { name: "extra" }), None);
	assert!(member(&view, "extra").unwrap().online);
	assert!(member(&view, "member-0").is_none());
}

#[test]
fn disconnection_clears_reachability_and_return_restores_online_presence() {
	let mut view = view();
	apply(
		&mut view,
		Some(&Presence::Roster {
			names: alloc::vec!["ada", "bo"],
		}),
		None,
	);
	apply(
		&mut view,
		Some(&Presence::Away {
			name: "bo",
			reason: "lunch",
		}),
		None,
	);
	apply(
		&mut view,
		Some(&Presence::Offline {
			names: alloc::vec!["bo", "cy"],
		}),
		None,
	);
	for name in ["bo", "cy"] {
		let offline = member(&view, name).unwrap();
		assert!(!offline.online);
		assert_eq!(offline.away.text().as_str(), Some(""));
		assert!(offline.seat.is_none());
	}
	assert!(member(&view, "ada").unwrap().online);
	apply(
		&mut view,
		Some(&Presence::Away {
			name: "bo",
			reason: "late",
		}),
		None,
	);
	apply(
		&mut view,
		Some(&Presence::Seat(alloc::boxed::Box::new(
			crate::room::inbox::metadata::Seat {
				name: "bo",
				network: "Libera",
				state: "linked",
				nick: "bo_irc",
				badge: "IRC",
				said: "Linked",
			},
		))),
		None,
	);
	let bo = member(&view, "bo").unwrap();
	assert!(!bo.online);
	assert_eq!(bo.away.text().as_str(), Some(""));
	assert!(bo.seat.is_none(), "late details cannot restore live membership");
	apply(&mut view, Some(&Presence::Join { name: "bo" }), None);
	assert!(member(&view, "bo").unwrap().online);
	apply(&mut view, Some(&Presence::Leave { name: "cy" }), None);
	assert!(member(&view, "cy").is_none());
	let encoded = serde_json::to_string(&Presence::Offline {
		names: alloc::vec!["bo"],
	})
	.unwrap();
	let event: crate::session::event::Presence = serde_json::from_str(&encoded).unwrap();
	assert!(
		matches!(event, crate::session::event::Presence::Offline { names } if names.as_slice()[0].text().as_str() == Some("bo"))
	);
	let oversized = alloc::format!(
		"{{\"kind\":\"offline\",\"names\":[{}]}}",
		alloc::vec!["\"bo\""; crate::server::rooms::MAX_ROOM_OFFLINE + 1].join(",")
	);
	assert!(serde_json::from_str::<crate::session::event::Presence>(&oversized).is_err());
}

#[test]
fn a_subject_fact_replaces_the_view_and_an_empty_one_takes_it_down() {
	use crate::room::{inbox::metadata::facts, subject::Subject};
	let line = |args: &[&str]| {
		args.iter()
			.map(|arg| alloc::string::String::from(*arg))
			.collect::<Vec<_>>()
	};
	let mut view = view();
	let linked = line(&["room", "", "subject", "chess", "ocapn://host.tcp/s/Y2hlc3M"]);
	apply(&mut view, None, facts(&linked).as_ref());
	let stated = Subject::new("chess", Some("ocapn://host.tcp/s/Y2hlc3M")).unwrap();
	let board = crate::session::subject::Subject::from_room(&stated).unwrap();
	assert!(matches!(&view.subject, Nullable::Value(held) if *held == board));
	let encoded = serde_json::to_value(&view).unwrap();
	assert_eq!(
		encoded["subject"],
		serde_json::json!({"description":"chess","link":"ocapn://host.tcp/s/Y2hlc3M"})
	);
	let reread: RoomView = serde_json::from_str(&serde_json::to_string(&encoded).unwrap()).unwrap();
	assert!(matches!(reread.subject, Nullable::Value(held) if held == board));
	// A description the browser kept as UTF-16, lone surrogate included, reads
	// back exactly.
	let surrogate: crate::session::subject::Subject = serde_json::from_str(r#"{"description":"a\ud800b"}"#).unwrap();
	assert_eq!(surrogate.description().utf16().collect::<Vec<_>>(), [97, 0xd800, 98]);
	assert!(
		serde_json::from_str::<crate::session::subject::Subject>(
			r#"{"description":"a","link":"ocapn://h.tcp/s/\ud800"}"#
		)
		.is_err()
	);
	let taken_down = line(&["room", "", "subject", ""]);
	apply(&mut view, None, facts(&taken_down).as_ref());
	assert!(matches!(view.subject, Nullable::Null));
	// A link without a description, more than a link, or a link of another
	// scheme is no subject fact.
	for refused in [
		line(&["room", "", "subject", "", "ocapn://host.tcp/s/Y2hlc3M"]),
		line(&["room", "", "subject", "chess", "ocapn://host.tcp/s/Y2hlc3M", "more"]),
		line(&["room", "", "subject", "chess", "https://host/s/x"]),
	] {
		assert!(facts(&refused).is_none(), "{refused:?}");
	}
}
