//! The Rooms operator: the server-wide inventories a holder reads in
//! bounded pages under one revision, the search that cuts them server-side,
//! and the acts each row offers. The policy names every act exactly. The
//! adapter performs it and answers what changed.
pub mod inventory;
pub mod page;
pub mod revision;
pub mod rows;
pub mod view;

use crate::room::{ArgumentView, ListArgument};
use alloc::{
	string::{String, ToString},
	vec::Vec,
};

/// Rows one page carries.
pub const MAX_PAGE: u64 = 32;
/// A search, in characters.
pub const MAX_QUERY: usize = 128;
/// Rows one retire batch acts on.
pub const MAX_RETIRE_BATCH: u64 = 256;
/// Members one room row names before `membersMore`.
pub const MAX_MEMBERS_PER_ROOM: usize = MAX_PAGE as usize;

/// The inventories, in the order a whole snapshot answers them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Category {
	Stewardships,
	Links,
	Registrations,
	Sessions,
	Rooms,
	References,
	Trouble,
}

pub const CATEGORIES: [Category; 7] = [
	Category::Stewardships,
	Category::Links,
	Category::Registrations,
	Category::Sessions,
	Category::Rooms,
	Category::References,
	Category::Trouble,
];

impl Category {
	pub fn parse(name: &str) -> Option<Self> {
		CATEGORIES.into_iter().find(|category| category.name() == name)
	}
	pub const fn name(self) -> &'static str {
		match self {
			Self::Stewardships => "stewardships",
			Self::Links => "links",
			Self::Registrations => "registrations",
			Self::Sessions => "sessions",
			Self::Rooms => "rooms",
			Self::References => "references",
			Self::Trouble => "trouble",
		}
	}
}

/// The kinds of retained reference, in reading order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ReferenceKind {
	Membership,
	Line,
	Upload,
	ForeignRoom,
	PendingPeering,
	Registration,
	OfferedInbox,
	Signaling,
	SignalExchange,
}

pub const REFERENCE_KINDS: [ReferenceKind; 9] = [
	ReferenceKind::Membership,
	ReferenceKind::Line,
	ReferenceKind::Upload,
	ReferenceKind::ForeignRoom,
	ReferenceKind::PendingPeering,
	ReferenceKind::Registration,
	ReferenceKind::OfferedInbox,
	ReferenceKind::Signaling,
	ReferenceKind::SignalExchange,
];

impl ReferenceKind {
	pub fn parse(name: &str) -> Option<Self> {
		REFERENCE_KINDS.into_iter().find(|kind| kind.name() == name)
	}
	pub const fn name(self) -> &'static str {
		match self {
			Self::Membership => "membership",
			Self::Line => "line",
			Self::Upload => "upload",
			Self::ForeignRoom => "foreign-room",
			Self::PendingPeering => "pending-peering",
			Self::Registration => "registration",
			Self::OfferedInbox => "offered-inbox",
			Self::Signaling => "signaling",
			Self::SignalExchange => "signal-exchange",
		}
	}
}

/// What `resetOperatorScope` may reset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResetScope {
	Links,
	Registrations,
	Sessions,
	Rooms,
	Runtime,
	All,
}

impl ResetScope {
	pub fn parse(name: &str) -> Option<Self> {
		Some(match name {
			"links" => Self::Links,
			"registrations" => Self::Registrations,
			"sessions" => Self::Sessions,
			"rooms" => Self::Rooms,
			"runtime" => Self::Runtime,
			"all" => Self::All,
			_ => return None,
		})
	}
}

/// A snapshot ask, read from the wire: the whole inventory at cursor zero,
/// or one category's page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SnapshotAsk {
	Whole {
		query: String,
		kind: Option<ReferenceKind>,
	},
	Page {
		category: Category,
		cursor: u64,
		limit: u64,
		query: String,
		kind: Option<ReferenceKind>,
	},
}

