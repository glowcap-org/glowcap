//! Workspace gestures change one admitted candidate without invoking upstream
//! authority. The runtime commits the candidate and its terminal receipt together.
mod departure;
mod selection;
use super::{
	custody::{Custody, References},
	workspace::{self, Conversation, Intent},
};
use crate::{
	fields::Text,
	room::ArgumentView,
	session::{
		checkpoint::commands::{Command, results},
		command::{Request, Route},
	},
};
use alloc::vec::Vec;
pub use departure::{retire_authority, retire_membership, retire_publication, retire_room_control};
pub use selection::ArchiveSelection;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Arguments,
	Missing,
	Capacity,
}

/// These routes change local intent and custody. Checked imports and external
/// effects have separate admission owners even when they also change intent.
pub fn recognizes(route: Route) -> bool {
	matches!(
		route,
		Route::Checkpoint(
			Command::ClearWorkspace
				| Command::SetDraft
				| Command::Select
				| Command::DismissInvitation
				| Command::SetStanding
				| Command::ChooseDirectoryNickname
				| Command::SetDirectoryStanding
				| Command::SetRoomStanding
				| Command::SetEffectiveStanding
				| Command::SetIgnoredNames
				| Command::SetIgnoredName
				| Command::ChooseHistoryRetention
				| Command::ChooseConnection
				| Command::CloseDirect
				| Command::LeaveConversation
				| Command::LeaveDirectory
				| Command::DropRoomModerator
				| Command::DropRoomManager
				| Command::SelectArchive
				| Command::ReplaceOperationsCapabilities
				| Command::ReplaceOperationsBundle
				| Command::OpenDirect
		) | Route::Result(
			results::Command::TakeRoomLink | results::Command::TakeRoomModerator | results::Command::TakeRoomManager
		)
	)
}
fn field<const LIMIT: usize>(text: &str) -> Result<Text<LIMIT>, Refusal> {
	Text::new(text.into()).ok_or(Refusal::Capacity)
}
fn enabled(text: &str) -> Result<bool, Refusal> {
	match text {
		"true" => Ok(true),
		"false" => Ok(false),
		_ => Err(Refusal::Arguments),
	}
}
fn conversation<'a>(intent: &'a mut Intent, id: &str) -> Result<&'a mut Conversation, Refusal> {
	intent
		.conversations
		.as_mut_slice()
		.iter_mut()
		.find(|row| row.id().text().as_str() == Some(id))
		.ok_or(Refusal::Missing)
}

