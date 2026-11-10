//! How the inventories name a room's authority: the face a durable link
//! shows, and the stewardship row a room answers. Both are built from the
//! live rooms and the durable authority together, the two places that must
//! agree, and both the diagnostic snapshot and the operator read them here
//! so one page cannot call a room `design` while the other calls it by its
//! durable key.
use crate::{
	directory::creation::RecoveryKey,
	room::stewardship::Kind,
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

/// One room this server owns with its issued moderator and manager links.
/// `name` is the durable name the operator verbs accept: a private room's
/// opaque key, never its label.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StewardshipRow {
	pub name: String,
	pub label: String,
	pub visibility: Visibility,
	/// The moderator link's generation: every issue or revoke of that link
	/// advances it.
	pub generation: u64,
	/// The current moderator sturdyref, present exactly while one is issued.
	pub steward: Option<String>,
	/// The current manager sturdyref, present exactly while one is issued.
	pub manager: Option<String>,
	/// An IRC bridge runs this room. It takes no manager link and cannot be
	/// forgotten here.
	pub bridged: bool,
}

/// The rows the operator's "Rooms and their links" section lists, sorted by
/// what a reader sees each room called. They are every live room, every room
/// a link stands for (a published room link, an issued moderator link, an
/// issued manager link), and every managed room record, which holds a public
/// name and a policy until the operator forgets it. `link` answers the
/// sturdyref of an issued moderator or manager link. A revoked link
/// keeps its generation counter so a reissue never mints a revoked link's
/// bytes again. The counter is no room, so it has no row.
pub fn stewardship_rows<C: Copy + Ord, R: Clone>(
	rooms: &Rooms<C, R>,
	authority: &Authority,
	link: impl Fn(Kind, &str) -> Option<String>,
) -> Vec<StewardshipRow> {
	let live: BTreeMap<String, LiveRoom<'_, C>> = rooms
		.live()
		.map(|room| (room.durable_name.to_lowercase(), room))
		.collect();
	let mut out: BTreeMap<String, StewardshipRow> = BTreeMap::new();
	for name in live
		.values()
		.map(|room| room.durable_name)
		.chain(authority.owned_names())
	{
		if let alloc::collections::btree_map::Entry::Vacant(slot) = out.entry(name.to_lowercase()) {
			let row = row_of(live.get(slot.key()), authority, &link, name);
			slot.insert(row);
		}
	}
	let mut rows: Vec<StewardshipRow> = out.into_values().collect();
	rows.sort_by_cached_key(stewardship_order);
	rows
}

/// The durable name the operator's verbs act on: a live room's, or one the
/// authority holds something under, matched the way links fold names. The
/// list reads the same set, so every row it shows can be acted on.
pub fn owned_name<C: Copy + Ord, R: Clone>(rooms: &Rooms<C, R>, authority: &Authority, asked: &str) -> Option<String> {
	live_room(rooms, asked)
		.map(|room| String::from(room.durable_name))
		.or_else(|| authority.owned_name(asked).map(String::from))
}

/// The row `name` answers right now, whether or not the list holds it: the
/// reply to issuing or revoking a link reads it after the change, when the
/// last link of a room nobody is in has just gone.
pub fn stewardship_row<C: Copy + Ord, R: Clone>(
	rooms: &Rooms<C, R>,
	authority: &Authority,
	link: impl Fn(Kind, &str) -> Option<String>,
	name: &str,
) -> StewardshipRow {
	row_of(live_room(rooms, name).as_ref(), authority, &link, name)
}

