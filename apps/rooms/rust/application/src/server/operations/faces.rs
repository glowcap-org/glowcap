//! How the inventories name a room's authority: the face a durable link
//! shows, and the stewardship row a room answers. Both are built from the
//! live rooms and the durable authority together, the two places that must
//! agree, and both the diagnostic snapshot and the operator read them here
//! so one page cannot call a room `design` while the other calls it by its
//! durable key.
use crate::{
	directory::creation::RecoveryKey,
	server::{
		links::Authority,
		rooms::{LiveRoom, Rooms},
	},
};
use alloc::{
	collections::BTreeMap,
	string::{String, ToString},
	vec::Vec,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Visibility {
	Listed,
	Private,
}
impl Visibility {
	pub const fn name(self) -> &'static str {
		match self {
			Self::Listed => "listed",
			Self::Private => "private",
		}
	}
}

/// What a durable link is called and whether it is listed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkFace {
	pub name: String,
	pub label: String,
	pub visibility: Visibility,
}

/// The live room a durable name stands for, by its key or its public name.
pub fn live_room<'a, C: Copy + Ord, R: Clone>(rooms: &'a Rooms<C, R>, name: &str) -> Option<LiveRoom<'a, C>> {
	let public = rooms.public_key_of(name);
	rooms
		.live()
		.find(|room| room.key.as_str().eq_ignore_ascii_case(name) || public.as_ref() == Some(room.key))
}

pub fn link_face<C: Copy + Ord, R: Clone>(rooms: &Rooms<C, R>, authority: &Authority, name: &str) -> LinkFace {
	let live = live_room(rooms, name);
	let managed = authority.managed_room(name);
	let private = match (&live, managed) {
		(Some(live), _) => !live.listed,
		(None, Some(managed)) => !managed.policy.is_listed(),
		(None, None) => RecoveryKey::accepts(name),
	};
	LinkFace {
		name: name.into(),
		label: live
			.map(|live| live.name.to_string())
			.or_else(|| managed.map(|managed| managed.name.clone()))
			.unwrap_or_else(|| if private { String::new() } else { name.into() }),
		visibility: if private {
			Visibility::Private
		} else {
			Visibility::Listed
		},
	}
}

/// One room this server owns and whether it has an issued moderator
/// capability. `name` is the durable name the operator verbs accept: a
/// private room's opaque key, never its label.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StewardshipRow {
	pub name: String,
	pub label: String,
	pub visibility: Visibility,
	/// Every issue or revoke advances it, so an older answer cannot rewind
	/// a newer row.
	pub generation: u64,
	pub issued: bool,
	/// The current steward sturdyref, present exactly while issued.
	pub steward: Option<String>,
}

/// The stewardship inventory, sorted by what a reader sees the room called.
/// `steward_link` answers the sturdyref of an issued stewardship.
pub fn stewardship_rows<C: Copy + Ord, R: Clone>(
	rooms: &Rooms<C, R>,
	authority: &Authority,
	steward_link: impl Fn(&str) -> Option<String>,
) -> Vec<StewardshipRow> {
	let mut out: BTreeMap<String, StewardshipRow> = BTreeMap::new();
	let add = |out: &mut BTreeMap<String, StewardshipRow>, name: &str, label: String, visibility: Visibility| {
		let issue = authority.stewardship(name);
		let issued = issue.is_some_and(|issue| issue.issued);
		out.insert(
			name.to_lowercase(),
			StewardshipRow {
				name: name.into(),
				label,
				visibility,
				generation: issue.map_or(0, |issue| issue.generation),
				issued,
				steward: if issued { steward_link(name) } else { None },
			},
		);
	};
	for room in rooms.live() {
		let visibility = if room.listed {
			Visibility::Listed
		} else {
			Visibility::Private
		};
		add(&mut out, room.durable_name, room.name.to_string(), visibility);
	}
	let durable: Vec<String> = authority
		.linked_rooms()
		.chain(authority.stewards().map(|issue| issue.name.as_str()))
		.map(String::from)
		.collect();
	for name in durable {
		if out.contains_key(&name.to_lowercase()) {
			continue;
		}
		let managed = authority.managed_room(&name);
		let (label, visibility) = match managed {
			Some(managed) => (
				managed.name.clone(),
				if managed.policy.is_listed() {
					Visibility::Listed
				} else {
					Visibility::Private
				},
			),
			None if RecoveryKey::accepts(&name) => (String::new(), Visibility::Private),
			None => (name.clone(), Visibility::Listed),
		};
		add(&mut out, &name, label, visibility);
	}
	let mut rows: Vec<StewardshipRow> = out.into_values().collect();
	rows.sort_by_cached_key(stewardship_order);
	rows
}

/// What a reader sees a row called.
pub fn shown(row: &StewardshipRow) -> &str {
	if row.label.is_empty() { &row.name } else { &row.label }
}

/// Shared ordering for Rooms and bridged stewardship rows. Compute each
/// Unicode-folded key once, rather than allocating during every comparison.
pub fn stewardship_order(row: &StewardshipRow) -> (String, String) {
	(shown(row).to_lowercase(), row.name.clone())
}
