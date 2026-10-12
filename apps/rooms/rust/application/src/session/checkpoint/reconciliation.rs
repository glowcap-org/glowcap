//! Exact live facts reconciled into durable Rooms intent. A fact carries the
//! generation or route it observed. Obsolete observations do not write state.
mod room_context;
pub use super::fields::{Bearer, Field, Id, Text};
use super::{
	Checkpoint,
	commands::{CommandRoutes, Error},
	model::*,
	validate,
};
use crate::{session::state::Impact, text::DocumentText};
pub use room_context::RoomContext;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Authority {
	Room,
	Manager,
	Steward,
}

/// Typed application facts, not a wire encoding or permission to use a room.
/// The runtime that holds the corresponding capability supplies each fact.
#[derive(Clone)]
pub enum Fact {
	DirectoryReached {
		directory: Id,
		locator: Id,
	},
	RoomReconnect {
		context: RoomContext,
		conversation: Id,
		connected: bool,
	},
	RoomAuthority {
		context: RoomContext,
		conversation: Id,
		kind: Authority,
		token: Text<16384>,
		claimable: bool,
	},
	RoomAuthorityAcquired {
		context: RoomContext,
		conversation: Id,
		room_link: Bearer,
		manager_link: Bearer,
	},
	RoomPublication {
		context: RoomContext,
		conversation: Id,
		expected: Option<Field>,
		publication: Field,
	},
	DirectAccepted {
		conversation: Id,
		directory: Id,
		peer: Id,
		registration: Field,
	},
	DirectRegistrationRetired {
		conversation: Id,
		directory: Id,
		peer: Id,
		registration: Field,
	},
}
impl Fact {
	pub fn room_context(&self) -> Option<&RoomContext> {
		match self {
			Self::RoomReconnect { context, .. }
			| Self::RoomAuthority { context, .. }
			| Self::RoomAuthorityAcquired { context, .. }
			| Self::RoomPublication { context, .. } => Some(context),
			_ => None,
		}
	}
	pub fn retained_bytes(&self) -> usize {
		let fields: &[&DocumentText] = match self {
			Self::DirectoryReached { directory, locator } => &[&directory.0, &locator.0],
			Self::RoomReconnect { conversation, .. } => &[&conversation.0],
			Self::RoomAuthority {
				conversation, token, ..
			} => &[&conversation.0, &token.0],
			Self::RoomAuthorityAcquired {
				conversation,
				room_link,
				manager_link,
				..
			} => &[&conversation.0, &room_link.0, &manager_link.0],
			Self::RoomPublication {
				conversation,
				expected,
				publication,
				..
			} => {
				let extra = expected.as_ref().map_or(0, |v| v.0.heap_bytes());
				return core::mem::size_of::<Self>()
					.saturating_add(conversation.0.heap_bytes())
					.saturating_add(publication.0.heap_bytes())
					.saturating_add(extra)
					.saturating_add(self.room_context().map_or(0, RoomContext::heap_bytes));
			}
			Self::DirectAccepted {
				conversation,
				directory,
				peer,
				registration,
			}
			| Self::DirectRegistrationRetired {
				conversation,
				directory,
				peer,
				registration,
			} => &[&conversation.0, &directory.0, &peer.0, &registration.0],
		};
		fields.iter().fold(
			core::mem::size_of::<Self>().saturating_add(self.room_context().map_or(0, RoomContext::heap_bytes)),
			|sum, value| sum.saturating_add(value.heap_bytes()),
		)
	}
	pub fn impact(&self) -> Impact {
		match self {
			Self::DirectoryReached { .. } | Self::RoomReconnect { .. } => Impact::Presentation,
			_ => Impact::Realization,
		}
	}
	/// A stable issue subject within this session. It does not carry bearer text.
	pub fn subject(&self) -> (&'static str, &DocumentText) {
		match self {
			Self::DirectoryReached { directory, .. } => ("directory-reached", &directory.0),
			Self::RoomReconnect { conversation, .. } => ("room-reconnect", &conversation.0),
			Self::RoomAuthority { conversation, .. } => ("authority", &conversation.0),
			Self::RoomAuthorityAcquired { conversation, .. } => ("authority-acquired", &conversation.0),
			Self::RoomPublication { conversation, .. } => ("room-publication", &conversation.0),
			Self::DirectAccepted { conversation, .. } => ("direct-accepted", &conversation.0),
			Self::DirectRegistrationRetired { conversation, .. } => ("direct-retired", &conversation.0),
		}
	}
	pub fn apply(&self, current: &Checkpoint, routes: &impl CommandRoutes) -> Result<Option<Checkpoint>, Error> {
		// Decide against the borrowed graph before cloning. Duplicate deliveries
		// and delayed retirement notices require no replacement graph allocation.
		let Some(edit) = self.admit(&current.0, routes)? else {
			return Ok(None);
		};
		let mut next = current.0.clone();
		match edit {
			Edit::Directory(index) => next.directories.0[index].reached = Some(true),
			Edit::Room(index) => {
				let Conversation::Room(room) = &mut next.conversations.0[index] else {
					unreachable!("admitted room index");
				};
				match self {
					Self::RoomReconnect { connected, .. } => {
						room.reconnect = if *connected { None } else { Some(Reconnect::Manual) }
					}
					Self::RoomAuthority { kind, .. } => match kind {
						Authority::Manager => room.manager = None,
						Authority::Steward => room.steward = None,
						Authority::Room => {
							room.link = None;
							room.steward = None;
							room.reconnect = Some(Reconnect::Manual);
						}
					},
					Self::RoomAuthorityAcquired {
						room_link,
						manager_link,
						..
					} => {
						room.link = Some(room_link.clone());
						room.manager = Some(manager_link.clone());
					}
					Self::RoomPublication { publication, .. } => room.publication_id = Some(publication.clone()),
					_ => unreachable!("admitted room fact"),
				}
			}
			Edit::NewDirect => {
				let Self::DirectAccepted {
					conversation,
					directory,
					peer,
					registration,
				} = self
				else {
					unreachable!("admitted direct fact");
				};
				next.conversations
					.try_push(Conversation::Direct(alloc::boxed::Box::new(Direct {
						kind: DirectKind::Direct,
						id: conversation.clone(),
						directory: directory.clone(),
						peer: peer.clone(),
						peer_registration_id: registration.clone(),
						closed: false,
						draft: Text("".into()),
					})))
					.map_err(|_| Error::Size)?;
			}
			Edit::ReopenDirect(index) => {
				let Conversation::Direct(direct) = &mut next.conversations.0[index] else {
					unreachable!("admitted direct reopening");
				};
				direct.closed = false;
			}
			Edit::CloseDirect(index) => {
				let Conversation::Direct(direct) = &mut next.conversations.0[index] else {
					unreachable!("admitted direct retirement");
				};
				direct.closed = true;
			}
		}
		validate::state(&mut next, routes)?;
		Ok(Some(Checkpoint(next)))
	}
	fn admit(&self, state: &State, routes: &impl CommandRoutes) -> Result<Option<Edit>, Error> {
		if let Self::DirectoryReached { directory, locator } = self {
			return Ok(state
				.directories
				.0
				.iter()
				.position(|d| d.id == *directory && d.locator == *locator && d.reached != Some(true))
				.map(Edit::Directory));
		}
		if let Self::DirectAccepted {
			conversation,
			directory,
			peer,
			registration,
		} = self
		{
			if !state
				.directories
				.0
				.iter()
				.any(|d| d.id == *directory && d.nick.0.utf16().next().is_some())
			{
				return Err(Error::NamedDirectory);
			}
			if state.conversations.0.iter().any(|c|
				matches!(c, Conversation::Direct(d) if !d.closed && d.directory == *directory && d.peer_registration_id == *registration)) { return Ok(None); }
			if let Some(index) = state.conversations.0.iter().position(|c| c.id() == conversation) {
				return match &state.conversations.0[index] {
					Conversation::Direct(direct)
						if direct.closed
							&& direct.directory == *directory
							&& direct.peer == *peer
							&& direct.peer_registration_id == *registration =>
					{
						Ok(Some(Edit::ReopenDirect(index)))
					}
					_ => Err(Error::Conflict),
				};
			}
			return Ok(Some(Edit::NewDirect));
		}
		if let Self::DirectRegistrationRetired {
			conversation: target,
			directory,
			peer,
			registration,
		} = self
		{
			return Ok(state
				.conversations
				.0
				.iter()
				.position(|conversation| {
					matches!(conversation, Conversation::Direct(direct)
					if !direct.closed
						&& direct.id == *target
						&& direct.directory == *directory
						&& direct.peer == *peer
						&& direct.peer_registration_id == *registration)
				})
				.map(Edit::CloseDirect));
		}
		let (_, id) = self.subject();
		let Some(index) = state.conversations.0.iter().position(|c| &c.id().0 == id) else {
			return Ok(None);
		};
		let Conversation::Room(room) = &state.conversations.0[index] else {
			return Ok(None);
		};
		if !self.room_context().is_some_and(|context| context.matches(room)) {
			return Ok(None);
		}
		let changed = match self {
			Self::RoomReconnect { .. } => room.reconnect == Some(Reconnect::Requested),
			Self::RoomAuthority { kind, token, .. } => {
				let bearer = match kind {
					Authority::Room => &room.link,
					Authority::Manager => &room.manager,
					Authority::Steward => &room.steward,
				};
				let Some(bearer) = bearer else {
					return Ok(None);
				};
				let generation = routes
					.authority_token(&bearer.0.utf8_lossy())
					.ok_or(Error::Generation)?;
				token.0.as_str() == Some(generation.as_str())
			}
			Self::RoomAuthorityAcquired {
				room_link,
				manager_link,
				..
			} => {
				if room.link.as_ref().is_some_and(|v| v != room_link)
					|| room.manager.as_ref().is_some_and(|v| v != manager_link)
				{
					return Err(Error::Conflict);
				}
				room.link.as_ref() != Some(room_link) || room.manager.as_ref() != Some(manager_link)
			}
			Self::RoomPublication {
				expected, publication, ..
			} => !room.held && room.publication_id == *expected && room.publication_id.as_ref() != Some(publication),
			_ => unreachable!("room fact classification"),
		};
		Ok(changed.then_some(Edit::Room(index)))
	}
}
enum Edit {
	Directory(usize),
	Room(usize),
	NewDirect,
	ReopenDirect(usize),
	CloseDirect(usize),
}
