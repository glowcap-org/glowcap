//! Room gestures become command material from the authoritative checkpoint.
//! The directory identity captured here is checked again before every retry.
use super::{fields::*, model::*, Checkpoint};
use crate::{directory::creation::RecoveryKey, room::policy::RoomPolicy};
use alloc::{string::String, vec::Vec};
use serde::Serialize;
mod direct;
mod directory;
mod sharing;
pub use direct::DirectGesture;
pub use directory::Reach;
pub use sharing::ShareRoom;

pub struct RoomGesture {
	name: &'static str,
	arguments: Vec<String>,
	directory: Id,
	expected: Option<(Id, Field)>,
}
impl RoomGesture {
	pub fn retained_bytes(&self) -> usize {
		use crate::fields::footprint::HeapBytes;
		core::mem::size_of::<Self>()
			+ self.directory.heap_bytes()
			+ self.arguments.capacity() * core::mem::size_of::<String>()
			+ self.arguments.iter().map(String::capacity).sum::<usize>()
			+ self
				.expected
				.as_ref()
				.map_or(0, |(locator, nick)| locator.heap_bytes() + nick.heap_bytes())
	}
	pub fn name(&self) -> &'static str {
		self.name
	}
	pub fn arguments(&self) -> &[String] {
		&self.arguments
	}
	pub fn check(&self, checkpoint: &Checkpoint) -> Result<(), &'static str> {
		let actual = checkpoint
			.0
			.directories
			.0
			.iter()
			.find(|directory| directory.id == self.directory);
		let stable = match (actual, &self.expected) {
			(None, None) => true,
			(Some(actual), Some(expected)) => actual.locator == expected.0 && actual.nick == expected.1,
			_ => false,
		};
		if stable {
			Ok(())
		} else {
			Err("The room's directory or nickname changed; repeat the action from the current view")
		}
	}
}
#[derive(Serialize)]
struct Join<'a> {
	locator: &'a Id,
	nick: &'a Field,
	conversation: Room,
}
pub struct Destination<'a> {
	pub directory: &'a str,
	pub locator: &'a str,
	pub name: &'a str,
	pub nick: &'a str,
	pub link: Option<&'a str>,
	pub policy: RoomPolicy,
}
pub struct JoinPlan {
	pub readiness: Option<Reach>,
	pub preparation: Option<RoomGesture>,
	pub admission: RoomGesture,
}
fn encode(value: &impl Serialize) -> Result<String, &'static str> {
	serde_json::to_string(value).map_err(|_| "Could not encode the Rooms gesture")
}
fn room(directory: &Directory, name: &str, id: &str, held: bool) -> Result<Room, &'static str> {
	Ok(Room {
		kind: RoomKind::Room,
		id: Id::new(id.into()).ok_or("Invalid conversation identity")?,
		directory: directory.id.clone(),
		name: Text::new(name.into()).ok_or("A room name must be between 1 and 32 characters")?,
		held,
		reconnect: None,
		link: None,
		manager: None,
		steward: None,
		publication_id: None,
		standing: Nullable::Null,
		draft: Field::new("".into()).expect("empty draft"),
		bridge_intent: Presence::Missing,
	})
}
impl Checkpoint {
	fn gesture_directory(&self, id: &str) -> Result<&Directory, &'static str> {
		self.0
			.directories
			.0
			.iter()
			.find(|directory| directory.id.text().as_str() == Some(id))
			.ok_or("The room's directory is no longer in this session")
	}
	pub fn pick_room(&self, directory: &str, name: &str, id: &str) -> Result<RoomGesture, &'static str> {
		let directory = self.gesture_directory(directory)?;
		let folded = crate::text::DocumentText::from(name).lowercase();
		let existing = self
			.0
			.conversations
			.0
			.iter()
			.find_map(|conversation| match conversation {
				Conversation::Room(room)
					if room.directory == directory.id && !room.held && room.name.text().lowercase() == folded =>
				{
					Some(room)
				}
				_ => None,
			});
		if let Some(room) = existing {
			return Ok(RoomGesture {
				name: "select",
				arguments: alloc::vec![room.id.text().as_str().ok_or("Invalid conversation identity")?.into()],
				directory: directory.id.clone(),
				expected: Some((directory.locator.clone(), directory.nick.clone())),
			});
		}
		let intent = Join {
			locator: &directory.locator,
			nick: &directory.nick,
			conversation: room(directory, name, id, false)?,
		};
		Ok(RoomGesture {
			name: "joinRoom",
			arguments: alloc::vec![encode(&intent)?],
			directory: directory.id.clone(),
			expected: Some((directory.locator.clone(), directory.nick.clone())),
		})
	}
	pub fn take_room_link(
		&self,
		directory: &str,
		locator: &str,
		link: &str,
		name: &str,
		id: &str,
	) -> Result<RoomGesture, &'static str> {
		let prior = self.gesture_directory(directory).ok();
		let current = self
			.0
			.conversations
			.0
			.iter()
			.find(|c| self.active() == Some(c.id().text()));
		let source = prior
			.or_else(|| current.and_then(|c| self.gesture_directory(c.directory().text().as_str()?).ok()))
			.or_else(|| self.0.directories.0.iter().find(|d| d.home))
			.ok_or("Choose a nickname before joining a room link")?;
		let (directory, _) = self.prepare_directory(
			directory,
			locator,
			source.nick.text().as_str().ok_or("Invalid nickname")?,
			false,
		)?;
		let mut conversation = room(&directory, name, id, true)?;
		conversation.link = Some(Bearer::new(link.into()).ok_or("Invalid room link")?);
		let intent = Join {
			locator: &directory.locator,
			nick: &directory.nick,
			conversation,
		};
		Ok(RoomGesture {
			name: "takeRoomLink",
			arguments: alloc::vec![encode(&intent)?],
			directory: directory.id.clone(),
			expected: prior.map(|d| (d.locator.clone(), d.nick.clone())),
		})
	}
	pub fn create_managed_room(
		&self,
		directory: &str,
		name: &str,
		id: &str,
		key: &RecoveryKey,
		policy: RoomPolicy,
	) -> Result<RoomGesture, &'static str> {
		let directory = self.gesture_directory(directory)?;
		let room = room(directory, name, id, !policy.is_listed())?;
		let mut arguments = alloc::vec![encode(&room)?, key.as_str().into()];
		arguments.extend(policy.modes().into_iter().map(String::from));
		Ok(RoomGesture {
			name: "openManagedRoom",
			arguments,
			directory: directory.id.clone(),
			expected: Some((directory.locator.clone(), directory.nick.clone())),
		})
	}
	pub fn join_destination(
		&self,
		destination: Destination<'_>,
		id: &str,
		key: &RecoveryKey,
	) -> Result<JoinPlan, &'static str> {
		if crate::room::inbox::nick_refusal(destination.nick).is_some() {
			return Err("The directory nickname is invalid");
		}
		let prior = self.gesture_directory(destination.directory).ok();
		let managed = destination.link.is_none() && destination.policy != RoomPolicy::Open;
		let (mut directory, preparation) =
			self.prepare_directory(destination.directory, destination.locator, destination.nick, managed)?;

		if !managed {
			directory.locator = Id::new(destination.locator.into()).ok_or("Invalid directory locator")?;
			let mut conversation = room(&directory, destination.name, id, destination.link.is_some())?;
			conversation.link = destination
				.link
				.map(|link| Bearer::new(link.into()).ok_or("Invalid room link"))
				.transpose()?;
			let intent = Join {
				locator: &directory.locator,
				nick: &directory.nick,
				conversation,
			};
			return Ok(JoinPlan {
				readiness: None,
				preparation: None,
				admission: RoomGesture {
					name: "joinRoom",
					arguments: alloc::vec![encode(&intent)?],
					directory: directory.id.clone(),
					expected: prior.map(|prior| (prior.locator.clone(), prior.nick.clone())),
				},
			});
		}

		let conversation = room(&directory, destination.name, id, !destination.policy.is_listed())?;
		let mut arguments = alloc::vec![encode(&conversation)?, key.as_str().into()];
		arguments.extend(destination.policy.modes().into_iter().map(String::from));
		Ok(JoinPlan {
			readiness: Some(Reach::observe(directory.clone())),
			preparation,
			admission: RoomGesture {
				name: "openManagedRoom",
				arguments,
				expected: Some((directory.locator.clone(), directory.nick.clone())),
				directory: directory.id,
			},
		})
	}
}

pub fn private_name_available(
	snapshot: &crate::session::snapshot::Snapshot,
	directory: &str,
	name: &str,
) -> Result<(), String> {
	let folded = crate::text::DocumentText::from(name).lowercase();
	if snapshot
		.directory_views
		.as_slice()
		.iter()
		.filter(|view| view.directory_id.text().as_str() == Some(directory))
		.flat_map(|view| view.rooms.as_slice())
		.any(|room| room.name.text().lowercase() == folded)
	{
		return Err(alloc::format!(
			"#{name} is already live here. Turn off Private to open it, or choose another name for a new private room."
		));
	}
	Ok(())
}
