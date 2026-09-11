use super::*;
use alloc::boxed::Box;

pub(super) fn receive(state: &mut State, arg: &DocumentText, routes: &impl Routes) -> Result<(), Error> {
	let invite: Invitation = json(arg, MAX_JSON)?;
	receive_value(state, invite, routes)
}
fn receive_value(state: &mut State, invite: Invitation, routes: &impl Routes) -> Result<(), Error> {
	// These are record-schema checks, including on a deduplicated delivery.
	super::super::invitations::validate_received(&invite, routes)?;
	if !super::super::invitations::present(state, &invite) {
		push(&mut state.invitations, invite)?;
	}
	Ok(())
}

/// Typed receipt can consume the validated record without serializing and
/// parsing it back through the command's wire argument representation.
pub fn receive_room_link(
	current: &Checkpoint,
	invite: &super::super::invitations::RoomLink,
	routes: &impl Routes,
) -> Result<Checkpoint, Error> {
	let mut next = current.0.clone();
	receive_value(&mut next, invite.0.clone(), routes)?;
	validate::state(&mut next, routes)?;
	Ok(Checkpoint(next))
}
pub(super) fn accept(state: &mut State, args: &[DocumentText], routes: &impl Routes) -> Result<(), Error> {
	let index = state
		.invitations
		.0
		.iter()
		.position(|i| i.id.0 == args[0])
		.ok_or(Error::Missing)?;
	let invite = &state.invitations.0[index];
	if validate::route(&invite.locator.0, routes, false)? != invite.directory.0 {
		return Err(Error::Conflict);
	}
	if !validate::nick(&invite.nick.0, false) {
		return Err(Error::NamedDirectory);
	}
	let directory = state.directories.0.iter_mut().find(|d| d.id == invite.directory);
	if let Some(directory) = directory {
		if directory.nick.0.utf16().next().is_some() && directory.nick != invite.nick {
			return Err(Error::Conflict);
		}
		directory.nick = invite.nick.clone();
	} else {
		push(
			&mut state.directories,
			Directory {
				id: invite.directory.clone(),
				locator: Text(invite.locator.0.clone()),
				home: false,
				reached: None,
				nick: invite.nick.clone(),
				standing: Nullable::Null,
			},
		)?;
	}
	if let Some(existing) = state.conversations.0.iter().find(|c| c.id().0 == args[1]) {
		let Conversation::Room(room) = existing else {
			return Err(Error::Conflict);
		};
		if room.directory != invite.directory || room.link.as_ref() != Some(&invite.link) {
			return Err(Error::Conflict);
		}
	} else {
		let label = if invite.label.0.utf16().next().is_none() {
			"private room".into()
		} else {
			invite.label.0.clone()
		};
		push(
			&mut state.conversations,
			Conversation::Room(Box::new(Room {
				kind: RoomKind::Room,
				id: text(&args[1])?,
				directory: invite.directory.clone(),
				name: text(&label)?,
				held: true,
				reconnect: None,
				link: Some(invite.link.clone()),
				manager: None,
				steward: None,
				publication_id: None,
				standing: Nullable::Null,
				draft: Text("".into()),
				bridge_intent: Presence::Missing,
			})),
		)?;
	}
	state.active = Nullable::Value(text(&args[1])?);
	state.invitations.0.remove(index);
	Ok(())
}

/// Receiving a live handoff and accepting it are one checkpoint transaction.
/// Validate the intermediate receive exactly as the two historical reducers do,
/// while cloning the checkpoint only once. A failed acceptance publishes neither.
pub fn accept_handed(
	current: &Checkpoint,
	invitation: &DocumentText,
	args: &[DocumentText; 2],
	routes: &impl Routes,
) -> Result<Checkpoint, Error> {
	if args[1].utf16().next().is_none() {
		return Err(Error::Arguments);
	}
	let invite: Invitation = json(invitation, MAX_JSON)?;
	if invite.id.0 != args[0] {
		return Err(Error::Conflict);
	}
	let mut next = current.0.clone();
	receive_value(&mut next, invite, routes)?;
	validate::state(&mut next, routes)?;
	accept(&mut next, args, routes)?;
	validate::state(&mut next, routes)?;
	Ok(Checkpoint(next))
}
