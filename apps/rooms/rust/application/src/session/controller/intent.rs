//! Session-controller intents bind commands to the authority they observed.
use super::{Authority, Error};
use crate::{
	session::{checkpoint::commands::results::Command, command, fields::Id},
	text::DocumentText,
};
use alloc::{string::String, vec::Vec};
use serde::Deserialize;

#[derive(PartialEq, Eq)]
pub(super) struct Intent {
	name: String,
	command: Command,
	target: DocumentText,
	args: Vec<DocumentText>,
}
impl Intent {
	pub fn new(name: &str, command: Command, args: Vec<DocumentText>) -> Result<Self, Error> {
		if !command.arity().contains(&args.len())
			|| args
				.iter()
				.any(|arg| arg.utf16().take(command::MAX_ARGUMENT_UNITS + 1).count() > command::MAX_ARGUMENT_UNITS)
			|| args.iter().map(DocumentText::heap_bytes).sum::<usize>() > command::MAX_MATERIAL_BYTES
		{
			return Err(Error::Arguments);
		}
		let target = if command == Command::TakeRoomLink {
			#[derive(Deserialize)]
			struct Room {
				id: Id,
			}
			#[derive(Deserialize)]
			struct Entry {
				conversation: Room,
			}
			let source = args[0].json_source().ok_or(Error::Arguments)?;
			crate::fields::json_object::<Entry>(&source)
				.map_err(|_| Error::Arguments)?
				.conversation
				.id
				.0
		} else if command == Command::OpenManagedRoom {
			#[derive(Deserialize)]
			struct Room {
				id: Id,
			}
			let source = args[0].json_source().ok_or(Error::Arguments)?;
			crate::fields::json_object::<Room>(&source)
				.map_err(|_| Error::Arguments)?
				.id
				.0
		} else {
			Id::new(args[0].clone()).ok_or(Error::Arguments)?.0
		};
		Ok(Self {
			name: name.into(),
			command,
			target,
			args,
		})
	}
	pub fn key(&self) -> (String, DocumentText) {
		(self.name.clone(), self.target.clone())
	}
	pub fn bytes(&self) -> usize {
		// Include both the intent target and the map's separately owned key.
		core::mem::size_of::<Self>()
			+ self.name.capacity() * 2
			+ self.target.heap_bytes() * 2
			+ self.args.capacity() * core::mem::size_of::<DocumentText>()
			+ self.args.iter().map(DocumentText::heap_bytes).sum::<usize>()
	}
	pub fn held<'a>(&self, rooms: impl IntoIterator<Item = Authority<'a>>) -> bool {
		let Some(room) = rooms.into_iter().find(|r| r.id == &self.target) else {
			return false;
		};
		match self.command {
			// A resumed entry can select a different, already-held identity.
			// Reissue its ledgered operation to observe that exact result.
			Command::TakeRoomLink => false,
			Command::OpenManagedRoom | Command::EnsureRoomLink | Command::LinkRoom => room.link.is_some(),
			Command::TakeRoomModerator => room
				.steward
				.is_some_and(|held| self.args.get(1).is_none_or(|wanted| wanted == held)),
			Command::TakeRoomManager => room.manager == self.args.get(1),
			Command::RecoverRoomManager => room.manager.is_some(),
		}
	}
}
