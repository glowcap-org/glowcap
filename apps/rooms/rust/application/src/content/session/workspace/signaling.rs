//! Signaling follows one exact registered name and its initiating session.
use super::{Directory, Id, Intent, custody};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SignalingSelection {
	pub id: Id,
	pub access: custody::FieldKey<custody::DirectoryAccess>,
	pub name: custody::FieldKey<custody::DirectoryName>,
	pub source: custody::FieldKey<custody::SessionAccess>,
}
impl SignalingSelection {
	pub fn directory(row: &Directory) -> Option<Self> {
		Some(Self {
			id: row.id.clone(),
			access: row.access,
			name: row.name?,
			source: row.source?,
		})
	}
	pub fn matches(&self, intent: &Intent) -> bool {
		intent.directories.as_slice().iter().any(|row| {
			row.id == self.id
				&& row.access == self.access
				&& row.name == Some(self.name)
				&& row.source == Some(self.source)
		})
	}
}
