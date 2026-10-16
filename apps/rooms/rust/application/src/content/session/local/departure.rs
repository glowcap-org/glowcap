//! Removing intent releases only its unused custody selections. Moved rows
//! retain their own payload backing while the candidate retires their fields.
use super::Refusal;
use crate::{
	content::session::{
		custody::{Coordinate, Custody, FieldKey, References, Role},
		workspace::{Conversation, Id, Intent, Reconnect, coordinate},
	},
	session::checkpoint::commands::Command,
};

pub(super) fn release<R: References>(
	intent: &Intent,
	custody: &mut Custody<R>,
	fields: impl IntoIterator<Item = Coordinate>,
) {
	for field in fields {
		if !intent.coordinates().any(|selected| selected == field) {
			// Another removed row may have already released the same selection.
			custody.remove(field);
		}
	}
}

/// Confirmed revocation retires aliases of its exact entry or moderator field.
/// A subscribed seat is independent authority and remains held. Without an
/// entrance, future reconnection requires an explicit replacement grant.
pub fn retire_authority<R: References>(
	intent: &mut Intent,
	custody: &mut Custody<R>,
	key: FieldKey<super::super::custody::RoomAccess>,
) {
	for row in intent.conversations.as_mut_slice() {
		let Conversation::Room(room) = row else { continue };
		if room.access == Some(key) {
			room.access = None;
			room.reconnect = Reconnect::Manual;
		}
		if room.moderator == Some(key) {
			room.moderator = None;
		}
	}
	release(intent, custody, [coordinate(Role::RoomAccess, key)]);
}

/// A retired manager publication cannot clear a replacement control generation.
/// Independently subscribed seats and moderator grants remain selected.
pub fn retire_room_control<R: References>(
	intent: &mut Intent,
	custody: &mut Custody<R>,
	key: FieldKey<super::super::custody::RoomControl>,
) {
	for row in intent.conversations.as_mut_slice() {
		if let Conversation::Room(room) = row
			&& room.control == Some(key)
		{
			room.control = None;
		}
	}
	release(intent, custody, [coordinate(Role::RoomControl, key)]);
}

/// Retire every workspace alias of the selected exact seat before dispatching
/// its goodbye. Files, subject facet and line lists move out of their existing bounded rows.
/// Only their borrowed coordinates survive through alias-aware release. This
/// adds no payload copy or field inventory. Other seats, independent imports
/// and receipt occurrences remain held. Call only on the admitted candidate.
/// The runtime commits this change with its unresolved effect receipt.
pub fn retire_membership<R: References>(
	intent: &mut Intent,
	custody: &mut Custody<R>,
	seat: FieldKey<super::super::custody::RoomSeat>,
) -> Result<(), Refusal> {
	let mut retired = false;
	loop {
		let removed = intent.conversations.as_mut_slice().iter_mut().find_map(|row| {
			let Conversation::Room(room) = row else {
				return None;
			};
			if room.seat != Some(seat) {
				return None;
			}
			room.seat = None;
			room.reconnect = Reconnect::Manual;
			Some((
				room.subject.take(),
				room.files.take(),
				room.inbox.take(),
				core::mem::take(&mut room.lines),
			))
		});
		let Some((subject, files, inbox, lines)) = removed else {
			break;
		};
		retired = true;
		release(
			intent,
			custody,
			core::iter::once(coordinate(Role::RoomSeat, seat))
				.chain(subject.map(|key| coordinate(Role::RoomSubject, key)))
				.chain(files.map(|key| coordinate(Role::RoomFiles, key)))
				.chain(inbox.map(|key| coordinate(Role::RoomInbox, key)))
				.chain(lines.as_slice().iter().map(|row| coordinate(Role::Line, row.handle))),
		);
	}
	if retired { Ok(()) } else { Err(Refusal::Missing) }
}
/// Retire all aliases of the exact publication lease in the admitted candidate.
/// The receipt keeps its own occurrence. Independent room custody survives.
pub fn retire_publication<R: References>(
	intent: &mut Intent,
	custody: &mut Custody<R>,
	lease: FieldKey<super::super::custody::PublicationLease>,
) -> Result<(), Refusal> {
	let mut retired = false;
	while let Some(at) = intent.peering.as_slice().iter().position(|row| row.lease == lease) {
		let row = intent.peering.0.remove(at);
		retired = true;
		release(
			intent,
			custody,
			[
				coordinate(Role::RoomAccess, row.room),
				coordinate(Role::PublicationLease, row.lease),
			],
		);
	}
	if retired { Ok(()) } else { Err(Refusal::Missing) }
}
fn select_remaining(intent: &mut Intent, directory: Option<&Id>) {
	intent.active = intent
		.conversations
		.as_slice()
		.iter()
		.filter(|row| !matches!(row, Conversation::Direct(direct) if direct.closed))
		.min_by_key(|row| {
			(
				matches!(row, Conversation::Direct(_)),
				directory.is_some_and(|directory| row.directory() != directory),
			)
		})
		.map(|row| row.id().clone());
}
fn remove_conversation<R: References>(intent: &mut Intent, custody: &mut Custody<R>, at: usize) -> Conversation {
	let row = intent.conversations.0.remove(at);
	while let Some(at) = intent
		.archive_shares
		.as_slice()
		.iter()
		.position(|share| &share.channel == row.id())
	{
		let share = intent.archive_shares.0.remove(at);
		release(intent, custody, share.coordinates());
	}
	release(intent, custody, row.coordinates());
	row
}

