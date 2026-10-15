//! The directory's discovery values drawn as wire arguments: the inverse of
//! the readers in `discovery`, kept beside them so a directory answers in
//! exactly the shape a client reads, and one round trip proves both.
use super::{Event, Member, Page, RoomInfo, Snapshot};
use crate::{session::snapshot::BuildArguments, text::DocumentText};
use alloc::{string::String, vec, vec::Vec};

/// How room rows are drawn for one reader: the two-field baseline `list` and
/// `watch` answer, or the full publication record `listPublications` and
/// `watchPublications` answer. Only publication snapshots include members.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shape {
	Baseline,
	Publication,
}

fn owned(text: &DocumentText) -> String {
	match text.as_str() {
		Some(text) => text.into(),
		None => char::decode_utf16(text.utf16())
			.map(|unit| unit.unwrap_or(char::REPLACEMENT_CHARACTER))
			.collect(),
	}
}

fn count<B: BuildArguments>(entry: &RoomInfo) -> B::Value {
	match entry.count.as_ref() {
		Some(count) => B::integer(count.get()),
		None => B::null(),
	}
}

/// One room row under `shape`.
pub fn room_row<B: BuildArguments>(entry: &RoomInfo, shape: Shape) -> Vec<B::Value> {
	let mut row = vec![B::text(owned(entry.name.text())), count::<B>(entry)];
	if shape == Shape::Publication {
		row.extend([
			B::text(owned(entry.id.text())),
			B::text(entry.kind.wire().into()),
			B::text(owned(entry.origin.text())),
			B::text(entry.proof.wire().into()),
			match entry.offers.as_ref() {
				Some(kind) => B::text(kind.as_str().into()),
				None => B::null(),
			},
		]);
	}
	row
}

pub fn rooms<B: BuildArguments>(rooms: &[RoomInfo], shape: Shape) -> B::Value {
	B::list(rooms.iter().map(|entry| B::list(room_row::<B>(entry, shape))).collect())
}

/// A `listPublications` answer: `[rows, next]`, where `next` is the cursor
/// of the following page or null on the last one.
pub fn page<B: BuildArguments>(page: &Page) -> B::Value {
	B::list(vec![
		rooms::<B>(&page.rooms, Shape::Publication),
		match &page.next {
			Some(next) => B::text(next.text()),
			None => B::null(),
		},
	])
}

fn member_row<B: BuildArguments>(member: &Member) -> B::Value {
	B::list(vec![
		B::text(owned(member.name.text())),
		B::text(owned(&member.registration_id)),
	])
}

/// Baseline `watch` answers room rows. `watchPublications` answers
/// `[rooms, peers, omitted]`.
pub fn snapshot<B: BuildArguments>(snapshot: &Snapshot, shape: Shape) -> B::Value {
	if shape == Shape::Baseline {
		return rooms::<B>(&snapshot.rooms, shape);
	}
	B::list(vec![
		rooms::<B>(&snapshot.rooms, shape),
		B::list(snapshot.peers.iter().map(member_row::<B>).collect()),
		B::integer(snapshot.omitted),
	])
}

