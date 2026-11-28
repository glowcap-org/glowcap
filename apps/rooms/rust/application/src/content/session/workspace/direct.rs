//! Opening a direct conversation. A `startDirect` receipt holds the peer's
//! inbox as a result key, and the workspace reaches the peer only after one
//! acquisition moves that key into a direct row. A row reaches the peer whose
//! registration introduced it, under whatever contact its directory held
//! then: its route and its inbox are its own custody, so a directory that
//! registers again later leaves the row carrying lines both ways.
//!
//! [`direct_reach`] is the one rule for which row reaches a member. The
//! opener's plan here, the receiving side's [`receive_direct`], the session's
//! participation check (`imports/participation.rs` in the runtime), the
//! terminal front, attached views, and the page (through the browser module's
//! `directReach`) all ask it. A registration holds at most one open row. A
//! route this session's `startDirect` returns while one is open is given
//! back, and an introduction the member sends lands in that row. Otherwise
//! `startDirect` reopens the last closed row of the registration under its
//! own id, or else adds a new row, and an introduction adds a new row, so a
//! member never reopens a row this side holds closed. The session refuses a
//! workspace replacement or a local gesture that opens a second row
//! (`Intent::reaches_another`).
//!
//! A route lands in a row by one rule, [`land`], whoever opened it. A row
//! keeps the openings of the last [`MAX_TAKEN_OPENINGS`] introductions it
//! took, so a replay of one it replaced is refused, not landed again.
//!
//! A workspace saved before this rule may hold two open rows for one
//! registration, and keeps working: each row keeps its own route and the
//! lines that arrive on it, [`open_direct`] and so every post and every new
//! route reach the first, a replacement keeps both, and closing either
//! leaves the other open.
use super::{Conversation, Direct, DirectKind, Field, Id, Intent, Introduction, custody};
use crate::{
	content::session::results,
	fields::{List, Text},
};
use alloc::{boxed::Box, string::String, vec::Vec};
use core::fmt;
/// The owner installs a reciprocal route under the delivering inbox slot and
/// its handoff ordinal. The coordinate compares custody; only the owner can
/// install the actual reference.
pub fn reciprocal_key(
	inbox: custody::FieldKey<custody::DirectInbox>,
	ordinal: core::num::NonZeroU64,
) -> custody::FieldKey<custody::DirectAccess> {
	custody::FieldKey::new(inbox.slot(), ordinal)
}
pub const FIRST_RECIPROCAL: core::num::NonZeroU64 = core::num::NonZeroU64::MIN;

/// The most openings a direct row remembers taking. A replay of an opening
/// older than these lands as a fresh one.
pub const MAX_TAKEN_OPENINGS: usize = 8;
/// The openings of the introductions a row took from the member, oldest
/// first. A row this session opened took none.
pub type Openings = List<Text<128, true>, MAX_TAKEN_OPENINGS>;

/// The arguments of one `startDirect` command, in its order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StartDirect<'a> {
	/// The directory row the introduction comes from.
	pub directory: &'a str,
	/// The nickname the directory registered for the peer.
	pub peer: &'a str,
	/// The peer's registration the directory returned for that nickname.
	pub registration: &'a str,
	/// The opening the introduction carries, kept across retries.
	pub opening: &'a str,
}
impl<'a> StartDirect<'a> {
	/// The four arguments of a `startDirect` command, or `None` for any other
	/// count.
	pub fn read(arguments: &'a [String]) -> Option<Self> {
		let [directory, peer, registration, opening] = arguments else {
			return None;
		};
		Some(Self {
			directory,
			peer,
			registration,
			opening,
		})
	}
	/// The command's arguments, in the order `read` takes them.
	pub fn arguments(&self) -> Vec<String> {
		[self.directory, self.peer, self.registration, self.opening]
			.map(String::from)
			.into()
	}
}

