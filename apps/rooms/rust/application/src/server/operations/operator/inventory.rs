//! The seven inventories as sources a page is cut from, each row beside the
//! exact act that retires it. Every row is drawn from the live policies and
//! the durable authority, so what the operator reads is what the server
//! holds, and every act names its target by an id that cannot drift onto a
//! replacement.
pub mod irc;
use super::{
	super::{
		faces::{Visibility, link_face, stewardship_rows},
		journal::Journal,
	},
	Category, MAX_MEMBERS_PER_ROOM, ReferenceKind,
	page::{Source, search_text},
	rows::{RoomKind, Row},
};
use crate::server::{
	directory::Directory,
	links::Authority,
	rooms::{MembershipKey, RoomKey, Rooms},
};
use alloc::{
	collections::BTreeMap,
	format,
	string::{String, ToString},
	vec::Vec,
};

/// One accepted session as the inventories name it.
pub struct SessionRow<C> {
	pub id: String,
	pub transport: String,
	pub nick: String,
	pub connection: C,
}

/// One room another directory published here, live or still resolving.
pub struct ForeignFace {
	pub id: String,
	pub name: String,
	pub origin: String,
	pub proof: &'static str,
	pub live: bool,
}

/// Everything the inventories read.
pub struct View<'a, C, R> {
	pub rooms: &'a Rooms<C, R>,
	pub directory: &'a Directory<C, R>,
	pub authority: &'a Authority,
	pub sessions: Vec<SessionRow<C>>,
	/// The caller's own connection, marked `you` where it appears.
	pub caller: C,
	pub journal: &'a Journal,
	pub foreign: Vec<ForeignFace>,
	pub irc: Vec<irc::Face<C>>,
}

/// The exact act a row's retire performs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Act {
	RevokeSteward(String),
	RevokeIrcSteward {
		publication: String,
		token: String,
	},
	RemoveIrc(String),
	EndIrcMembership {
		publication: String,
		membership: u64,
	},
	RevokeRoomLink(String),
	RevokeRegistration(String),
	/// By the session's operator id. The caller's own connection stays.
	Disconnect(String),
	/// By the room generation's exact entry id.
	RemoveRoom(String),
	/// By the publication's exact id, live or still resolving.
	RemoveForeign(String),
	EndMembership {
		room: RoomKey,
		membership: MembershipKey,
	},
	ReleaseOffered {
		nick: String,
		peer: String,
	},
	ReleaseSignaling(String),
	DropExchange(String),
}