/// Why an operator ask is refused. `Display` is the exact line the holder
/// reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// The arguments miss the verb's shape, which the caller names.
	Shape(String),
	/// `operatorSnapshot`'s whole-inventory search is not one text.
	SnapshotSearch,
	/// `operatorSnapshot`'s reference kind is not one.
	SnapshotKind,
	/// `operatorSnapshot`'s cursor or limit is out of range.
	SnapshotRange,
	/// `operatorSnapshot`'s category is unknown.
	SnapshotCategory,
	/// A reference kind was given for a category other than references.
	SnapshotKindCategory,
	/// `operatorSnapshot`'s query is over the limit.
	SnapshotQueryLength,
	/// `operatorRetireMatching`'s category is unknown.
	RetireCategory,
	/// `operatorRetireMatching`'s query is over the limit.
	RetireQueryLength,
	/// `operatorRetireMatching`'s batch limit is out of range.
	RetireLimit,
	/// A reference kind was given for a category other than references.
	RetireKindCategory,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Shape(shape) => f.write_str(shape),
			Self::SnapshotSearch => f.write_str("operatorSnapshot takes one optional search"),
			Self::SnapshotKind => f.write_str("operatorSnapshot reference kind is invalid"),
			Self::SnapshotRange => f.write_str("operatorSnapshot cursor or limit is out of range"),
			Self::SnapshotCategory => f.write_str("operatorSnapshot category is unknown"),
			Self::SnapshotKindCategory => f.write_str("operatorSnapshot reference kind is invalid for this category"),
			Self::SnapshotQueryLength => f.write_str("operatorSnapshot query is too long"),
			Self::RetireCategory => f.write_str("operatorRetireMatching category is unknown"),
			Self::RetireQueryLength => f.write_str("operatorRetireMatching query is too long"),
			Self::RetireLimit => f.write_str("operatorRetireMatching batch limit is out of range"),
			Self::RetireKindCategory => {
				f.write_str("operatorRetireMatching reference kind is invalid for this category")
			}
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

/// Read `operatorSnapshot`'s arguments. Two or fewer name the whole
/// inventory. Three to five name one page.
pub fn read_snapshot<A: ListArgument>(args: &[A]) -> Result<SnapshotAsk, Invalid> {
	if args.len() <= 2 {
		let query = match args.first() {
			None => String::new(),
			Some(query) => query
				.text()
				.filter(|query| query.chars().count() <= MAX_QUERY)
				.ok_or(Invalid::SnapshotSearch)?
				.into(),
		};
		let kind = match args.get(1) {
			None => None,
			Some(kind) => Some(
				kind.text()
					.and_then(ReferenceKind::parse)
					.ok_or(Invalid::SnapshotKind)?,
			),
		};
		return Ok(SnapshotAsk::Whole { query, kind });
	}
	let shape = "operatorSnapshot takes a category, cursor, limit, optional query, and optional reference kind";
	if args.len() > 5 {
		return Err(Invalid::Shape(shape.into()));
	}
	let (Some(category), Some(cursor), Some(limit)) = (args[0].text(), args[1].integer(), args[2].integer()) else {
		return Err(Invalid::Shape(shape.into()));
	};
	let query = match args.get(3) {
		None => "",
		Some(query) => query.text().ok_or_else(|| Invalid::Shape(shape.into()))?,
	};
	if cursor < 0 || cursor > i128::from(i64::MAX) || limit < 1 || limit > i128::from(MAX_PAGE) {
		return Err(Invalid::SnapshotRange);
	}
	let category = Category::parse(category).ok_or(Invalid::SnapshotCategory)?;
	let kind = match args.get(4) {
		None => None,
		Some(kind) => {
			let kind = kind.text().and_then(ReferenceKind::parse);
			if kind.is_none() || category != Category::References {
				return Err(Invalid::SnapshotKindCategory);
			}
			kind
		}
	};
	if query.chars().count() > MAX_QUERY {
		return Err(Invalid::SnapshotQueryLength);
	}
	Ok(SnapshotAsk::Page {
		category,
		cursor: cursor as u64,
		limit: limit as u64,
		query: query.into(),
		kind,
	})
}

/// A retire ask: everything matching `query` in `category`, `limit` rows
/// at a time.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RetireAsk {
	pub category: Category,
	pub query: String,
	pub limit: u64,
	pub kind: Option<ReferenceKind>,
}

