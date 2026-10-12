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
	pub fn select(snapshot: &Snapshot, directory: &str, who: &str, select: bool) -> Result<Self, Invalid> {
		if !matches!(snapshot.access, Access::Admin | Access::Interact) {
			return Err(Invalid::NoAccess);
		}
		let directory = snapshot
			.checkpoint
			.gesture_directory(directory)
			.map_err(Invalid::Gesture)?;
		let who = DocumentText::from(who);
		if directory.nick.text().lowercase() == who.lowercase() {
			return Err(Invalid::Yourself);
		}
		let member = peer(snapshot, &directory.id, &who).ok_or_else(|| Invalid::NotRegistered {
			who: who.as_str().unwrap_or("That member").into(),
		})?;
		let registration = crate::directory::registration::Id::parse(
			member.registration_id.as_str().ok_or(Invalid::PeerRegistration)?,
		)
		.map_err(Invalid::RegistrationId)?;
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
				directory.id.text().as_str().ok_or(Invalid::DirectoryIdentity)?,
				&registration,
			)
			.ok_or(Invalid::ConversationBound)?
		};
		let direct = Direct {
			kind: DirectKind::Direct,
			id: id.clone(),
			directory: directory.id.clone(),
			peer: Id::new(member.name.text().clone()).ok_or(Invalid::PeerName)?,
			peer_registration_id: Field::new(member.registration_id.clone()).ok_or(Invalid::PeerRegistration)?,
			closed: false,
			draft: Field::default(),
		};
		let (name, arguments, command) = match (existing.is_some(), select) {
			(true, true) => (
				"select",
				alloc::vec![id.text().as_str().ok_or(Invalid::ConversationIdentity)?.into()],
				true,
			),
			(true, false) => ("select", Vec::new(), false),
			(false, true) => (
				"openDirect",
				alloc::vec![encode(&direct).map_err(Invalid::Gesture)?],
				true,
			),
			(false, false) => (
				"startDirect",
				alloc::vec![encode(&direct).map_err(Invalid::Gesture)?],
				true,
			),
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
		#[expect(
			clippy::expect_used,
			reason = "`new` read `id` as scalar text when it admitted this gesture"
		)]
		self.id.text().as_str().expect("admitted direct identity")
	}
	pub fn check(&self, snapshot: &Snapshot) -> Result<(), Invalid> {
		self.guard.check(&snapshot.checkpoint).map_err(Invalid::Gesture)?;
		if !matches!(snapshot.access, Access::Admin | Access::Interact) {
			return Err(Invalid::AccessLost);
		}
		if peer(snapshot, &self.guard.directory, self.peer.text())
			.is_some_and(|peer| peer.registration_id == self.registration)
		{
			Ok(())
		} else {
			Err(Invalid::RegistrationChanged)
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

/// Why a direct gesture is refused. `Display` is the exact line the member
/// reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// A line the checkpoint or its encoder refused, with its own text.
	Gesture(&'static str),
	/// The session may not start direct conversations.
	NoAccess,
	/// The member named themselves.
	Yourself,
	/// The named member has no registration in this directory.
	NotRegistered { who: String },
	/// The peer's registration id did not parse.
	RegistrationId(crate::directory::registration::Error),
	/// The peer's registration is not scalar text.
	PeerRegistration,
	/// The directory identity is not scalar text.
	DirectoryIdentity,
	/// The direct conversation identity is over its bound.
	ConversationBound,
	/// The peer's name is not a valid identity.
	PeerName,
	/// The conversation identity is not scalar text.
	ConversationIdentity,
	/// The session lost permission for direct conversations.
	AccessLost,
	/// The peer's registration changed since it was chosen.
	RegistrationChanged,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Gesture(line) => f.write_str(line),
			Self::NoAccess => f.write_str("This session cannot start direct conversations"),
			Self::Yourself => f.write_str("You can't start a direct message with yourself."),
			Self::NotRegistered { who } => write!(f, "{who} is not registered for direct messages here."),
			Self::RegistrationId(source) => write!(f, "{source}"),
			Self::PeerRegistration => f.write_str("Invalid peer registration"),
			Self::DirectoryIdentity => f.write_str("Invalid directory identity"),
			Self::ConversationBound => f.write_str("Direct conversation identity exceeds its bound"),
			Self::PeerName => f.write_str("Invalid peer name"),
			Self::ConversationIdentity => f.write_str("Invalid conversation identity"),
			Self::AccessLost => f.write_str("This session no longer permits direct conversations"),
			Self::RegistrationChanged => {
				f.write_str("That peer's registration changed; choose them again from the current directory")
			}
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(Invalid::Gesture("gesture line"), "gesture line"),
			(Invalid::NoAccess, "This session cannot start direct conversations"),
			(Invalid::Yourself, "You can't start a direct message with yourself."),
			(
				Invalid::NotRegistered { who: "Ann".into() },
				"Ann is not registered for direct messages here.",
			),
			(
				Invalid::RegistrationId(crate::directory::registration::Error::Id),
				&crate::directory::registration::Error::Id.to_string(),
			),
			(Invalid::PeerRegistration, "Invalid peer registration"),
			(Invalid::DirectoryIdentity, "Invalid directory identity"),
			(
				Invalid::ConversationBound,
				"Direct conversation identity exceeds its bound",
			),
			(Invalid::PeerName, "Invalid peer name"),
			(Invalid::ConversationIdentity, "Invalid conversation identity"),
			(
				Invalid::AccessLost,
				"This session no longer permits direct conversations",
			),
			(
				Invalid::RegistrationChanged,
				"That peer's registration changed; choose them again from the current directory",
			),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}
}
