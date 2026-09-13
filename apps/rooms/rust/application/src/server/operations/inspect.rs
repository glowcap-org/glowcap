//! The diagnostic snapshot: what a holder of the inspect capability reads
//! about this server, as `[kind, name, note]` rows. It names what is
//! published and who is here and never hands out what would let a reader
//! act, so the retained references are the one inventory it omits.
use super::{
	faces::{link_face, shown, stewardship_rows},
	journal::Journal,
};
use crate::server::{directory::Directory, links::Authority, rooms::Rooms};
use alloc::{format, string::String, vec::Vec};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
	pub kind: &'static str,
	pub name: String,
	pub note: String,
}

/// One accepted session as the snapshot names it.
pub struct SessionFace {
	pub transport: String,
	pub nick: String,
}

/// Everything the snapshot reads.
pub struct View<'a, C, R> {
	pub rooms: &'a Rooms<C, R>,
	pub directory: &'a Directory<C, R>,
	pub authority: &'a Authority,
	pub sessions: Vec<SessionFace>,
	pub journal: &'a Journal,
	pub irc: &'a [super::operator::inventory::irc::Face<C>],
}

pub fn snapshot<C: Copy + Ord, R: Clone>(
	view: &View<'_, C, R>,
	steward_link: impl Fn(&str) -> Option<String>,
) -> Vec<Row> {
	let mut rows = Vec::new();
	let mut row = |kind: &'static str, name: String, note: String| rows.push(Row { kind, name, note });
	row("directory", crate::directory::NAME.into(), "published bootstrap".into());
	for room in view.rooms.live() {
		let place = if room.listed { "listed" } else { "private" };
		row(
			"room",
			room.name.into(),
			format!("{place}, {} here", room.members.len()),
		);
		for member in &room.members {
			row("occupant", String::from(member.nick), format!("in {}", room.name));
		}
	}
	for bridge in view.irc {
		let name = &bridge.stewardship.label;
		row(
			"room",
			name.clone(),
			format!("listed IRC bridge, {} Rooms readers", bridge.members.len()),
		);
		for member in &bridge.members {
			row("occupant", member.nick.clone(), format!("in {name}, {}", member.state));
		}
		row("link", name.clone(), "listed, durable publication active".into());
	}
	for registration in view.directory.registrations() {
		row(
			"registration",
			registration.nick,
			format!("{} inboxes offered", registration.offered.len()),
		);
	}
	for name in view.authority.linked_rooms() {
		let face = link_face(view.rooms, view.authority, name);
		let shown = if face.label.is_empty() {
			face.name.clone()
		} else {
			face.label.clone()
		};
		row(
			"link",
			shown,
			format!("{}, durable publication active", face.visibility.name()),
		);
	}
	let stewards = stewardship_rows(view.rooms, view.authority, steward_link);
	for stewardship in stewards.iter().chain(view.irc.iter().map(|bridge| &bridge.stewardship)) {
		row(
			"moderator",
			shown(stewardship).into(),
			if stewardship.issued {
				"moderator capability issued".into()
			} else {
				"no moderator capability issued".into()
			},
		);
	}
	for session in &view.sessions {
		row(
			"session",
			session.transport.clone(),
			if session.nick.is_empty() {
				"no registered nickname".into()
			} else {
				format!("registered as {}", session.nick)
			},
		);
	}
	for entry in view.journal.rows() {
		row(
			"trouble",
			entry.source.clone(),
			if entry.count > 1 {
				format!("{} ×{}", entry.reason, entry.count)
			} else {
				entry.reason.clone()
			},
		);
	}
	rows
}
