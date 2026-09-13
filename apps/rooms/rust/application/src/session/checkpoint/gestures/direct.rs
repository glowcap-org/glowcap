//! A direct gesture captures an exact registration, never a display-store row.
use super::*;
use crate::{grants::Access, session::snapshot::Snapshot, text::DocumentText};
use alloc::string::ToString;
pub struct DirectGesture {
	guard: RoomGesture,
	id: Id,
	peer: Text<32, true>,
	registration: DocumentText,
	command: bool,
}
fn peer<'a>(snapshot: &'a Snapshot, directory: &Id, name: &DocumentText) -> Option<&'a crate::directory::Member> {
	let folded = name.lowercase();
	snapshot
		.directory_views
		.as_slice()
		.iter()
		.find(|view| &view.directory_id == directory)?
		.peers
		.as_slice()
		.iter()
		.find(|peer| peer.name.text().lowercase() == folded)
}
impl DirectGesture {
	pub fn select(snapshot: &Snapshot, directory: &str, who: &str, select: bool) -> Result<Self, String> {
		if !matches!(snapshot.access, Access::Admin | Access::Interact) {
			return Err("This session cannot start direct conversations".into());
		}
		let directory = snapshot.checkpoint.gesture_directory(directory)?;
		let who = DocumentText::from(who);
		if directory.nick.text().lowercase() == who.lowercase() {
			return Err("You can't start a direct message with yourself.".into());
		}
		let member = peer(snapshot, &directory.id, &who).ok_or_else(|| {
			alloc::format!(
				"{} is not registered for direct messages here.",
				who.as_str().unwrap_or("That member")
			)
		})?;
		let registration = crate::directory::registration::Id::parse(
			member.registration_id.as_str().ok_or("Invalid peer registration")?,
		)
		.map_err(|e| e.to_string())?;
		let existing = snapshot
			.checkpoint
			.0
			.conversations
			.0
			.iter()
			.find_map(|conversation| match conversation {
				Conversation::Direct(direct)
					if direct.directory == directory.id
						&& !direct.closed && direct.peer_registration_id.text() == &member.registration_id =>
				{
					Some(direct.as_ref())
				}
				_ => None,
			});
		let id = if let Some(existing) = existing {
			existing.id.clone()
		} else {
			super::super::direct_id(
				directory.id.text().as_str().ok_or("Invalid directory identity")?,
				&registration,
			)
			.ok_or("Direct conversation identity exceeds its bound")?
		};
		let direct = Direct {
			kind: DirectKind::Direct,
			id: id.clone(),
			directory: directory.id.clone(),
			peer: Id::new(member.name.text().clone()).ok_or("Invalid peer name")?,
			peer_registration_id: Field::new(member.registration_id.clone()).ok_or("Invalid peer registration")?,
			closed: false,
			draft: Field::new("".into()).expect("empty draft"),
		};
		let (name, arguments, command) = match (existing.is_some(), select) {
			(true, true) => (
				"select",
				alloc::vec![id.text().as_str().ok_or("Invalid conversation identity")?.into()],
				true,
			),
			(true, false) => ("select", Vec::new(), false),
			(false, true) => ("openDirect", alloc::vec![encode(&direct)?], true),
			(false, false) => ("startDirect", alloc::vec![encode(&direct)?], true),
		};
		Ok(Self {
			guard: RoomGesture {
				name,
				arguments,
				directory: directory.id.clone(),
				expected: Some(super::expected(directory)),
			},
			id,
			peer: member.name.clone(),
			registration: member.registration_id.clone(),
			command,
		})
	}
	pub fn command(&self) -> Option<(&'static str, &[String])> {
		self.command.then(|| (self.guard.name(), self.guard.arguments()))
	}
	pub fn id(&self) -> &str {
		self.id.text().as_str().expect("admitted direct identity")
	}
	pub fn check(&self, snapshot: &Snapshot) -> Result<(), String> {
		self.guard.check(&snapshot.checkpoint)?;
		if !matches!(snapshot.access, Access::Admin | Access::Interact) {
			return Err("This session no longer permits direct conversations".into());
		}
		if peer(snapshot, &self.guard.directory, self.peer.text())
			.is_some_and(|peer| peer.registration_id == self.registration)
		{
			Ok(())
		} else {
			Err("That peer's registration changed; choose them again from the current directory".into())
		}
	}
	pub fn conversation<'a>(&self, checkpoint: &'a Checkpoint) -> Result<impl Serialize + 'a, &'static str> {
		checkpoint
			.0
			.conversations
			.0
			.iter()
			.find_map(|conversation| match conversation {
				Conversation::Direct(direct)
					if direct.id == self.id
						&& direct.directory == self.guard.directory
						&& direct.peer_registration_id.text() == &self.registration
						&& !direct.closed =>
				{
					Some(direct.as_ref())
				}
				_ => None,
			})
			.ok_or("The direct conversation was retired before its result was observed")
	}
	pub fn retained_bytes(&self) -> usize {
		use crate::fields::footprint::HeapBytes;
		core::mem::size_of::<Self>()
			+ self.guard.retained_bytes()
			+ self.id.heap_bytes()
			+ self.peer.heap_bytes()
			+ self.registration.heap_bytes()
	}
}