/// What the reach rule reads of one direct row: the directory row it was
/// introduced from, the registration that introduced it, and whether it is
/// closed. The page projects its rows to this through the browser module.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Reaching<'a> {
	pub directory: &'a str,
	pub registration: Option<&'a str>,
	pub closed: bool,
}
impl<'a> Reaching<'a> {
	/// The fields of `row` the rule reads. A row whose text fields hold no
	/// text reaches no one.
	pub fn of(row: &'a Direct) -> Option<Self> {
		Some(Self {
			directory: row.directory.text().as_str()?,
			registration: row
				.introduction
				.as_ref()
				.and_then(|introduction| introduction.registration.text().as_str()),
			closed: row.closed,
		})
	}
	/// Whether the row was introduced from `directory` to the peer holding
	/// `registration`, under any contact that directory held.
	pub fn reaches(&self, directory: &str, registration: &str) -> bool {
		self.directory == directory && self.registration == Some(registration)
	}
}

/// Where the rows reaching one member sit among a workspace's conversations.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DirectReach {
	/// The first open row. A new route is given back while one is open.
	pub open: Option<usize>,
	/// The last closed row, which this session's own `startDirect` reopens
	/// when none is open.
	pub reopened: Option<usize>,
}

/// Find the rows of `rows`, one entry per conversation and `None` for a room,
/// that reach the peer holding `registration` through `directory`. Keyed by
/// registration, so the case of a nickname or a name another member took
/// since cannot select the wrong row.
pub fn direct_reach<'a>(
	rows: impl IntoIterator<Item = Option<Reaching<'a>>>,
	directory: &str,
	registration: &str,
) -> DirectReach {
	let mut reach = DirectReach::default();
	for (at, row) in rows.into_iter().enumerate() {
		match row {
			Some(row) if row.reaches(directory, registration) && row.closed => reach.reopened = Some(at),
			Some(row) if row.reaches(directory, registration) && reach.open.is_none() => reach.open = Some(at),
			_ => {}
		}
	}
	reach
}

/// Whether `row` was introduced from the directory row `directory` to the
/// peer that holds `registration`, under any contact that directory held.
pub fn introduced_to(row: &Direct, directory: &str, registration: &str) -> bool {
	Reaching::of(row).is_some_and(|row| row.reaches(directory, registration))
}

fn reach(intent: &Intent, directory: &str, registration: &str) -> DirectReach {
	let rows = intent.conversations.as_slice().iter().map(|row| match row {
		Conversation::Direct(row) => Reaching::of(row),
		Conversation::Room(_) => None,
	});
	direct_reach(rows, directory, registration)
}

fn direct_at(intent: &Intent, at: usize) -> Option<&Direct> {
	match intent.conversations.as_slice().get(at)? {
		Conversation::Direct(row) => Some(row.as_ref()),
		Conversation::Room(_) => None,
	}
}

/// The open direct row that reaches the peer holding `registration` through
/// `directory`, by [`direct_reach`].
pub fn open_direct<'a>(intent: &'a Intent, directory: &str, registration: &str) -> Option<&'a Direct> {
	direct_at(intent, reach(intent, directory, registration).open?)
}

/// The position and row of the last closed direct row that reaches the peer
/// holding `registration` through `directory`, by [`direct_reach`].
pub fn reopened_direct<'a>(intent: &'a Intent, directory: &str, registration: &str) -> Option<(usize, &'a Direct)> {
	let at = reach(intent, directory, registration).reopened?;
	Some((at, direct_at(intent, at)?))
}

impl Direct {
	/// Close the conversation a lost connection carried, and clear its inbox,
	/// route, and lines.
	pub fn retire_connection(&mut self) {
		self.closed = true;
		self.inbox = None;
		self.access = None;
		self.lines = List::default();
	}
}

impl Intent {
	/// Whether an open row of `self` other than `row` reaches the registration
	/// that introduced `row`. One registration holds at most one open row,
	/// whoever opened it and whatever rights opened it, so `row` may open only
	/// while this is false.
	pub(crate) fn reaches_another(&self, row: &Direct) -> bool {
		let Some(Reaching {
			directory,
			registration: Some(registration),
			..
		}) = Reaching::of(row)
		else {
			return false;
		};
		self.conversations.as_slice().iter().any(|other| {
			matches!(other, Conversation::Direct(other) if other.id != row.id && !other.closed
				&& introduced_to(other, directory, registration))
		})
	}
}

