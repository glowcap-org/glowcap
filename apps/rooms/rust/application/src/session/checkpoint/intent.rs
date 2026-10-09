//! Read-only intent projections for runtime realization. These borrow the
//! committed graph; adapters do not serialize and reparse checkpoint documents.
use super::{
	Checkpoint,
	fields::{Bearer, Field, Id, Text},
	model::Reconnect,
};
use crate::bridge::Answers;

#[derive(Clone, Copy)]
pub struct DirectoryIntent<'a> {
	pub home: bool,
	pub id: &'a Id,
	pub locator: &'a Id,
	pub nick: &'a Field,
	pub nick_allocation: crate::directory::registration::NicknameAllocation,
}
#[derive(Clone, Copy)]
pub struct DirectIntent<'a> {
	pub id: &'a Id,
	pub directory: &'a Id,
	pub peer: &'a Id,
	pub registration: &'a Field,
	pub closed: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RoomReconnect {
	Manual,
	Requested,
}
#[derive(Clone, Copy)]
pub struct BridgeIntent<'a> {
	pub scope: &'a crate::text::DocumentText,
	pub action: &'a crate::text::DocumentText,
	pub answers: &'a Answers,
	pub secrets_given: bool,
	pub credential_revision: Option<&'a crate::text::DocumentText>,
}
#[derive(Clone, Copy)]
pub struct RoomIntent<'a> {
	pub id: &'a Id,
	pub directory: &'a Id,
	pub name: &'a Text<32, true>,
	pub held: bool,
	pub reconnect: Option<RoomReconnect>,
	pub link: Option<&'a Bearer>,
	pub manager: Option<&'a Bearer>,
	pub steward: Option<&'a Bearer>,
	pub publication_id: Option<&'a Field>,
	pub bridge: Option<BridgeIntent<'a>>,
}
#[derive(Clone, Copy)]
pub struct OperationCredential<'a> {
	pub capability: &'static str,
	pub scope: &'a str,
	pub swiss: &'a str,
}
#[derive(Clone, Copy)]
pub struct PeeringIntent<'a> {
	pub id: &'a str,
	pub destination: &'a str,
	pub source: &'a str,
	pub name: &'a str,
}
impl Checkpoint {
	/// Effective standing for one room, including explicit empty overrides.
	pub fn room_standing(&self, id: &str) -> Option<&crate::text::DocumentText> {
		self.0.conversations.0.iter().find_map(|conversation| {
			let super::model::Conversation::Room(room) = conversation else {
				return None;
			};
			if room.id.text().as_str() != Some(id) {
				return None;
			}
			let directory = self
				.0
				.directories
				.0
				.iter()
				.find(|directory| directory.id == room.directory)?;
			Some(
				room.standing
					.as_ref()
					.or(directory.standing.as_ref())
					.unwrap_or(&self.0.standing)
					.text(),
			)
		})
	}
	pub fn active(&self) -> Option<&crate::text::DocumentText> {
		self.0.active.as_ref().map(|id| id.text())
	}
	pub fn keeps_history(&self) -> bool {
		self.0.keep_history
	}
	/// Selected archive capability is part of every history read's identity:
	/// changing it changes the authoritative accounts even when conversations do not.
	pub fn archive_peer(&self) -> Option<&crate::text::DocumentText> {
		self.0.capabilities.archive_peer.as_ref().map(|peer| peer.text())
	}
	pub fn directs(&self) -> impl Iterator<Item = DirectIntent<'_>> {
		self.0.conversations.0.iter().filter_map(|conversation| {
			let super::model::Conversation::Direct(direct) = conversation else {
				return None;
			};
			Some(DirectIntent {
				id: &direct.id,
				directory: &direct.directory,
				peer: &direct.peer,
				registration: &direct.peer_registration_id,
				closed: direct.closed,
			})
		})
	}
	pub fn rooms(&self) -> impl Iterator<Item = RoomIntent<'_>> {
		self.0.conversations.0.iter().filter_map(|conversation| {
			let super::model::Conversation::Room(room) = conversation else {
				return None;
			};
			Some(RoomIntent {
				id: &room.id,
				directory: &room.directory,
				name: &room.name,
				held: room.held,
				reconnect: room.reconnect.map(|reconnect| match reconnect {
					Reconnect::Manual => RoomReconnect::Manual,
					Reconnect::Requested => RoomReconnect::Requested,
				}),
				link: room.link.as_ref(),
				manager: room.manager.as_ref(),
				steward: room.steward.as_ref(),
				publication_id: room.publication_id.as_ref(),
				bridge: match &room.bridge_intent {
					super::fields::Presence::Value(bridge) => Some(BridgeIntent {
						scope: bridge.scope.text(),
						action: bridge.action.text(),
						answers: &bridge.answers,
						secrets_given: bridge.secrets_given,
						credential_revision: bridge.credential_revision.as_ref().map(|revision| revision.text()),
					}),
					_ => None,
				},
			})
		})
	}
	pub fn operations(&self) -> impl Iterator<Item = OperationCredential<'_>> {
		self.0.capabilities.operations.0.iter().filter_map(|credential| {
			Some(OperationCredential {
				capability: credential.capability.wire(),
				scope: credential.scope.text().as_str()?,
				swiss: credential.swiss.text().as_str()?,
			})
		})
	}
	pub fn peering(&self) -> impl Iterator<Item = PeeringIntent<'_>> {
		self.0.peering.0.iter().filter_map(|peering| {
			Some(PeeringIntent {
				id: peering.id.text().as_str()?,
				destination: peering.destination.text().as_str()?,
				source: peering.source.text().as_str()?,
				name: peering.name.text().as_str()?,
			})
		})
	}
	pub fn directories(&self) -> impl ExactSizeIterator<Item = DirectoryIntent<'_>> {
		self.0.directories.0.iter().map(|directory| DirectoryIntent {
			home: directory.home,
			id: &directory.id,
			locator: &directory.locator,
			nick: &directory.nick,
			nick_allocation: directory.nick_allocation,
		})
	}
}
