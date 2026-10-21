//! A fresh Host cannot use its predecessor's registrations or membership routes.
//! Retire their selections before exposing the workspace. Nickname intent,
//! history, drafts, initiating sources and original receipts remain durable.
use super::{records, refuse};
use glowcap::{Argument, Ref, Result, loam};
use rooms_application::content::session::{custody, workspace};

pub(super) fn invoke(call: &mut loam::Call<'_>, input: loam::Invocation<'_>, root: &Ref) -> Result<Argument> {
	if call.source()? != *root || !input.args.is_empty() {
		return Err(refuse(
			"Host registration retirement requires the private startup owner",
		));
	}
	let mut record = records::decode(input)?;
	let mut changed = false;
	let conversations = record.intent.conversations.as_slice();
	for row in record.intent.directories.as_mut_slice() {
		changed |= row.name.is_some() || row.inbox.is_some() || row.assigned_nick.is_some();
		if let Some(key) = row.name.take() {
			let field = coordinate(custody::Role::DirectoryName, key);
			if !witnessed(conversations, field) {
				record.custody.remove(field);
			}
		}
		if let Some(key) = row.inbox.take() {
			let field = coordinate(custody::Role::DirectoryInbox, key);
			if !witnessed(conversations, field) {
				record.custody.remove(field);
			}
		}
		row.assigned_nick = None;
	}
	for row in record.intent.conversations.as_mut_slice() {
		let lines = match row {
			workspace::Conversation::Direct(row) => {
				changed |= !row.closed || row.access.is_some() || row.inbox.is_some();
				row.closed = true;
				if let Some(key) = row.access.take() {
					record.custody.remove(coordinate(custody::Role::DirectAccess, key));
				}
				if let Some(key) = row.inbox.take() {
					record.custody.remove(coordinate(custody::Role::DirectInbox, key));
				}
				&mut row.lines
			}
			workspace::Conversation::Room(row) => {
				changed |= row.seat.is_some() || row.subject.is_some() || row.files.is_some() || row.inbox.is_some();
				if let Some(key) = row.seat.take() {
					record.custody.remove(coordinate(custody::Role::RoomSeat, key));
				}
				if let Some(key) = row.subject.take() {
					record.custody.remove(coordinate(custody::Role::RoomSubject, key));
				}
				if let Some(key) = row.files.take() {
					record.custody.remove(coordinate(custody::Role::RoomFiles, key));
				}
				if let Some(key) = row.inbox.take() {
					record.custody.remove(coordinate(custody::Role::RoomInbox, key));
				}
				&mut row.lines
			}
		};
		changed |= !lines.is_empty();
		for line in lines.as_slice() {
			record.custody.remove(coordinate(custody::Role::Line, line.handle));
		}
		*lines = Default::default();
	}
	// Foreign listings belong to the publishing connection. Keep no selected
	// lease after its Host ends, and retain any room authority still selected
	// by another conversation or operation. Moving the old list adds no copy. status-allow: replacement state identity
	let publications = core::mem::take(&mut record.intent.peering);
	changed |= !publications.is_empty();
	for row in publications.as_slice() {
		for field in [
			coordinate(custody::Role::PublicationLease, row.lease),
			coordinate(custody::Role::RoomAccess, row.room),
		] {
			if !record.intent.coordinates().any(|held| held == field) {
				record.custody.remove(field);
			}
		}
	}
	if changed {
		record
			.intent
			.validate(&record.custody)
			.map_err(|_| refuse("invalid retired Host registration intent"))?;
		records::replace(call, input, &mut record)?;
	}
	Ok(Argument::Void)
}

fn coordinate<K>(role: custody::Role, key: custody::FieldKey<K>) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}

// Only direct introductions can still select these directory fields after
// directory retirement. Borrow their fixed witnesses; do not walk message
// handles or allocate another inventory during startup.
fn witnessed(conversations: &[workspace::Conversation], field: custody::Coordinate) -> bool {
	conversations.iter().any(|row| {
		let workspace::Conversation::Direct(row) = row else {
			return false;
		};
		let Some(witness) = &row.introduction else { return false };
		match field.role {
			custody::Role::DirectoryName => coordinate(field.role, witness.name) == field,
			custody::Role::DirectoryInbox => coordinate(field.role, witness.callback) == field,
			_ => false,
		}
	})
}
