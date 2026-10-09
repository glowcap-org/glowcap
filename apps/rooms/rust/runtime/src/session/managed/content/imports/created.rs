//! Creation appends one checked room to the current workspace atomically.
//! Receipt targets fence the original directory; unrelated membership writes
//! never cause this independent append to conflict or erase newer intent.
use super::*;

impl Request<'_> {
	pub(super) fn created_directory<'r>(
		&self,
		record: &'r MetadataRecord,
	) -> Result<[Retained<'r, records::Metadata>; 2]> {
		let original = original_text(text(self.intent)?)?;
		if original.len() < 5 || text(&original[2])? != "openManagedRoom" {
			return Err(refuse("room append requires an original creation receipt"));
		}
		let directory = record
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id.text().as_str() == Some(text(&original[3]).unwrap_or("")))
			.ok_or_else(|| refuse("creation directory was removed"))?;
		let current = record
			.custody
			.get(Coordinate {
				role: custody::Role::DirectoryAccess,
				key: custody::FieldKey::new(directory.access.slot(), directory.access.generation()),
			})
			.ok_or_else(|| refuse("creation directory custody is absent"))?;
		let target = self
			.receipt(record)?
			.targets
			.as_slice()
			.first()
			.ok_or_else(|| refuse("creation directory target is absent"))?;
		if target.borrowed().coordinate() != current.coordinate() {
			return Err(refuse("creation directory selection was replaced"));
		}
		Ok([target.borrowed(), current])
	}
	pub(super) fn created_workspace(&self, record: &MetadataRecord) -> Result<workspace::Intent> {
		self.created_directory(record)?;
		let replacement = self.replacement.as_ref().expect("creation replacement");
		if !replacement.releases.is_empty() || self.selections.len() != 2 {
			return Err(refuse("creation selects exactly its room and manager"));
		}
		let candidate = workspace::Intent::decode(replacement.intent).map_err(|_| refuse("invalid creation recipe"))?;
		let [workspace::Conversation::Room(room)] = candidate.conversations.as_slice() else {
			return Err(refuse("creation selects one room"));
		};
		let original = original_text(text(self.intent)?)?;
		let matches = |role, key: Option<custody::Coordinate>| {
			self.selections
				.iter()
				.any(|selection| selection.destination.role == role && Some(selection.destination) == key)
		};
		let coordinate = |role, slot, generation| Coordinate {
			role,
			key: custody::FieldKey::new(slot, generation),
		};
		if room.id.text() != self.operation.text()
			|| room.directory.text().as_str() != Some(text(&original[3])?)
			|| room.name.text().as_str() != Some(text(&original[4])?)
			|| room
				.source
				.map(|key| coordinate(custody::Role::SessionAccess, key.slot(), key.generation()))
				!= replacement.source
			|| replacement.source.is_none()
			|| !matches(
				custody::Role::RoomAccess,
				room.access
					.map(|key| coordinate(custody::Role::RoomAccess, key.slot(), key.generation())),
			) || !matches(
			custody::Role::RoomControl,
			room.control
				.map(|key| coordinate(custody::Role::RoomControl, key.slot(), key.generation())),
		) || room.accepted.is_some()
			|| room.public_entry.is_some()
			|| room.publication.is_some()
			|| room.inbox.is_some()
			|| room.seat.is_some()
			|| room.topic.is_some()
			|| room.files.is_some()
			|| room.moderator.is_some()
			|| !room.lines.is_empty()
			|| room.standing.is_some()
			|| room.draft.text().as_str() != Some("")
			|| room.reconnect != workspace::Reconnect::Requested
		{
			return Err(refuse("room selection differs from its original creation"));
		}
		if record
			.intent
			.conversations
			.as_slice()
			.iter()
			.any(|row| row.id() == &room.id)
		{
			return Err(refuse("creation room is already selected by another result"));
		}
		let mut intent = record.intent.clone();
		intent.active = Some(room.id.clone());
		intent
			.conversations
			.try_push(workspace::Conversation::Room(room.clone()))
			.map_err(|_| refuse("workspace conversations are full"))?;
		Ok(intent)
	}
}