/// All candidates belong to the callback. Removed rows move out of its existing
/// lists, so retirement needs no duplicate field inventory or payload copies.
/// Each removed selection checks the bounded remaining intent for aliases.
/// Receipts and unrelated imports keep their independent custody.
pub(super) fn apply<R: References>(
	command: Command,
	args: &[&str],
	intent: &mut Intent,
	custody: &mut Custody<R>,
) -> Result<(), Refusal> {
	match (command, args) {
		(Command::LeaveConversation, [id]) => {
			let at = intent
				.conversations
				.0
				.iter()
				.position(|row| row.id().text().as_str() == Some(id))
				.ok_or(Refusal::Missing)?;
			let row = remove_conversation(intent, custody, at);
			if intent.active.as_ref() == Some(row.id()) {
				select_remaining(intent, Some(row.directory()));
			}
		}
		(Command::LeaveDirectory, [id]) => {
			let at = intent
				.directories
				.0
				.iter()
				.position(|row| row.id.text().as_str() == Some(id))
				.ok_or(Refusal::Missing)?;
			let selected_removed = intent.active.as_ref().is_some_and(|selected| {
				intent
					.conversations
					.0
					.iter()
					.any(|row| row.id() == selected && row.directory().text().as_str() == Some(id))
			});
			while let Some(at) = intent
				.conversations
				.0
				.iter()
				.position(|row| row.directory().text().as_str() == Some(id))
			{
				remove_conversation(intent, custody, at);
			}
			while let Some(at) = intent
				.invitations
				.0
				.iter()
				.position(|row| row.directory.text().as_str() == Some(id))
			{
				let row = intent.invitations.0.remove(at);
				release(intent, custody, row.coordinates());
			}
			while let Some(at) = intent
				.peering
				.0
				.iter()
				.position(|row| row.directory.text().as_str() == Some(id))
			{
				let row = intent.peering.0.remove(at);
				release(
					intent,
					custody,
					[
						coordinate(Role::RoomAccess, row.room),
						coordinate(Role::PublicationLease, row.lease),
					],
				);
			}
			let row = intent.directories.0.remove(at);
			release(intent, custody, row.coordinates());
			if selected_removed {
				select_remaining(intent, None);
			}
		}
		(Command::DropRoomModerator | Command::DropRoomManager, [id, expected]) => {
			let expected: FieldKey<()> = serde_json::from_str(expected).map_err(|_| Refusal::Arguments)?;
			let Conversation::Room(row) = super::conversation(intent, id)? else {
				return Err(Refusal::Missing);
			};
			let (role, selected) = if command == Command::DropRoomManager {
				(
					Role::RoomControl,
					row.control.map(|key| FieldKey::new(key.slot(), key.generation())),
				)
			} else {
				(
					Role::RoomAccess,
					row.moderator.map(|key| FieldKey::new(key.slot(), key.generation())),
				)
			};
			if selected != Some(expected) {
				return Err(Refusal::Missing);
			}
			if command == Command::DropRoomManager {
				row.control = None;
			} else {
				row.moderator = None;
			}
			release(intent, custody, [Coordinate { role, key: expected }]);
		}
		_ => return Err(Refusal::Arguments),
	}
	Ok(())
}