/// One watcher notification's arguments under `shape`.
pub fn event<B: BuildArguments>(event: &Event, shape: Shape) -> Vec<B::Value> {
	match event {
		Event::Room { kind, entry } => {
			let mut args = vec![B::text(kind.wire().into())];
			args.extend(room_row::<B>(entry, shape));
			args
		}
		Event::Member { kind, peer, count } => vec![
			B::text(kind.wire().into()),
			B::text(owned(peer.name.text())),
			B::integer(*count),
			B::text(owned(&peer.registration_id)),
		],
		Event::Truncated(count) => vec![B::text(crate::protocol_data::TRUNCATED.into()), B::integer(*count)],
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{
		directory::{MemberChange, OriginProof, PublicationKind, RoomChange},
		fields::{Nullable, SafeInteger, Text},
		room::{ArgumentView, ListArgument, policy::MembershipKind},
	};

	/// A value the way a binding would decode it.
	#[derive(Clone, Debug, PartialEq)]
	enum V {
		Text(String),
		Integer(u64),
		Null,
		List(Vec<V>),
	}
	struct Build;
	impl BuildArguments for Build {
		type Value = V;
		fn text(value: String) -> V {
			V::Text(value)
		}
		fn integer(value: u64) -> V {
			V::Integer(value)
		}
		fn null() -> V {
			V::Null
		}
		fn list(values: Vec<V>) -> V {
			V::List(values)
		}
	}
	impl ArgumentView for &V {
		fn boolean(&self) -> Option<bool> {
			None
		}
		fn is_null(&self) -> bool {
			matches!(self, V::Null)
		}
		fn text(&self) -> Option<&str> {
			match self {
				V::Text(text) => Some(text),
				_ => None,
			}
		}
		fn integer(&self) -> Option<i128> {
			match self {
				V::Integer(n) => Some(*n as i128),
				_ => None,
			}
		}
		fn float(&self) -> Option<f64> {
			None
		}
		fn contains_capability(&self) -> bool {
			false
		}
	}
	impl ListArgument for &V {
		fn list_len(&self) -> Option<usize> {
			match self {
				V::List(items) => Some(items.len()),
				_ => None,
			}
		}
		fn at(&self, index: usize) -> Option<Self> {
			match self {
				V::List(items) => items.get(index),
				_ => None,
			}
		}
	}

	fn garden(kind: PublicationKind) -> RoomInfo {
		let foreign = kind != PublicationKind::Local;
		RoomInfo {
			id: Text(
				if foreign {
					"far:garden"
				} else {
					"~00000000000000000000000000000001"
				}
				.into(),
			),
			name: Text("Garden".into()),
			kind,
			count: if foreign {
				Nullable::Null
			} else {
				Nullable::Value(SafeInteger::new(3).unwrap())
			},
			origin: Text(if foreign { "far" } else { "" }.into()),
			proof: if foreign {
				OriginProof::Session
			} else {
				OriginProof::Local
			},
			offers: Nullable::Value(MembershipKind::Participant),
		}
	}
	fn alice() -> Member {
		Member {
			name: Text("Alice".into()),
			registration_id: "11111111-1111-4111-8111-111111111111".into(),
		}
	}

	#[test]
	fn a_drawn_snapshot_reads_back_under_both_shapes() {
		let mut held = Snapshot {
			rooms: vec![garden(PublicationKind::Local), garden(PublicationKind::Foreign)],
			peers: vec![alice()],
			omitted: 2,
		};
		let publication = snapshot::<Build>(&held, Shape::Publication);
		let read = crate::directory::snapshot(&&publication).unwrap();
		assert_eq!(read.rooms, held.rooms);
		assert_eq!(read.peers, held.peers);
		assert_eq!(read.omitted, 2);
		// A baseline row names a local room by name and count alone; a foreign
		// room has no count there, which is why a publication reader exists.
		held.rooms.truncate(1);
		let baseline = snapshot::<Build>(&held, Shape::Baseline);
		let read = crate::directory::rooms(&&baseline).unwrap();
		assert_eq!(read.len(), 1);
		assert_eq!(read[0].name, held.rooms[0].name);
		assert_eq!(read[0].kind, PublicationKind::Local);
	}

	#[test]
	fn a_listing_pages_by_cursor_and_reads_back() {
		use crate::directory::{Cursor, MAX_ROWS};
		let keyed = |n: usize| {
			let mut room = garden(PublicationKind::Local);
			room.id = Text(alloc::format!("~{n:032x}").as_str().into());
			(alloc::format!("#room{n:04}"), room)
		};
		let walk = |after: Option<&Cursor>, closed: usize| {
			(0..MAX_ROWS + 3)
				.filter(move |n| *n != closed)
				.map(keyed)
				.filter(move |(key, room)| after.is_none_or(|cursor| cursor.precedes(room.kind, key)))
				.collect::<Vec<_>>()
		};
		let first = Page::cut(walk(None, usize::MAX));
		let last_key = alloc::format!("#room{:04}", MAX_ROWS - 1);
		assert_eq!(first.rooms.len(), MAX_ROWS);
		assert_eq!(
			first.next,
			Some(Cursor {
				kind: PublicationKind::Local,
				key: last_key.clone(),
			})
		);
		let drawn = page::<Build>(&first);
		assert_eq!(crate::directory::page(&&drawn).unwrap(), first);
		assert_eq!(first.next.as_ref().unwrap().text(), alloc::format!("local:{last_key}"));
		// The last row of the first page closes before the second page is
		// asked for: the walk still resumes after its key, so no row is
		// skipped or answered twice.
		let rest = Page::cut(walk(first.next.as_ref(), MAX_ROWS - 1));
		assert_eq!((rest.rooms.len(), &rest.next), (3, &None));
		assert_eq!(rest.rooms[0].id, keyed(MAX_ROWS).1.id);
		// A page that exactly fits the rest of the walk is the last page.
		let exact = Page::cut((0..MAX_ROWS).map(keyed));
		assert_eq!((exact.rooms.len(), &exact.next), (MAX_ROWS, &None));
		// A later source lists after every row of an earlier one.
		let foreign = Cursor {
			kind: PublicationKind::Foreign,
			key: "#a".into(),
		};
		assert!(!foreign.precedes(PublicationKind::Local, "#z"));
		assert!(foreign.precedes(PublicationKind::Foreign, "#b"));
		assert!(foreign.precedes(PublicationKind::Bridge, "#a"));
		let past = Page::cut(walk(Some(&foreign), usize::MAX));
		assert_eq!((past.rooms.len(), past.next), (0, None));
		// A cursor reads back only in the form a directory mints.
		assert_eq!(Cursor::parse("foreign:#a"), Some(foreign));
		assert_eq!(Cursor::parse("garden"), None);
		assert_eq!(Cursor::parse("elsewhere:#a"), None);
		assert_eq!(Cursor::parse("local:"), None);
		// A continuation after an empty page would let a directory keep a
		// reader paging forever.
		let stalled = page::<Build>(&Page {
			rooms: Vec::new(),
			next: first.next.clone(),
		});
		assert!(crate::directory::page(&&stalled).is_err());
	}

	#[test]
	fn a_drawn_event_reads_back() {
		let registered = Event::Member {
			kind: MemberChange::Registered,
			peer: alice(),
			count: 1,
		};
		let args = event::<Build>(&registered, Shape::Baseline);
		assert_eq!(crate::directory::event(&&V::List(args)), Some(registered));
		let opened = Event::Room {
			kind: RoomChange::Opened,
			entry: garden(PublicationKind::Local),
		};
		let args = event::<Build>(&opened, Shape::Publication);
		assert_eq!(crate::directory::event(&&V::List(args)), Some(opened));
		let args = event::<Build>(&Event::Truncated(4), Shape::Baseline);
		assert_eq!(crate::directory::event(&&V::List(args)), Some(Event::Truncated(4)));
	}
}
