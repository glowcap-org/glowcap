//! Custody selections refer only to exact checked fields. Importing actual
//! authority has its own shared save admission before these local gestures.
use super::{Refusal, conversation, departure};
use crate::{
	content::session::{
		custody::{self, Custody, FieldKey, References, Role},
		workspace::{Conversation, Intent, coordinate},
	},
	fields::List,
	session::{
		checkpoint::commands::{Command, results},
		command::Route,
	},
};
use serde::{Deserialize, Serialize};

/// Selecting an archive names access and optional management separately. An
/// absent control clears the previous selection rather than carrying it across
/// to a different archive. Neither coordinate restores or grants authority.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArchiveSelection {
	pub access: FieldKey<custody::ArchiveAccess>,
	pub control: Option<FieldKey<custody::ArchiveControl>>,
}

fn selected<R: References, K>(custody: &Custody<R>, role: Role, key: FieldKey<K>) -> Result<FieldKey<K>, Refusal> {
	if custody.get(coordinate(role, key)).is_none() {
		return Err(Refusal::Missing);
	}
	Ok(key)
}
fn take<K: PartialEq>(slot: &mut Option<FieldKey<K>>, key: FieldKey<K>) -> Result<(), Refusal> {
	if slot.is_some_and(|held| held != key) {
		return Err(Refusal::Missing);
	}
	*slot = Some(key);
	Ok(())
}

/// JSON allocates only the bounded candidate selections. Room keys are scalar.
/// Operator replacement moves its old list and borrows its coordinates through
/// alias-aware retirement. No capability copy, restoration or role conversion
/// occurs here. The callback commits this candidate with its terminal receipt.
pub(super) fn apply<R: References>(
	route: Route,
	args: &[&str],
	intent: &mut Intent,
	custody: &mut Custody<R>,
) -> Result<(), Refusal> {
	match (route, args) {
		(Route::Checkpoint(Command::ReplaceOperationsBundle), [raw]) => {
			let next: List<crate::content::session::workspace::Operations, 64> =
				serde_json::from_str(raw).map_err(|_| Refusal::Arguments)?;
			for (at, row) in next.as_slice().iter().enumerate() {
				if !row.valid()
					|| custody.get(row.handle).is_none()
					|| next.as_slice()[..at].iter().any(|prior| prior.handle == row.handle)
				{
					return Err(Refusal::Arguments);
				}
			}
			let old = core::mem::replace(&mut intent.operations, next);
			departure::release(intent, custody, old.as_slice().iter().map(|row| row.handle));
		}
		(
			Route::Result(
				command @ (results::Command::TakeRoomLink
				| results::Command::TakeRoomModerator
				| results::Command::TakeRoomManager),
			),
			[id, raw],
		) => {
			let Conversation::Room(room) = conversation(intent, id)? else {
				return Err(Refusal::Missing);
			};
			if command == results::Command::TakeRoomManager {
				let key = serde_json::from_str(raw).map_err(|_| Refusal::Arguments)?;
				take(&mut room.control, selected(custody, Role::RoomControl, key)?)?;
			} else {
				let key = serde_json::from_str(raw).map_err(|_| Refusal::Arguments)?;
				let key = selected(custody, Role::RoomAccess, key)?;
				take(
					if command == results::Command::TakeRoomLink {
						&mut room.access
					} else {
						&mut room.moderator
					},
					key,
				)?;
				if command == results::Command::TakeRoomLink {
					let accepted = room.accepted.take();
					departure::release(
						intent,
						custody,
						accepted.map(|key| coordinate(Role::AcceptedAccess, key)),
					);
				}
			}
		}
		(Route::Checkpoint(Command::SelectArchive), rest) if rest.len() <= 1 => {
			let selection: Option<ArchiveSelection> = rest
				.first()
				.map(|raw| crate::fields::json_object(raw))
				.transpose()
				.map_err(|_| Refusal::Arguments)?;
			if let Some(selection) = selection {
				selected(custody, Role::ArchiveAccess, selection.access)?;
				if let Some(control) = selection.control {
					selected(custody, Role::ArchiveControl, control)?;
				}
			}
			let old = [
				intent.archive.map(|key| coordinate(Role::ArchiveAccess, key)),
				intent.archive_control.map(|key| coordinate(Role::ArchiveControl, key)),
			];
			intent.archive = selection.map(|selection| selection.access);
			intent.archive_control = selection.and_then(|selection| selection.control);
			departure::release(intent, custody, old.into_iter().flatten());
		}
		(Route::Checkpoint(Command::ReplaceOperationsCapabilities), [raw]) => {
			let next: List<FieldKey<custody::Operator>, 64> =
				serde_json::from_str(raw).map_err(|_| Refusal::Arguments)?;
			for (at, &key) in next.as_slice().iter().enumerate() {
				selected(custody, Role::Operator, key)?;
				if next.as_slice()[..at].contains(&key) {
					return Err(Refusal::Arguments);
				}
			}
			let old = core::mem::replace(&mut intent.operators, next);
			departure::release(
				intent,
				custody,
				old.as_slice().iter().map(|&key| coordinate(Role::Operator, key)),
			);
		}
		_ => return Err(Refusal::Arguments),
	}
	Ok(())
}