/// Land `arriving` in the direct row at `at`, the one rule for a route that
/// reaches a row already there, whoever opened it. The row keeps its id and
/// draft, and adds `arriving`'s openings to its own. An open row also keeps
/// its lines and inbox, which the session's next install replaces. A closed
/// row, which only this session's own `startDirect` reopens, takes
/// `arriving`'s, so it reopens with no lines, as a new row starts.
/// Everything else, the peer, source, route, and introduction, is
/// `arriving`'s, and the row is open.
///
/// Returns the row's id and the coordinates it held that nothing in `intent`
/// refers to now: the route it replaced, and the source, inbox, line
/// handles, and introduction custody it dropped. The caller releases them.
fn land(intent: &mut Intent, at: usize, arriving: Direct) -> (Id, Vec<custody::Coordinate>) {
	let Some(Conversation::Direct(row)) = intent.conversations.as_mut_slice().get_mut(at) else {
		unreachable!("direct_reach names only direct rows");
	};
	// What the row keeps is swapped back in, so `previous` ends holding only
	// what the row dropped.
	let mut previous = core::mem::replace(row.as_mut(), arriving);
	core::mem::swap(&mut row.id, &mut previous.id);
	core::mem::swap(&mut row.draft, &mut previous.draft);
	if !previous.closed {
		core::mem::swap(&mut row.lines, &mut previous.lines);
		core::mem::swap(&mut row.inbox, &mut previous.inbox);
	}
	let taken = core::mem::replace(&mut row.openings, core::mem::take(&mut previous.openings));
	for opening in taken.as_slice() {
		if row.openings.as_slice().len() == MAX_TAKEN_OPENINGS {
			row.openings.remove(0);
		}
		// tolerant: a full list gave up its oldest opening above, so this fits.
		let _ = row.openings.try_push(opening.clone());
	}
	row.closed = false;
	let id = row.id.clone();
	let held = Conversation::Direct(Box::new(previous));
	let mut released = Vec::new();
	for coordinate in held.coordinates() {
		if !released.contains(&coordinate) && !intent.coordinates().any(|kept| kept == coordinate) {
			released.push(coordinate);
		}
	}
	(id, released)
}

/// Land an introduction the member sent in the open row that reaches their
/// registration, by [`land`], else add `row` as a new row. A closed row stays
/// as this side left it. `row` is the receiving row the introduction names,
/// holding its opening. Returns the id the conversation continues under, and
/// what the open row dropped, which the caller releases.
pub fn receive_direct(intent: &mut Intent, row: Direct) -> Result<(Id, Vec<custody::Coordinate>), DirectRefusal> {
	let reach = match Reaching::of(&row) {
		Some(Reaching {
			directory,
			registration: Some(registration),
			..
		}) => reach(intent, directory, registration),
		_ => return Err(DirectRefusal::Arguments),
	};
	let Some(at) = reach.open else {
		let id = row.id.clone();
		intent
			.conversations
			.try_push(Conversation::Direct(Box::new(row)))
			.map_err(|_| DirectRefusal::Full)?;
		return Ok((id, Vec::new()));
	};
	Ok(land(intent, at, row))
}

/// The complete acquisition candidate that keeps one introduced route.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirectAdoption {
	/// The direct conversation the route lands in.
	pub conversation: Id,
	/// The current workspace with that conversation open.
	pub intent: Intent,
	/// The receipt's route and the destination it moves to.
	pub mappings: Vec<[custody::Coordinate; 2]>,
	/// The key the acquisition saves the initiating access under.
	pub source: custody::FieldKey<custody::SessionAccess>,
}

