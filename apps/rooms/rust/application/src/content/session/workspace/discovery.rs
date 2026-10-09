//! Discovery has no membership or nickname authority. Its callback remains
//! bound to the exact directory and initiating source selected at creation.
use super::{Directory, Id, Intent, custody};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiscoverySelection {
	pub id: Id,
	pub access: custody::FieldKey<custody::DirectoryAccess>,
	pub source: custody::FieldKey<custody::SessionAccess>,
}
impl DiscoverySelection {
	pub fn directory(row: &Directory) -> Option<Self> {
		Some(Self {
			id: row.id.clone(),
			access: row.access,
			source: row.source?,
		})
	}
	pub fn matches(&self, intent: &Intent) -> bool {
		intent
			.directories
			.as_slice()
			.iter()
			.any(|row| row.id == self.id && row.access == self.access && row.source == Some(self.source))
	}
}