fn row_of<C: Copy + Ord>(
	live: Option<&LiveRoom<'_, C>>,
	authority: &Authority,
	link: &impl Fn(Kind, &str) -> Option<String>,
	name: &str,
) -> StewardshipRow {
	let managed = authority.managed_room(name);
	let (label, visibility) = match (live, managed) {
		(Some(room), _) => (
			room.name.to_string(),
			if room.listed {
				Visibility::Listed
			} else {
				Visibility::Private
			},
		),
		(None, Some(managed)) => (
			managed.name.clone(),
			if managed.policy.is_listed() {
				Visibility::Listed
			} else {
				Visibility::Private
			},
		),
		(None, None) if RecoveryKey::accepts(name) => (String::new(), Visibility::Private),
		(None, None) => (name.into(), Visibility::Listed),
	};
	StewardshipRow {
		name: name.into(),
		label,
		visibility,
		generation: authority.steward_generation(name),
		steward: if authority.has_steward(name) {
			link(Kind::Steward, name)
		} else {
			None
		},
		manager: if authority.has_manager(name) {
			link(Kind::Manager, name)
		} else {
			None
		},
		bridged: false,
	}
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

#[cfg(test)]
mod tests {
	use super::*;
	use crate::server::document::Document;

	/// A kept document where room "old" has an issued manager and nothing
	/// else, and a managed room has a manager whose issue was withdrawn.
	const KEPT: &str = r#"{"version":1,"identitySeed":"0101010101010101010101010101010101010101010101010101010101010101","roomLinkSecret":"0202020202020202020202020202020202020202020202020202020202020202","linkedRooms":["Garden","~00000000000000000000000000000001"],"revokedRooms":["old"],"roomLinkGenerations":[{"name":"garden","generation":3}],"stewards":[{"name":"garden","generation":1,"issued":true}],"managers":[{"name":"~00000000000000000000000000000001","generation":2,"issued":false},{"name":"old","generation":1,"issued":true}],"managedRooms":[{"id":"~00000000000000000000000000000001","name":"Garden","generation":2,"policy":{"visibility":"listed","entry":"open","speaking":"moderated"}}],"subjects":[{"name":"garden","description":"seedlings","link":"ocapn://peer.tcp/s/c3dpc3M"},{"name":"~00000000000000000000000000000001","description":"kept"}]}"#;

	/// A document after "Garden"'s link was taken down and both manager
	/// links were revoked: "garden" is a manager tombstone with no room, and
	/// the managed record stands with nothing issued.
	const TOMBSTONES: &str = r#"{"version":1,"identitySeed":"0101010101010101010101010101010101010101010101010101010101010101","roomLinkSecret":"0202020202020202020202020202020202020202020202020202020202020202","linkedRooms":[],"revokedRooms":["Garden","~00000000000000000000000000000001"],"roomLinkGenerations":[{"name":"garden","generation":3}],"stewards":[],"managers":[{"name":"garden","generation":2,"issued":false},{"name":"~00000000000000000000000000000001","generation":2,"issued":false}],"managedRooms":[{"id":"~00000000000000000000000000000001","name":"Garden","generation":2,"policy":{"visibility":"listed","entry":"open","speaking":"moderated"}}],"subjects":[]}"#;

	#[test]
	fn a_tombstone_has_no_row_and_a_managed_record_keeps_one() {
		let authority = Authority::read(&Document::decode(TOMBSTONES).unwrap()).unwrap();
		let rooms = Rooms::<u8, u8>::new(None, crate::files::FileLimits::default());
		let link = |_: Kind, _: &str| Some(String::from("ocapn://held"));
		let rows = stewardship_rows(&rooms, &authority, link);
		assert_eq!(
			rows.iter().map(|row| row.name.as_str()).collect::<Vec<_>>(),
			["~00000000000000000000000000000001"],
			"a revoked link's counter is no room, a managed record is one"
		);
		let managed = &rows[0];
		assert_eq!(
			(managed.label.as_str(), managed.visibility),
			("Garden", Visibility::Listed)
		);
		assert_eq!((&managed.steward, &managed.manager), (&None, &None));
		let answered = stewardship_row(&rooms, &authority, link, "garden");
		assert_eq!(
			(answered.label.as_str(), answered.visibility),
			("garden", Visibility::Listed)
		);
		assert_eq!((answered.steward, answered.manager), (None, None));
		let forgotten = authority
			.with_room_forgotten("~00000000000000000000000000000001")
			.unwrap()
			.expect("a record to drop");
		assert!(stewardship_rows(&rooms, &forgotten, link).is_empty());
		assert_eq!(
			forgotten.manager_generation("~00000000000000000000000000000001"),
			2,
			"the counter stays"
		);
		assert!(
			forgotten.with_room_forgotten("garden").unwrap().is_none(),
			"a tombstone alone is nothing to forget"
		);
	}

	#[test]
	fn every_listed_name_is_owned_and_a_stranger_is_not() {
		let authority = Authority::read(&Document::decode(KEPT).unwrap()).unwrap();
		let rooms = Rooms::<u8, u8>::new(None, crate::files::FileLimits::default());
		let rows = stewardship_rows(&rooms, &authority, |_, _| None);
		assert_eq!(rows.len(), 3, "a linked room, a managed record, a manager-only room");
		for row in &rows {
			assert_eq!(
				owned_name(&rooms, &authority, &row.name.to_uppercase()).as_deref(),
				Some(row.name.as_str()),
				"{} resolves however it is cased",
				row.name
			);
		}
		assert_eq!(owned_name(&rooms, &authority, "nowhere"), None);
	}

	#[test]
	fn a_manager_with_no_members_link_or_steward_still_has_a_row() {
		let authority = Authority::read(&Document::decode(KEPT).unwrap()).unwrap();
		let rooms = Rooms::<u8, u8>::new(None, crate::files::FileLimits::default());
		let rows = stewardship_rows(&rooms, &authority, |kind, _| {
			Some(match kind {
				Kind::Manager => "ocapn://held/m".into(),
				_ => "ocapn://held/s".into(),
			})
		});
		let old = rows
			.iter()
			.find(|row| row.name == "old")
			.expect("the manager's room is listed");
		assert_eq!(old.manager.as_deref(), Some("ocapn://held/m"));
		assert_eq!(old.steward, None);
		let managed = rows
			.iter()
			.find(|row| row.name == "~00000000000000000000000000000001")
			.expect("the managed room is listed");
		assert_eq!(
			managed.manager, None,
			"a revoked manager is not held, the room link lists the room"
		);
		let garden = rows
			.iter()
			.find(|row| row.name.eq_ignore_ascii_case("garden"))
			.expect("the steward's room is listed");
		assert_eq!(garden.steward.as_deref(), Some("ocapn://held/s"));
		assert_eq!(
			garden.manager, None,
			"a room with no manager generation asks for no link"
		);
	}
}
