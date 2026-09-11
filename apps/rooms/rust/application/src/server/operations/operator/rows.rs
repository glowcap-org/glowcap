//! What each inventory row says on the wire.
use super::super::faces::{StewardshipRow, Visibility};
use super::super::listeners::Wire;
use alloc::{string::String, vec, vec::Vec};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Row {
	/// `[name, label, visibility, generation, issued, steward|null]`.
	Stewardship(StewardshipRow),
	/// `[name, label, visibility]`.
	Link {
		name: String,
		label: String,
		visibility: Visibility,
	},
	/// `[nick, sessionId, you]`.
	Registration { nick: String, session: String, you: bool },
	/// `[id, transport, nick, you]`.
	Session {
		id: String,
		transport: String,
		nick: String,
		you: bool,
	},
	/// `[id, kind, name, origin, proof, retained|null, members, membersMore]`
	/// where a member is `[nick, sessionId, state]`.
	Room {
		id: String,
		kind: RoomKind,
		name: String,
		origin: String,
		proof: &'static str,
		retained: Option<u64>,
		members: Vec<(String, String, String)>,
		members_more: bool,
	},
	/// `[id, kind, owner, room, member, detail]`.
	Reference {
		id: String,
		kind: super::ReferenceKind,
		owner: &'static str,
		room: String,
		member: String,
		detail: String,
	},
	/// `[source, reason, count]`.
	Trouble { source: String, reason: String, count: u64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RoomKind {
	Local,
	Private,
	Peered,
	PendingPeered,
	Irc,
}

impl RoomKind {
	pub const fn name(self) -> &'static str {
		match self {
			Self::Local => "local",
			Self::Private => "private",
			Self::Peered => "peered",
			Self::PendingPeered => "pending-peered",
			Self::Irc => "irc",
		}
	}
}

pub fn wire<W: Wire>(row: &Row) -> W::Value {
	match row {
		Row::Stewardship(row) => wire_stewardship::<W>(row),
		Row::Link {
			name,
			label,
			visibility,
		} => W::list(vec![W::text(name), W::text(label), W::text(visibility.name())]),
		Row::Registration { nick, session, you } => W::list(vec![W::text(nick), W::text(session), W::boolean(*you)]),
		Row::Session {
			id,
			transport,
			nick,
			you,
		} => W::list(vec![W::text(id), W::text(transport), W::text(nick), W::boolean(*you)]),
		Row::Room {
			id,
			kind,
			name,
			origin,
			proof,
			retained,
			members,
			members_more,
		} => W::list(vec![
			W::text(id),
			W::text(kind.name()),
			W::text(name),
			W::text(origin),
			W::text(proof),
			match retained {
				Some(count) => W::integer(*count),
				None => W::null(),
			},
			W::list(
				members
					.iter()
					.map(|(nick, session, state)| W::list(vec![W::text(nick), W::text(session), W::text(state)]))
					.collect(),
			),
			W::boolean(*members_more),
		]),
		Row::Reference {
			id,
			kind,
			owner,
			room,
			member,
			detail,
		} => W::list(vec![
			W::text(id),
			W::text(kind.name()),
			W::text(owner),
			W::text(room),
			W::text(member),
			W::text(detail),
		]),
		Row::Trouble { source, reason, count } => W::list(vec![W::text(source), W::text(reason), W::integer(*count)]),
	}
}

pub fn wire_stewardship<W: Wire>(row: &StewardshipRow) -> W::Value {
	W::list(vec![
		W::text(&row.name),
		W::text(&row.label),
		W::text(row.visibility.name()),
		W::integer(row.generation),
		W::boolean(row.issued),
		match &row.steward {
			Some(steward) => W::text(steward),
			None => W::null(),
		},
	])
}

/// One page as the wire carries it: `[revision, next|null, rows, total]`.
pub fn wire_page<W: Wire>(revision: u64, page: &super::page::Page<Row>) -> W::Value {
	W::list(vec![
		W::integer(revision),
		match page.next {
			Some(next) => W::integer(next),
			None => W::null(),
		},
		W::list(page.rows.iter().map(wire::<W>).collect()),
		W::integer(page.total),
	])
}

/// The whole inventory: `[revision, [[category, next|null, rows, total]…]]`.
pub fn wire_whole<W: Wire>(revision: u64, pages: &[(super::Category, super::page::Page<Row>)]) -> W::Value {
	W::list(vec![
		W::integer(revision),
		W::list(
			pages
				.iter()
				.map(|(category, page)| {
					W::list(vec![
						W::text(category.name()),
						match page.next {
							Some(next) => W::integer(next),
							None => W::null(),
						},
						W::list(page.rows.iter().map(wire::<W>).collect()),
						W::integer(page.total),
					])
				})
				.collect(),
		),
	])
}