impl<C: Copy + Ord, R: Clone> View<'_, C, R> {
	fn session_id(&self, connection: C) -> Option<&str> {
		self.sessions
			.iter()
			.find(|session| session.connection == connection)
			.map(|session| session.id.as_str())
	}
	/// The sources of one category, in inventory order.
	pub fn sources(
		&self,
		category: Category,
		kind: Option<ReferenceKind>,
		steward_link: &dyn Fn(&str) -> Option<String>,
	) -> Vec<Source<Row, Act>> {
		let mut sources: Vec<_> = match category {
			Category::Stewardships => stewardship_rows(self.rooms, self.authority, steward_link)
				.into_iter()
				.map(|row| Source {
					text: search_text(&[&row.name, &row.label, row.visibility.name()]),
					retire: row.issued.then(|| Act::RevokeSteward(row.name.clone())),
					row: Row::Stewardship(row),
				})
				.collect(),
			Category::Links => self
				.authority
				.linked_rooms()
				.map(|name| {
					let face = link_face(self.rooms, self.authority, name);
					Source {
						text: search_text(&[&face.name, &face.label, face.visibility.name()]),
						retire: Some(Act::RevokeRoomLink(face.name.clone())),
						row: Row::Link {
							name: face.name,
							label: face.label,
							visibility: face.visibility,
						},
					}
				})
				.collect(),
			Category::Registrations => self
				.directory
				.registrations()
				.filter_map(|registration| {
					let session = self.session_id(registration.connection)?.to_string();
					Some(Source {
						text: search_text(&[&registration.nick, &session]),
						retire: Some(Act::RevokeRegistration(registration.nick.clone())),
						row: Row::Registration {
							nick: registration.nick,
							session,
							you: registration.connection == self.caller,
						},
					})
				})
				.collect(),
			Category::Sessions => self
				.sessions
				.iter()
				.map(|session| Source {
					text: search_text(&[&session.id, &session.transport, &session.nick]),
					retire: Some(Act::Disconnect(session.id.clone())),
					row: Row::Session {
						id: session.id.clone(),
						transport: session.transport.clone(),
						nick: session.nick.clone(),
						you: session.connection == self.caller,
					},
				})
				.collect(),
			Category::Rooms => self
				.rooms
				.live()
				.map(|room| {
					let members: Vec<(String, String, String)> = room
						.members
						.iter()
						.take(MAX_MEMBERS_PER_ROOM)
						.map(|member| {
							(
								member.nick.to_string(),
								self.session_id(member.connection).unwrap_or("").to_string(),
								member.away.to_string(),
							)
						})
						.collect();
					let nicks: Vec<&str> = members.iter().map(|(nick, _, _)| nick.as_str()).collect();
					let mut parts = alloc::vec![room.entry_id, room.name, "local"];
					parts.extend(nicks);
					Source {
						text: search_text(&parts),
						retire: Some(Act::RemoveRoom(room.entry_id.to_string())),
						row: Row::Room {
							id: room.entry_id.to_string(),
							kind: if room.listed {
								RoomKind::Local
							} else {
								RoomKind::Private
							},
							name: room.name.to_string(),
							origin: String::new(),
							proof: "local",
							// One owned inbox occurrence per member. Published
							// controls live in the Host and consult generation
							// keys; this room retains none of their Ref handles.
							retained: Some(room.members.len() as u64),
							members_more: room.members.len() > MAX_MEMBERS_PER_ROOM,
							members,
						},
					}
				})
				.chain(self.foreign.iter().map(|foreign| Source {
					text: search_text(&[&foreign.id, &foreign.name, &foreign.origin, foreign.proof]),
					retire: Some(Act::RemoveForeign(foreign.id.clone())),
					row: Row::Room {
						id: foreign.id.clone(),
						kind: if foreign.live {
							RoomKind::Peered
						} else {
							RoomKind::PendingPeered
						},
						name: foreign.name.clone(),
						origin: foreign.origin.clone(),
						proof: foreign.proof,
						// The one capability held: the room its source handed.
						retained: Some(1),
						members: Vec::new(),
						members_more: false,
					},
				}))
				.collect(),
			Category::References => self.references(kind),
			Category::Trouble => self
				.journal
				.rows()
				.map(|entry| Source {
					text: search_text(&[&entry.source, &entry.reason]),
					retire: None,
					row: Row::Trouble {
						source: entry.source.clone(),
						reason: entry.reason.clone(),
						count: entry.count,
					},
				})
				.collect(),
		};
		sources.extend(self.irc_sources(category, kind));
		if category == Category::Stewardships && !self.irc.is_empty() {
			sources.sort_by_cached_key(|source| match &source.row {
				Row::Stewardship(row) => crate::server::operations::faces::stewardship_order(row),
				_ => unreachable!("the stewardship category contains stewardship rows"),
			});
		}
		sources
	}
	/// The retained references, children before their owners, so one act
	/// removes exactly the row it names rather than cascading.
	fn references(&self, wanted: Option<ReferenceKind>) -> Vec<Source<Row, Act>> {
		let mut out = Vec::new();
		let mut push = |kind: ReferenceKind,
		                id: String,
		                owner: &'static str,
		                room: String,
		                member: String,
		                detail: String,
		                act: Act| {
			if wanted.is_some_and(|wanted| wanted != kind) {
				return;
			}
			out.push(Source {
				text: search_text(&[&id, kind.name(), owner, &room, &member, &detail]),
				retire: Some(act),
				row: Row::Reference {
					id,
					kind,
					owner,
					room,
					member,
					detail,
				},
			});
		};
		for room in self.rooms.live() {
			for member in room.members.iter().rev() {
				push(
					ReferenceKind::Membership,
					format!("ref-m{}", member.membership.raw()),
					"room membership",
					room.name.to_string(),
					member.nick.to_string(),
					"membership inbox".into(),
					Act::EndMembership {
						room: room.key.clone(),
						membership: member.membership,
					},
				);
			}
		}
		for foreign in &self.foreign {
			let (kind, prefix, owner) = if foreign.live {
				(ReferenceKind::ForeignRoom, "ref-f", "foreign room publication")
			} else {
				(
					ReferenceKind::PendingPeering,
					"ref-pending-",
					"pending foreign publication",
				)
			};
			push(
				kind,
				format!("{prefix}{}", foreign.id),
				owner,
				foreign.name.clone(),
				String::new(),
				format!("{} publication from {}", foreign.proof, foreign.origin),
				Act::RemoveForeign(foreign.id.clone()),
			);
		}
		for exchange in self.directory.exchanges() {
			push(
				ReferenceKind::SignalExchange,
				format!("ref-x{}", exchange.id),
				"signaling exchange",
				String::new(),
				self.session_id(exchange.originator).unwrap_or("").to_string(),
				format!("in-flight exchange {}", exchange.id),
				Act::DropExchange(exchange.id.clone()),
			);
		}
		let registrations: Vec<_> = self.directory.registrations().collect();
		let ids: BTreeMap<&str, &str> = registrations
			.iter()
			.map(|registration| (registration.id.as_str(), registration.nick.as_str()))
			.collect();
		for registration in &registrations {
			for peer in &registration.offered {
				let named = ids.get(peer.as_str()).copied().unwrap_or("departed registration");
				push(
					ReferenceKind::OfferedInbox,
					format!("ref-o{}-{peer}", registration.id),
					"directory registration",
					String::new(),
					registration.nick.clone(),
					format!("inbox offered to {named} ({peer})"),
					Act::ReleaseOffered {
						nick: registration.nick.clone(),
						peer: peer.clone(),
					},
				);
			}
			if registration.signaling {
				push(
					ReferenceKind::Signaling,
					format!("ref-s{}", registration.id),
					"directory registration",
					String::new(),
					registration.nick.clone(),
					"WebRTC signaling inbox".into(),
					Act::ReleaseSignaling(registration.nick.clone()),
				);
			}
		}
		for registration in &registrations {
			push(
				ReferenceKind::Registration,
				format!("ref-r{}", registration.id),
				"directory registration",
				String::new(),
				registration.nick.clone(),
				"registration inbox and name claim".into(),
				Act::RevokeRegistration(registration.nick.clone()),
			);
		}
		out
	}
}

/// The rows a visibility word sorts under, for tests and the inspect page.
pub fn visibility_name(visibility: Visibility) -> &'static str {
	visibility.name()
}
