//! Room membership follows the current directory assignment, independently of
//! a pending request to change it. Replacement registrations require a new seat.
use super::{Directory, Id, Intent, custody::FieldKey};
use crate::{content::session::custody::DirectoryName, fields::Text};
use serde::{Deserialize, Serialize};

/// One bounded nickname copy per room worker or callback selection. It survives
/// the borrowed workspace so replacement of the assigned name or its exact
/// registration fences the old seat. No directory payload or authority is copied. status-allow: replacement state identity
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RoomNickname {
	nick: Text<32>,
	registration: Option<FieldKey<DirectoryName>>,
}
impl RoomNickname {
	pub fn select(intent: &Intent, directory: &Id) -> Option<Self> {
		Self::directory(intent, directory).map(Self::from_directory)
	}
	pub fn directory<'a>(intent: &'a Intent, id: &Id) -> Option<&'a Directory> {
		intent.directories.as_slice().iter().find(|row| row.id == *id)
	}
	pub fn from_directory(row: &Directory) -> Self {
		Self {
			nick: row.assigned_nick.as_ref().unwrap_or(&row.nick).clone(),
			registration: row.name,
		}
	}
	/// A registering directory has no assignment for a room to follow until its
	/// registration lands, so a seat taken before then is fenced when it does.
	pub fn settled(row: &Directory) -> bool {
		row.name.is_some() || !row.registers()
	}
	pub fn matches(&self, intent: &Intent, directory: &Id) -> bool {
		Self::directory(intent, directory).is_some_and(|row| self.matches_directory(row))
	}
	pub fn matches_directory(&self, row: &Directory) -> bool {
		self.registration == row.name && self.nick == *row.assigned_nick.as_ref().unwrap_or(&row.nick)
	}
	pub fn text(&self) -> &Text<32> {
		&self.nick
	}
}
