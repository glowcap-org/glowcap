//! The committed membership inputs observed by a room fact. Unrelated draft
//! and presentation edits do not invalidate an observation.
use super::super::{
	RoomIntent, RoomReconnect,
	fields::{Bearer, Field, Id, Text},
	model::{Reconnect, Room},
};

#[derive(Clone)]
pub struct RoomContext {
	directory: Id,
	name: Text<32, true>,
	held: bool,
	reconnect: Option<RoomReconnect>,
	link: Option<Bearer>,
	manager: Option<Bearer>,
	steward: Option<Bearer>,
	publication: Option<Field>,
}
impl RoomContext {
	pub fn capture(intent: RoomIntent<'_>) -> Self {
		Self {
			directory: intent.directory.clone(),
			name: intent.name.clone(),
			held: intent.held,
			reconnect: intent.reconnect,
			link: intent.link.cloned(),
			manager: intent.manager.cloned(),
			steward: intent.steward.cloned(),
			publication: intent.publication_id.cloned(),
		}
	}
	pub(super) fn heap_bytes(&self) -> usize {
		self.directory.text().heap_bytes()
			+ self.name.text().heap_bytes()
			+ [&self.link, &self.manager, &self.steward]
				.iter()
				.map(|field| field.as_ref().map_or(0, |value| value.text().heap_bytes()))
				.sum::<usize>()
			+ self.publication.as_ref().map_or(0, |value| value.text().heap_bytes())
	}
	pub(super) fn matches(&self, room: &Room) -> bool {
		self.directory == room.directory
			&& self.name == room.name
			&& self.held == room.held
			&& self.reconnect
				== room.reconnect.map(|value| match value {
					Reconnect::Manual => RoomReconnect::Manual,
					Reconnect::Requested => RoomReconnect::Requested,
				}) && self.link == room.link
			&& self.manager == room.manager
			&& self.steward == room.steward
			&& self.publication == room.publication_id
	}
}