/// Why a route cannot be kept. Each but `Open` leaves the receipt intact.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DirectRefusal {
	/// An open conversation, this one, already reaches the peer's
	/// registration. It keeps its own route, so this receipt is given back.
	Open(Id),
	/// The directory was not part of the workspace the command saw.
	Unknown,
	/// The directory left the workspace after the command.
	Removed,
	/// The directory's contact changed after the command.
	Changed,
	/// The directory held no registration to introduce from.
	Unregistered,
	/// The command's arguments are not ones a direct row holds.
	Arguments,
	/// The workspace already holds the most conversations it can.
	Full,
}
impl fmt::Display for DirectRefusal {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Self::Open(_) => "an open direct conversation already reaches this member, release this receipt",
			Self::Unknown => "the initiating directory is unavailable",
			Self::Removed => "the initiating directory was removed, retain its receipt",
			Self::Changed => "the initiating registration changed, retain its receipt",
			Self::Unregistered => "the initiating directory holds no registration",
			Self::Arguments => "the startDirect arguments do not fit a direct conversation",
			Self::Full => "the workspace holds no more conversations",
		})
	}
}
impl core::error::Error for DirectRefusal {}

/// Plan keeping `receipt`'s route. `original` is the workspace the command
/// was prepared against and `current` the one the acquisition is checked at.
/// `operation` is the command's operation. `access` and `source` are fresh
/// keys for the route and the initiating access. An open row that already
/// reaches the registration is `Open`, whether this session or the peer
/// opened it.
pub fn adopt_direct(
	original: &Intent,
	current: &Intent,
	operation: &str,
	start: &StartDirect<'_>,
	receipt: &results::Direct,
	access: custody::FieldKey<custody::DirectAccess>,
	source: custody::FieldKey<custody::SessionAccess>,
) -> Result<DirectAdoption, DirectRefusal> {
	let find = |intent: &'_ Intent| {
		intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id.text().as_str() == Some(start.directory))
			.cloned()
	};
	let before = find(original).ok_or(DirectRefusal::Unknown)?;
	let now = find(current).ok_or(DirectRefusal::Removed)?;
	if !before.same_contact(&now) {
		return Err(DirectRefusal::Changed);
	}
	let (Some(name), Some(callback)) = (before.name, before.inbox) else {
		return Err(DirectRefusal::Unregistered);
	};
	let introduction = Introduction {
		access: before.access,
		name,
		callback,
		registration: Text::new(start.registration.into()).ok_or(DirectRefusal::Arguments)?,
		opening: Text::new(start.opening.into()).ok_or(DirectRefusal::Arguments)?,
	};
	if let Some(open) = open_direct(current, start.directory, start.registration) {
		return Err(DirectRefusal::Open(open.id.clone()));
	}
	let reopened = reopened_direct(current, start.directory, start.registration).map(|(at, row)| (at, row.id.clone()));
	let id = match &reopened {
		Some((_, id)) => id.clone(),
		None => Id::new(operation.into()).ok_or(DirectRefusal::Arguments)?,
	};
	let row = Direct {
		kind: DirectKind::Direct,
		id: id.clone(),
		directory: before.id.clone(),
		peer: Id::new(start.peer.into()).ok_or(DirectRefusal::Arguments)?,
		source: Some(source),
		access: Some(access),
		introduction: Some(introduction),
		openings: Openings::default(),
		inbox: None,
		lines: List::default(),
		closed: false,
		draft: Field::default(),
	};
	let mut intent = current.clone();
	match reopened {
		// The acquisition retires every coordinate its candidate no longer
		// refers to (`Intent::replace_configuration_retiring`), the same set
		// `land` names, so the plan releases nothing itself. The session's
		// participation check holds the plan's releases empty.
		Some((at, _)) => {
			land(&mut intent, at, row);
		}
		None => intent
			.conversations
			.try_push(Conversation::Direct(Box::new(row)))
			.map_err(|_| DirectRefusal::Full)?,
	}
	let role = custody::Role::DirectAccess;
	Ok(DirectAdoption {
		conversation: id,
		intent,
		mappings: Vec::from([[
			custody::Coordinate::new(role, receipt.inbox),
			custody::Coordinate::new(role, access),
		]]),
		source,
	})
}

#[cfg(test)]
mod tests;