pub fn read_retire<A: ArgumentView>(args: &[A]) -> Result<RetireAsk, Invalid> {
	let shape = "operatorRetireMatching takes a category, query, batch limit, and optional reference kind";
	if args.len() < 3 || args.len() > 4 {
		return Err(Invalid::Shape(shape.into()));
	}
	let (Some(category), Some(query), Some(limit)) = (args[0].text(), args[1].text(), args[2].integer()) else {
		return Err(Invalid::Shape(shape.into()));
	};
	let category = Category::parse(category).ok_or(Invalid::RetireCategory)?;
	if query.chars().count() > MAX_QUERY {
		return Err(Invalid::RetireQueryLength);
	}
	if limit < 1 || limit > i128::from(MAX_RETIRE_BATCH) {
		return Err(Invalid::RetireLimit);
	}
	let kind = match args.get(3) {
		None => None,
		Some(kind) => {
			let kind = kind.text().and_then(ReferenceKind::parse);
			if kind.is_none() || category != Category::References {
				return Err(Invalid::RetireKindCategory);
			}
			kind
		}
	};
	Ok(RetireAsk {
		category,
		query: query.into(),
		limit: limit as u64,
		kind,
	})
}

/// One text argument, exactly.
pub fn one_text<A: ArgumentView>(args: &[A], shape: &str) -> Result<String, Invalid> {
	let [value] = args else {
		return Err(Invalid::Shape(shape.into()));
	};
	value
		.text()
		.map(String::from)
		.ok_or_else(|| Invalid::Shape(shape.into()))
}

/// Two text arguments, exactly.
pub fn two_texts<A: ArgumentView>(args: &[A], shape: &str) -> Result<(String, String), Invalid> {
	let [first, second] = args else {
		return Err(Invalid::Shape(shape.into()));
	};
	match (first.text(), second.text()) {
		(Some(first), Some(second)) => Ok((first.into(), second.into())),
		_ => Err(Invalid::Shape(shape.into())),
	}
}

/// The verbs, as the wire names them.
pub mod verbs {
	pub const SNAPSHOT: &str = "operatorSnapshot";
	pub const RETIRE_MATCHING: &str = "operatorRetireMatching";
	pub const WATCH: &str = "watch";
	pub const UNWATCH: &str = "unwatch";
	pub const CHANGED: &str = "changed";
	pub const REVOKE_ROOM_LINK: &str = "revokeRoomLink";
	pub const REVOKE_ROOM_AUTHORITY: &str = "revokeRoomAuthority";
	pub const REVOKE_NICK: &str = "revokeNick";
	pub const DISCONNECT_SESSION: &str = "disconnectSession";
	pub const REMOVE_ROOM: &str = "removeOperatorRoom";
	pub const RELEASE_REFERENCE: &str = "releaseOperatorReference";
	pub const CLEAR_TROUBLE: &str = "clearOperatorTrouble";
	pub const RESET_SCOPE: &str = "resetOperatorScope";
	pub const GIVE_STEWARD: &str = "giveSteward";
	pub const GIVE_MANAGER: &str = "giveManager";
	pub const REVOKE_STEWARD: &str = "revokeSteward";
	pub const UNREGISTER_ROOM: &str = "unregisterRoom";
	pub const SET_ROOM_POLICY: &str = "setRoomPolicy";
}

/// The categories a whole snapshot answers, each as one page at cursor
/// zero, in order.
pub fn whole_pages<'a>(
	query: &str,
	kind: Option<ReferenceKind>,
	mut page: impl FnMut(Category, &str, Option<ReferenceKind>) -> page::Page<rows::Row> + 'a,
) -> Vec<(Category, page::Page<rows::Row>)> {
	CATEGORIES
		.into_iter()
		.map(|category| {
			let kind = if category == Category::References { kind } else { None };
			(category, page(category, query, kind))
		})
		.collect()
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(Invalid::Shape("shape line".into()), "shape line"),
			(Invalid::SnapshotSearch, "operatorSnapshot takes one optional search"),
			(Invalid::SnapshotKind, "operatorSnapshot reference kind is invalid"),
			(
				Invalid::SnapshotRange,
				"operatorSnapshot cursor or limit is out of range",
			),
			(Invalid::SnapshotCategory, "operatorSnapshot category is unknown"),
			(
				Invalid::SnapshotKindCategory,
				"operatorSnapshot reference kind is invalid for this category",
			),
			(Invalid::SnapshotQueryLength, "operatorSnapshot query is too long"),
			(Invalid::RetireCategory, "operatorRetireMatching category is unknown"),
			(Invalid::RetireQueryLength, "operatorRetireMatching query is too long"),
			(
				Invalid::RetireLimit,
				"operatorRetireMatching batch limit is out of range",
			),
			(
				Invalid::RetireKindCategory,
				"operatorRetireMatching reference kind is invalid for this category",
			),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}
}
