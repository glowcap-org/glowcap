//! Received room links use the checkpoint's invitation schema and validation.
//! Constructing one does not accept or join the offered room.
use super::{
	Checkpoint, Routes,
	commands::{self, Error},
	fields::*,
	footprint::HeapBytes,
	model::{Invitation, InvitationKind},
	validate,
};
use crate::text::DocumentText;

/// Each borrowed field is bounded before it is retained. The validated record
/// intentionally has no Debug implementation because it contains bearer text.
pub struct RoomLinkInput<'a> {
	pub id: &'a str,
	pub directory: &'a str,
	pub locator: &'a str,
	pub nick: &'a str,
	pub label: &'a str,
	pub from: &'a str,
	pub link: &'a str,
}
pub struct RoomLink(pub(super) Invitation);
impl RoomLink {
	pub fn new(input: RoomLinkInput<'_>, routes: &impl Routes) -> Result<Self, Error> {
		let invitation = Invitation {
			kind: InvitationKind::RoomLink,
			id: field(input.id)?,
			directory: field(input.directory)?,
			locator: field(input.locator)?,
			nick: field(input.nick)?,
			label: field(input.label)?,
			from: field(input.from)?,
			link: field(input.link)?,
		};
		validate_received(&invitation, routes)?;
		Ok(Self(invitation))
	}
	pub fn id(&self) -> &Id {
		&self.0.id
	}
	pub fn retained_bytes(&self) -> usize {
		core::mem::size_of::<Self>().saturating_add(self.0.heap_bytes())
	}
	pub fn encoded(&self) -> Result<DocumentText, Error> {
		serde_json::to_string(&self.0)
			.map(Into::into)
			.map_err(|_| Error::Arguments)
	}
	pub fn material(&self) -> Result<DocumentText, Error> {
		commands::Command::ReceiveRoomLinkInvitation.material(&[self.encoded()?])
	}
	/// Receipt deduplicates by either invitation identity or the exact bearer,
	/// matching the command reducer. No replacement checkpoint is needed then.
	pub fn present(&self, checkpoint: &Checkpoint) -> bool {
		present(&checkpoint.0, &self.0)
	}
}
pub(super) fn present(state: &super::model::State, invitation: &Invitation) -> bool {
	state
		.invitations
		.0
		.iter()
		.any(|i| i.id == invitation.id || i.link == invitation.link)
}
pub(super) fn validate_received(invitation: &Invitation, routes: &impl Routes) -> Result<(), Error> {
	if !validate::nick(&invitation.nick.0, true) {
		return Err(Error::NamedDirectory);
	}
	validate::route(&invitation.link.0, routes, true)?;
	Ok(())
}
fn field<const N: usize, const NONEMPTY: bool>(input: &str) -> Result<Text<N, NONEMPTY>, Error> {
	if !Text::<N, NONEMPTY>::accepts_utf16(input.encode_utf16()) {
		return Err(Error::Arguments);
	}
	Ok(Text(input.into()))
}
