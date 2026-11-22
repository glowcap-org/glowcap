//! Opening a direct conversation. A `startDirect` receipt holds the peer's
//! inbox as a result key, and the workspace reaches the peer only after one
//! acquisition moves that key into a direct row. This module finds the open
//! row that already reaches a peer's registration, and plans the one row the
//! session admits for a new route: the last closed row introduced under the
//! same registration, reopened under its own id and draft, or else a new row
//! whose id is the command's operation. The session's participation check
//! (`imports/participation.rs` in the runtime) is the rule this plan meets.
//! The terminal front and attached views use it, and the page plans the same
//! row in its own completion recipe.
use super::{Conversation, Direct, DirectKind, Directory, Field, Id, Intent, Introduction, custody};
use crate::{
	content::session::results,
	fields::{List, Text},
};
use alloc::{boxed::Box, string::String, vec::Vec};
use core::fmt;

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

/// Whether `row` was introduced from `directory`'s current contact to the
/// peer that holds `registration`.
fn introduces(row: &Direct, directory: &Directory, registration: &str) -> bool {
	row.directory == directory.id
		&& row.introduction.as_ref().is_some_and(|introduction| {
			introduction.access == directory.access
				&& Some(introduction.name) == directory.name
				&& Some(introduction.callback) == directory.inbox
				&& introduction.registration.text().as_str() == Some(registration)
		})
}

/// The open direct row that reaches the peer holding `registration` through
/// `directory`'s current contact. Keyed by registration, so the case of a
/// nickname or a name another member took since cannot select the wrong row.
pub fn open_direct<'a>(intent: &'a Intent, directory: &str, registration: &str) -> Option<&'a Direct> {
	let directory = intent
		.directories
		.as_slice()
		.iter()
		.find(|row| row.id.text().as_str() == Some(directory))?;
	intent.conversations.as_slice().iter().find_map(|row| match row {
		Conversation::Direct(row) if !row.closed && introduces(row, directory, registration) => Some(row.as_ref()),
		_ => None,
	})
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

/// Why a route cannot be kept. Each leaves the receipt intact.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DirectRefusal {
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
/// keys for the route and the initiating access.
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
	let reopened = current
		.conversations
		.as_slice()
		.iter()
		.enumerate()
		.rev()
		.find_map(|(at, row)| match row {
			Conversation::Direct(row)
				if row.closed
					&& row.directory == before.id
					&& row
						.introduction
						.as_ref()
						.is_some_and(|previous| previous.registration.text().as_str() == Some(start.registration)) =>
			{
				Some((at, row.id.clone(), row.draft.clone()))
			}
			_ => None,
		});
	let (id, draft) = match &reopened {
		Some((_, id, draft)) => (id.clone(), draft.clone()),
		None => (
			Id::new(operation.into()).ok_or(DirectRefusal::Arguments)?,
			Field::default(),
		),
	};
	let row = Conversation::Direct(Box::new(Direct {
		kind: DirectKind::Direct,
		id: id.clone(),
		directory: before.id.clone(),
		peer: Id::new(start.peer.into()).ok_or(DirectRefusal::Arguments)?,
		source: Some(source),
		access: Some(access),
		introduction: Some(introduction),
		inbox: None,
		lines: List::default(),
		closed: false,
		draft,
	}));
	let mut intent = current.clone();
	match reopened {
		Some((at, ..)) => intent.conversations.as_mut_slice()[at] = row,
		None => intent.conversations.try_push(row).map_err(|_| DirectRefusal::Full)?,
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
