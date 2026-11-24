//! This member's own nickname in each room, which a line alone does not carry.
//! Names are compared as Rooms compares nicknames, which is this type's rule.
//! A room line names its sender, and a nickname belongs to a directory, so the
//! name this member answers to in a room comes from the workspace. A line
//! under that name is the bot's own and is never answered.
use rooms_application::{content::session::workspace::Conversation, room::inbox::same_nick};
use rooms_services::session::attached::Snapshot;
use std::collections::BTreeMap;

#[derive(Default)]
pub struct Names {
	/// This member's nickname in each room, by room id.
	own: BTreeMap<String, String>,
}

impl Names {
	pub fn of(snapshot: &Snapshot) -> Self {
		let intent = &snapshot.intent;
		let mut names = Self::default();
		for conversation in intent.conversations.as_slice() {
			let Conversation::Room(room) = conversation else {
				continue;
			};
			let directory = intent
				.directories
				.as_slice()
				.iter()
				.find(|row| row.id == room.directory);
			let nick = directory.and_then(|row| row.assigned_nick.as_ref().unwrap_or(&row.nick).text().as_str());
			if let (Some(id), Some(nick)) = (room.id.text().as_str(), nick) {
				names.own.insert(id.to_owned(), nick.to_owned());
			}
		}
		names
	}

	/// Whether `from` is this member's nickname in `room`, as Rooms compares
	/// nicknames.
	pub fn is_own(&self, room: &str, from: &str) -> bool {
		self.own.get(room).is_some_and(|nick| same_nick(nick, from))
	}
}
