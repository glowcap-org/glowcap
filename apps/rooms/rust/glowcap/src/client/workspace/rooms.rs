//! Public-room intent retains the exact directory and publication for reopening.
use super::*;
use rooms_application::fields::{List, Text};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PublicRoomImport {
	pub id: workspace::Id,
	pub directory: workspace::Id,
	pub name: Text<32, true>,
	pub publication: Text<128, true>,
	pub source: custody::FieldKey<custody::SessionAccess>,
}
impl PublicRoomImport {
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>()
			+ self.id.text().heap_bytes()
			+ self.directory.text().heap_bytes()
			+ self.name.text().heap_bytes()
			+ self.publication.text().heap_bytes()
	}
}
impl<D: Deadline + Clone> Workspace<D> {
	/// Retain one complete candidate and its actual invoking source. Acquisition
	/// installs them atomically. Membership belongs to the managed supervisor.
	/// The public directory row supplies held authority, while the exact listing
	/// publication supplies the generation. No accepted visit is persisted.
	pub async fn prepare_public_room(
		&self,
		expected: u64,
		selected: PublicRoomImport,
	) -> Result<Acquisition<D>, Error> {
		let mut snapshot = self.snapshot().await?;
		if snapshot.revision != expected {
			return Err(Error::WorkspaceConflict);
		}
		if snapshot
			.intent
			.conversations
			.as_slice()
			.iter()
			.any(|row| row.id() == &selected.id)
		{
			return Err(loam::refusal("public room selection is already installed").into());
		}
		let access = snapshot
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id == selected.directory)
			.ok_or_else(|| loam::refusal("public room directory is no longer held"))?
			.access;
		let room = workspace::Room {
			kind: workspace::RoomKind::Room,
			id: selected.id,
			directory: selected.directory,
			name: selected.name,
			source: Some(selected.source),
			inbox: None,
			access: None,
			accepted: None,
			public_entry: Some(workspace::PublicEntry { access }),
			publication: Some(selected.publication),
			seat: None,
			subject: None,
			files: None,
			lines: List::default(),
			moderator: None,
			control: None,
			reconnect: workspace::Reconnect::Requested,
			standing: None,
			draft: Text::default(),
		};
		snapshot
			.intent
			.conversations
			.try_push(workspace::Conversation::Room(Box::new(room)))
			.map_err(|_| loam::refusal("workspace conversations are full"))?;
		Ok(self.prepare_acquisition(
			expected,
			vec![Import {
				coordinate: custody::Coordinate {
					role: custody::Role::SessionAccess,
					key: custody::FieldKey::new(selected.source.slot(), selected.source.generation()),
				},
				reference: self.reference.clone(),
				uri: None,
			}],
			&[],
			&snapshot.intent,
		)?)
	}
}
