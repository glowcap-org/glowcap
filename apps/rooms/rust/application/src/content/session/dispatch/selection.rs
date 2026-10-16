//! Exact workspace selection checks, independent of command grammar.
use super::*;
impl Dispatch {
	pub(super) fn room<'a>(intent: &'a workspace::Intent, id: &str) -> Result<&'a workspace::Room, Refusal> {
		intent
			.conversations
			.as_slice()
			.iter()
			.find_map(|conversation| match conversation {
				workspace::Conversation::Room(room) if room.id.text().as_str() == Some(id) => Some(room.as_ref()),
				_ => None,
			})
			.ok_or(Refusal)
	}
	pub(super) fn direct<'a>(intent: &'a workspace::Intent, id: &str) -> Result<&'a workspace::Direct, Refusal> {
		intent
			.conversations
			.as_slice()
			.iter()
			.find_map(|row| match row {
				workspace::Conversation::Direct(row) if row.id.text().as_str() == Some(id) && !row.closed => {
					Some(row.as_ref())
				}
				_ => None,
			})
			.ok_or(Refusal)
	}
	/// Coordinates only select already held custody. The upstream object still
	/// authorizes the exact verb. A RoomAccess field does not confer moderation.
	pub fn target(&self, intent: &workspace::Intent) -> Result<custody::Coordinate, Refusal> {
		let (role, slot, generation) = match &self.selection {
			Selection::Operations(coordinate, kind) => {
				if !intent
					.operations
					.as_slice()
					.iter()
					.any(|row| row.handle == *coordinate && row.kind == *kind && row.valid())
				{
					return Err(Refusal);
				}
				(coordinate.role, coordinate.key.slot(), coordinate.key.generation())
			}
			Selection::Post(id) => {
				let row = intent
					.conversations
					.as_slice()
					.iter()
					.find(|row| row.id().text().as_str() == Some(id.as_str()))
					.ok_or(Refusal)?;
				match row {
					workspace::Conversation::Room(room) => {
						let key = room.seat.ok_or(Refusal)?;
						(custody::Role::RoomSeat, key.slot(), key.generation())
					}
					workspace::Conversation::Direct(direct) if !direct.closed => {
						let key = direct.access.ok_or(Refusal)?;
						(custody::Role::DirectAccess, key.slot(), key.generation())
					}
					_ => return Err(Refusal),
				}
			}
			Selection::Invitation(id) => {
				let authority = intent
					.invitations
					.as_slice()
					.iter()
					.find(|row| row.id.text().as_str() == Some(id.as_str()))
					.ok_or(Refusal)?
					.authority;
				let workspace::InvitationAuthority::Offer(key) = authority else {
					return Err(Refusal);
				};
				(custody::Role::Offer, key.slot(), key.generation())
			}
			Selection::Introduction(id) => {
				let direct = Self::direct(intent, id)?;
				let witness = direct.introduction.as_ref().ok_or(Refusal)?;
				if !intent.directories.as_slice().iter().any(|row| {
					row.id == direct.directory
						&& row.access == witness.access
						&& row.name == Some(witness.name)
						&& row.inbox == Some(witness.callback)
						&& row.source == direct.source
				}) {
					return Err(Refusal);
				}
				(
					custody::Role::DirectoryAccess,
					witness.access.slot(),
					witness.access.generation(),
				)
			}
			Selection::Direct(id) => {
				let direct = intent
					.conversations
					.as_slice()
					.iter()
					.find_map(|row| match row {
						workspace::Conversation::Direct(row) if row.id.text().as_str() == Some(id) && !row.closed => {
							Some(row)
						}
						_ => None,
					})
					.ok_or(Refusal)?;
				let key = direct.access.ok_or(Refusal)?;
				(custody::Role::DirectAccess, key.slot(), key.generation())
			}
			Selection::Publication(id, expected) => {
				let key = intent
					.peering
					.as_slice()
					.iter()
					.find(|row| row.id.text().as_str() == Some(id.as_str()))
					.ok_or(Refusal)?
					.lease;
				if key != *expected {
					return Err(Refusal);
				}
				(custody::Role::PublicationLease, key.slot(), key.generation())
			}
			Selection::Directory(id) => {
				let key = intent
					.directories
					.as_slice()
					.iter()
					.find(|directory| directory.id.text().as_str() == Some(id.as_str()))
					.ok_or(Refusal)?
					.access;
				(custody::Role::DirectoryAccess, key.slot(), key.generation())
			}
			Selection::Operator(key) if intent.operators.as_slice().contains(key) => {
				(custody::Role::Operator, key.slot(), key.generation())
			}
			Selection::Room(id, selection) => {
				let room = Self::room(intent, id)?;
				match selection {
					RoomTarget::Link if room.control.is_some() => {
						let key = room.control.ok_or(Refusal)?;
						(custody::Role::RoomControl, key.slot(), key.generation())
					}
					RoomTarget::Entrance | RoomTarget::Link => {
						match (room.access, room.accepted, room.public_entry.as_ref()) {
							(Some(key), None, None) => (custody::Role::RoomAccess, key.slot(), key.generation()),
							(None, Some(key), None) => (custody::Role::AcceptedAccess, key.slot(), key.generation()),
							(None, None, Some(entry)) => (
								custody::Role::DirectoryAccess,
								entry.access.slot(),
								entry.access.generation(),
							),
							_ => return Err(Refusal),
						}
					}
					RoomTarget::Seat | RoomTarget::RetiringSeat(_) => {
						let key = room.seat.ok_or(Refusal)?;
						if matches!(selection, RoomTarget::RetiringSeat(expected) if *expected != key) {
							return Err(Refusal);
						}
						(custody::Role::RoomSeat, key.slot(), key.generation())
					}
					RoomTarget::Subject => {
						let key = room.subject.ok_or(Refusal)?;
						(custody::Role::RoomSubject, key.slot(), key.generation())
					}
					RoomTarget::Moderator => {
						let key = room.moderator.ok_or(Refusal)?;
						(custody::Role::RoomAccess, key.slot(), key.generation())
					}
					RoomTarget::Control => {
						let key = room.control.ok_or(Refusal)?;
						(custody::Role::RoomControl, key.slot(), key.generation())
					}
				}
			}
			Selection::Line(id, line) => {
				let key = intent
					.conversations
					.as_slice()
					.iter()
					.find(|row| row.id().text().as_str() == Some(id.as_str()))
					.ok_or(Refusal)?
					.lines()
					.iter()
					.find(|row| row.id.get() == line.get())
					.ok_or(Refusal)?
					.handle;
				(custody::Role::Line, key.slot(), key.generation())
			}
			_ => return Err(Refusal),
		};
		Ok(custody::Coordinate {
			role,
			key: custody::FieldKey::new(slot, generation),
		})
	}
	/// Additional authority is selected from existing checked custody. A callback
	/// coordinate cannot import an inbox or replace it after worker installation.
	pub fn targets(&self, intent: &workspace::Intent) -> Result<Vec<custody::Coordinate>, Refusal> {
		let mut targets = Vec::with_capacity(1 + usize::from(self.argument.is_some()));
		targets.push(self.target(intent)?);
		if let Some(argument) = &self.argument {
			let (role, key) = match argument {
				ArgumentTarget::Revocation {
					room,
					moderator,
					expected,
				} => {
					let row = Self::room(intent, room)?;
					let key = if *moderator { row.moderator } else { row.access }.ok_or(Refusal)?;
					if key != *expected {
						return Err(Refusal);
					}
					(
						custody::Role::RoomAccess,
						custody::FieldKey::new(key.slot(), key.generation()),
					)
				}
				ArgumentTarget::DirectInbox(key) => {
					let (Selection::Direct(id) | Selection::Introduction(id)) = &self.selection else {
						return Err(Refusal);
					};
					if !intent.conversations.as_slice().iter().any(|row| {
						matches!(row, workspace::Conversation::Direct(row)
						if row.id.text().as_str() == Some(id.as_str()) && !row.closed && row.inbox == Some(*key))
					}) {
						return Err(Refusal);
					}
					(
						custody::Role::DirectInbox,
						custody::FieldKey::new(key.slot(), key.generation()),
					)
				}
				ArgumentTarget::DirectoryInbox(key) => {
					let Selection::Directory(id) = &self.selection else {
						return Err(Refusal);
					};
					if !intent
						.directories
						.as_slice()
						.iter()
						.any(|row| row.id.text().as_str() == Some(id.as_str()) && row.inbox == Some(*key))
					{
						return Err(Refusal);
					}
					(
						custody::Role::DirectoryInbox,
						custody::FieldKey::new(key.slot(), key.generation()),
					)
				}
				ArgumentTarget::SelectedRoom(id) => {
					let room = Self::room(intent, id)?;
					let Selection::Direct(direct) = &self.selection else {
						return Err(Refusal);
					};
					if !intent.conversations.as_slice().iter().any(|row| matches!(row, workspace::Conversation::Direct(row) if row.id.text().as_str() == Some(direct.as_str()) && row.directory == room.directory)) { return Err(Refusal); }
					let key = room.access.ok_or(Refusal)?;
					(
						custody::Role::RoomAccess,
						custody::FieldKey::new(key.slot(), key.generation()),
					)
				}
				ArgumentTarget::Inbox(key) => {
					let Selection::Room(id, _) = &self.selection else {
						return Err(Refusal);
					};
					if Self::room(intent, id)?.inbox != Some(*key) {
						return Err(Refusal);
					}
					(
						custody::Role::RoomInbox,
						custody::FieldKey::new(key.slot(), key.generation()),
					)
				}
				ArgumentTarget::Room(key) => (
					custody::Role::RoomAccess,
					custody::FieldKey::new(key.slot(), key.generation()),
				),
			};
			targets.push(custody::Coordinate { role, key });
		}
		Ok(targets)
	}
}