/// Mutate only a callback-owned candidate. Any refusal discards that candidate.
/// Callers must never pass committed state. Argument views borrow admitted
/// request text. This bounded spine stores no additional argument strings.
pub fn apply<R: References>(
	request: &Request<'_, impl ArgumentView>,
	intent: &mut Intent,
	custody: &mut Custody<R>,
) -> Result<(), Refusal> {
	let args: Vec<_> = request.args().collect();
	match (request.route(), args.as_slice()) {
		(Route::Checkpoint(Command::ChooseDirectoryNickname), [id, nick, allocation]) => {
			if !nick.is_empty() && !crate::room::inbox::valid_nick(nick) {
				return Err(Refusal::Arguments);
			}
			let allocation =
				crate::directory::registration::NicknameAllocation::parse(allocation).ok_or(Refusal::Arguments)?;
			let row = intent
				.directories
				.as_mut_slice()
				.iter_mut()
				.find(|row| row.id.text().as_str() == Some(*id))
				.ok_or(Refusal::Missing)?;
			row.nick = Text::new((*nick).into()).ok_or(Refusal::Capacity)?;
			row.nick_allocation = allocation;
			row.assigned_nick = None;
		}
		(Route::Checkpoint(Command::OpenDirect), [raw]) => {
			let mut next: workspace::Direct = crate::fields::json_object(raw).map_err(|_| Refusal::Arguments)?;
			if next.closed
				|| next.access.is_none()
				|| !next.peer.text().as_str().is_some_and(crate::room::inbox::valid_nick)
			{
				return Err(Refusal::Arguments);
			}
			if let Some(existing) = intent
				.conversations
				.as_mut_slice()
				.iter_mut()
				.find(|row| row.id() == &next.id)
			{
				let Conversation::Direct(existing) = existing else {
					return Err(Refusal::Arguments);
				};
				if existing.directory != next.directory || existing.peer != next.peer || existing.access != next.access
				{
					return Err(Refusal::Arguments);
				}
				existing.closed = false;
				intent.active = Some(existing.id.clone());
			} else {
				intent.active = Some(next.id.clone());
				// Opening selects existing checked custody; it cannot import a bearer.
				next.draft = field("")?;
				intent
					.conversations
					.try_push(Conversation::Direct(alloc::boxed::Box::new(next)))
					.map_err(|_| Refusal::Capacity)?;
			}
		}
		(
			route @ (Route::Checkpoint(
				Command::SelectArchive | Command::ReplaceOperationsCapabilities | Command::ReplaceOperationsBundle,
			)
			| Route::Result(
				results::Command::TakeRoomLink
				| results::Command::TakeRoomModerator
				| results::Command::TakeRoomManager,
			)),
			_,
		) => selection::apply(route, &args, intent, custody)?,
		(
			Route::Checkpoint(
				command @ (Command::LeaveConversation
				| Command::LeaveDirectory
				| Command::DropRoomModerator
				| Command::DropRoomManager),
			),
			_,
		) => {
			departure::apply(command, &args, intent, custody)?;
		}
		(Route::Checkpoint(Command::ClearWorkspace), []) => {
			// Move the old topology out once. The canonical coordinate walk status-allow: replacement state identity
			// derives retirement at its owner without a page-sized client list.
			// Saved independent management and admitted erasure survive reset.
			let mut old = core::mem::replace(intent, Intent::empty());
			intent.accesses = core::mem::take(&mut old.accesses);
			intent.keep_history = old.keep_history;
			intent.connection = old.connection;
			intent.history_erasure = old.history_erasure.take();
			departure::release(intent, custody, old.coordinates());
		}
		(Route::Checkpoint(Command::SetDraft), [id, text]) => {
			let draft = field(text)?;
			match conversation(intent, id)? {
				Conversation::Room(row) => row.draft = draft,
				Conversation::Direct(row) => row.draft = draft,
			}
		}
		(Route::Checkpoint(Command::Select), []) => intent.active = None,
		(Route::Checkpoint(Command::Select), [id]) => {
			let id = conversation(intent, id)?.id().clone();
			intent.active = Some(id);
		}
		(Route::Checkpoint(Command::DismissInvitation), [id]) => {
			let at = intent
				.invitations
				.0
				.iter()
				.position(|row| row.id.text().as_str() == Some(id))
				.ok_or(Refusal::Missing)?;
			let row = intent.invitations.0.remove(at);
			departure::release(intent, custody, row.coordinates());
		}
		(Route::Checkpoint(Command::SetStanding), [text]) => intent.standing = field(text)?,
		(Route::Checkpoint(Command::SetDirectoryStanding), [id, rest @ ..]) if rest.len() <= 1 => {
			let standing = rest.first().map(|text| field(text)).transpose()?;
			intent
				.directories
				.as_mut_slice()
				.iter_mut()
				.find(|row| row.id.text().as_str() == Some(id))
				.ok_or(Refusal::Missing)?
				.standing = standing;
		}
		(Route::Checkpoint(Command::SetRoomStanding), [id, rest @ ..]) if rest.len() <= 1 => {
			let standing = rest.first().map(|text| field(text)).transpose()?;
			let Conversation::Room(row) = conversation(intent, id)? else {
				return Err(Refusal::Missing);
			};
			row.standing = standing;
		}
		(Route::Checkpoint(Command::SetEffectiveStanding), [id, text]) => {
			let value = field(text)?;
			let Conversation::Room(room) = conversation(intent, id)? else {
				return Err(Refusal::Missing);
			};
			if room.standing.is_some() {
				room.standing = Some(value);
			} else {
				let directory = room.directory.clone();
				let directory = intent
					.directories
					.as_mut_slice()
					.iter_mut()
					.find(|row| row.id == directory)
					.ok_or(Refusal::Missing)?;
				if directory.standing.is_some() {
					directory.standing = Some(value);
				} else {
					intent.standing = value;
				}
			}
		}
		(Route::Checkpoint(Command::SetIgnoredNames), [json]) => {
			intent.ignored = serde_json::from_str(json).map_err(|_| Refusal::Arguments)?;
		}
		(Route::Checkpoint(Command::SetIgnoredName), [name, toggle]) => {
			let name = field::<4096>(name)?.text().lowercase();
			if enabled(toggle)? {
				if !intent
					.ignored
					.as_slice()
					.iter()
					.any(|entry| entry.text().lowercase() == name)
				{
					intent
						.ignored
						.try_push(Text::new(name).ok_or(Refusal::Capacity)?)
						.map_err(|_| Refusal::Capacity)?;
				}
			} else {
				intent.ignored.0.retain(|entry| entry.text().lowercase() != name);
			}
		}
		(Route::Checkpoint(Command::ChooseHistoryRetention), [toggle]) => intent.keep_history = enabled(toggle)?,
		(Route::Checkpoint(Command::ChooseConnection), [mode]) => {
			let connection = match *mode {
				"relay" => workspace::Connection::Relay,
				"webrtc" => workspace::Connection::Webrtc,
				_ => return Err(Refusal::Arguments),
			};
			intent.connection = connection;
		}
		(Route::Checkpoint(Command::CloseDirect), [id]) => {
			let Conversation::Direct(row) = conversation(intent, id)? else {
				return Err(Refusal::Missing);
			};
			row.closed = true;
		}
		_ => return Err(Refusal::Arguments),
	}
	Ok(())
}
