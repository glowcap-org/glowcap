//! Received archive selections retain the exact source of their arrival.
//! Descriptive scope cannot reconstruct the reader or its admission authority.
use super::{Id, Intent, InvalidIntent, coordinate, custody};
use crate::archive::{Filter, ShareKind};
use serde::{Deserialize, Serialize};

pub const MAX_ARCHIVE_SHARES: usize = 64;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ReceivedArchive {
	pub id: Id,
	pub channel: Id,
	pub directory: Id,
	pub kind: ShareKind,
	pub conversation: Option<Id>,
	pub from: Id,
	pub access: custody::FieldKey<custody::ArchiveAccess>,
	pub source: custody::FieldKey<custody::SessionAccess>,
	pub durable: bool,
}
impl ReceivedArchive {
	pub fn coordinates(&self) -> impl Iterator<Item = custody::Coordinate> {
		[
			coordinate(custody::Role::ArchiveAccess, self.access),
			coordinate(custody::Role::SessionAccess, self.source),
		]
		.into_iter()
	}
}
impl Intent {
	pub(super) fn validate_archive_shares(&self) -> Result<(), InvalidIntent> {
		for (at, row) in self.archive_shares.as_slice().iter().enumerate() {
			if self.archive_shares.as_slice()[..at]
				.iter()
				.any(|prior| prior.id == row.id)
			{
				return Err(InvalidIntent::Duplicate);
			}
			if !self
				.conversations
				.as_slice()
				.iter()
				.any(|conversation| conversation.id() == &row.channel)
			{
				return Err(InvalidIntent::Directory);
			}
			Filter::shared(
				row.kind,
				row.directory.text().clone(),
				row.conversation.as_ref().map(|id| id.text().clone()),
			)
			.map_err(|_| InvalidIntent::Custody)?;
		}
		Ok(())
	}
}
