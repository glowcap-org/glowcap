//! Creation appends one checked room to the current workspace atomically.
//! Receipt targets fence the original directory. Unrelated membership writes
//! never cause this independent append to conflict or erase newer intent.
use super::*;

impl Request<'_> {
	/// The original creation command, decoded once per admission.
	fn creation_original(&self) -> Result<Vec<Argument>> {
		original_text(text(self.intent)?)
	}
	pub(super) fn created_directory<'r>(
		&self,
		record: &'r MetadataRecord,
		receipt: &'r custody::EffectReceipt<records::Metadata>,
	) -> Result<[Retained<'r, records::Metadata>; 2]> {
		self.created_directory_in(record, receipt, &self.creation_original()?)
	}
	fn created_directory_in<'r>(
		&self,
		record: &'r MetadataRecord,
		receipt: &'r custody::EffectReceipt<records::Metadata>,
		original: &[Argument],
	) -> Result<[Retained<'r, records::Metadata>; 2]> {
		if original.len() < 5 || text(&original[2])? != "openManagedRoom" {
			return Err(refuse("room append requires an original creation receipt"));
		}
		let directory_id = text(&original[3])?;
		let directory = record
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id.text().as_str() == Some(directory_id))
			.ok_or_else(|| refuse("creation directory was removed"))?;
		let current = record
			.custody
			.get(Coordinate {
				role: custody::Role::DirectoryAccess,
				key: custody::FieldKey::new(directory.access.slot(), directory.access.generation()),
			})
			.ok_or_else(|| refuse("creation directory custody is absent"))?;
		let target = receipt
			.targets
			.as_slice()
			.first()
			.ok_or_else(|| refuse("creation directory target is absent"))?;
		if target.borrowed().coordinate() != current.coordinate() {
			return Err(refuse("creation directory selection was replaced"));
		}
		Ok([target.borrowed(), current])
	}
	pub(super) fn created_workspace(
		&self,
		record: &MetadataRecord,
		receipt: &custody::EffectReceipt<records::Metadata>,
		replacement: &Replacement,
	) -> Result<workspace::Intent> {
		let original = self.creation_original()?;
		self.created_directory_in(record, receipt, &original)?;
		if !replacement.releases.is_empty() || self.selections.len() != 2 {
			return Err(refuse("creation selects exactly its room and manager"));
		}
		let candidate = workspace::Intent::decode(replacement.intent).map_err(|_| refuse("invalid creation recipe"))?;
		let [workspace::Conversation::Room(room)] = candidate.conversations.as_slice() else {
			return Err(refuse("creation selects one room"));
		};
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
			|| room.subject.is_some()
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
		intent
			.conversations
			.try_push(workspace::Conversation::Room(room.clone()))
			.map_err(|_| refuse("workspace conversations are full"))?;
		Ok(intent)
	}
}
