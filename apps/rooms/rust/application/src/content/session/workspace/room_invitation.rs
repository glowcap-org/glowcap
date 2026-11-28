//! Stage an actual entrance received over a direct conversation. A repeated
//! activity token is a replay. An independently offered same-name entrance
//! stays in invitations so the operator can choose between the two.
use super::*;
use alloc::boxed::Box;

pub struct RoomInvitation {
	pub id: Id,
	pub name: Text<32, true>,
	pub access: custody::FieldKey<custody::RoomAccess>,
	pub source: custody::FieldKey<custody::SessionAccess>,
}
impl RoomInvitation {
	pub fn stage(&self, intent: &mut Intent, direct: &Id, directory: &Id) -> Result<bool, &'static str> {
		let dm = intent
			.conversations
			.as_slice()
			.iter()
			.find_map(|row| match row {
				Conversation::Direct(dm) if &dm.id == direct && &dm.directory == directory && !dm.closed => Some(dm),
				_ => None,
			})
			.ok_or("the original direct conversation is no longer open")?;
		if intent.conversations.as_slice().iter().any(|row| row.id() == &self.id) {
			return Ok(false);
		}
		let stored = intent.invitations.as_slice().iter().position(|inv| inv.id == self.id);
		if let Some(at) = stored {
			let inv = &intent.invitations.as_slice()[at];
			if inv.directory != *directory
				|| inv.authority != InvitationAuthority::RoomAccess(self.access)
				|| inv.source != Some(self.source)
			{
				return Err("the retained invitation has different authority");
			}
		}
		if intent
			.conversations
			.as_slice()
			.iter()
			.any(|row| matches!(row,Conversation::Room(room) if &room.directory==directory && room.name==self.name))
		{
			if stored.is_some() {
				return Ok(false);
			}
			intent
				.invitations
				.try_push(Invitation {
					id: self.id.clone(),
					directory: directory.clone(),
					authority: InvitationAuthority::RoomAccess(self.access),
					source: Some(self.source),
					label: Field::new(self.name.text().clone()).ok_or("invalid room label")?,
					from: Field::new(dm.peer.text().clone()).ok_or("invalid direct peer")?,
				})
				.map_err(|_| "workspace invitations are full")?;
		} else {
			let room = Room::invited(
				self.id.clone(),
				directory.clone(),
				self.name.clone(),
				self.access,
				Some(self.source),
			);
			intent
				.conversations
				.try_push(Conversation::Room(Box::new(room)))
				.map_err(|_| "workspace conversations are full")?;
			if let Some(at) = stored {
				intent.invitations.remove(at);
			}
		}
		Ok(true)
	}
}
