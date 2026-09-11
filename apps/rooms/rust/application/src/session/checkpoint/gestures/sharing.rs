//! A room chosen for sharing remains the same membership across asynchronous
//! directory work and command retries. A matching label alone is insufficient.
use super::{Bearer, Checkpoint, Conversation, Field, Id, Room, Text};

pub struct ShareRoom {
	id: Id,
	directory: Id,
	name: Text<32, true>,
	held: bool,
	link: Option<Bearer>,
	publication: Option<Field>,
}
impl ShareRoom {
	pub fn select(checkpoint: &Checkpoint, current: &str, name: Option<&str>) -> Result<Self, &'static str> {
		let current = checkpoint
			.0
			.conversations
			.0
			.iter()
			.find_map(|entry| match entry {
				Conversation::Room(room) if room.id.text().as_str() == Some(current) => Some(room.as_ref()),
				_ => None,
			})
			.ok_or("That room is no longer in this session")?;
		let room = if let Some(name) = name.filter(|name| !name.is_empty()) {
			let mut matches = checkpoint.0.conversations.0.iter().filter_map(|entry| match entry {
				Conversation::Room(room)
					if room.directory == current.directory && room.name.text().as_str() == Some(name) =>
				{
					Some(room.as_ref())
				}
				_ => None,
			});
			let room = matches.next().ok_or("That room is not open here")?;
			if matches.next().is_some() {
				return Err("More than one held room has that name; open the intended room first");
			}
			room
		} else {
			current
		};
		Ok(Self {
			id: room.id.clone(),
			directory: room.directory.clone(),
			name: room.name.clone(),
			held: room.held,
			link: room.link.clone(),
			publication: room.publication_id.clone(),
		})
	}
	pub fn id(&self) -> &str {
		self.id.text().as_str().expect("admitted conversation identity")
	}
	pub fn directory(&self) -> &str {
		self.directory.text().as_str().expect("admitted directory identity")
	}
	pub fn check(&self, checkpoint: &Checkpoint) -> Result<(), &'static str> {
		let unchanged = checkpoint.0.conversations.0.iter().any(|entry| matches!(entry,
			Conversation::Room(room) if room.id == self.id && room.directory == self.directory && room.name == self.name && room.held == self.held && room.link == self.link && room.publication_id == self.publication));
		if unchanged {
			Ok(())
		} else {
			Err("The room changed while sharing was pending; repeat the action from its current view")
		}
	}
	pub fn link<'a>(&self, checkpoint: &'a Checkpoint) -> Result<RoomLink<'a>, &'static str> {
		let room: &Room = checkpoint
			.0
			.conversations
			.0
			.iter()
			.find_map(|entry| match entry {
				Conversation::Room(room)
					if room.id == self.id
						&& room.directory == self.directory
						&& room.name == self.name
						&& room.held == self.held =>
				{
					Some(room.as_ref())
				}
				_ => None,
			})
			.ok_or("The room was retired before its link arrived")?;
		Ok(RoomLink {
			name: room.name.text(),
			held: room.held,
			link: room
				.link
				.as_ref()
				.ok_or("The room did not provide an entry link")?
				.text(),
		})
	}
	pub fn retained_bytes(&self) -> usize {
		use crate::fields::footprint::HeapBytes;
		core::mem::size_of::<Self>()
			+ self.id.heap_bytes()
			+ self.directory.heap_bytes()
			+ self.name.heap_bytes()
			+ self.link.as_ref().map_or(0, HeapBytes::heap_bytes)
			+ self.publication.as_ref().map_or(0, HeapBytes::heap_bytes)
	}
}
#[derive(serde::Serialize)]
pub struct RoomLink<'a> {
	pub name: &'a crate::text::DocumentText,
	pub held: bool,
	pub link: &'a crate::text::DocumentText,
}
