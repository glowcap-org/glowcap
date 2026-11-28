//! Public-room intent retains the exact directory and publication for reopening.
use super::*;
use rooms_application::fields::{List, Text};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PublicRoomImport {
	pub id: workspace::Id,
	pub directory: workspace::Id,
	pub name: Text<32, true>,
	pub publication: Text<128, true>,
	pub source: custody::FieldKey<custody::SessionAccess>,
}
impl PublicRoomImport {
	pub fn into_room(self, access: custody::FieldKey<custody::DirectoryAccess>) -> workspace::Room {
		workspace::Room {
			kind: workspace::RoomKind::Room,
			id: self.id,
			directory: self.directory,
			name: self.name,
			source: Some(self.source),
			inbox: None,
			access: None,
			accepted: None,
			public_entry: Some(workspace::PublicEntry { access }),
			publication: Some(self.publication),
			seat: None,
			subject: None,
			files: None,
			lines: List::default(),
			moderator: None,
			control: None,
			reconnect: workspace::Reconnect::Requested,
			profile: Default::default(),
			audience: Default::default(),
			standing: None,
			draft: Text::default(),
		}
	}

	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>()
			+ self.id.text().heap_bytes()
			+ self.directory.text().heap_bytes()
			+ self.name.text().heap_bytes()
			+ self.publication.text().heap_bytes()
	}
}
impl<D: Deadline + Clone> Workspace<D> {
	/// A retained seat is ready only while its exact worker is active and its
	/// original participation grant still admits the readiness check.
	pub async fn room_membership_ready(
		&self,
		inbox: custody::FieldKey<custody::RoomInbox>,
		seat: custody::FieldKey<custody::RoomSeat>,
	) -> Result<bool, Error> {
		let keys =
			serde_json::to_string(&(inbox, seat)).map_err(|_| loam::refusal("invalid room readiness selection"))?;
		let args = [keys.into()];
		let offered = self.call("room-membership-reader", &args).await?;
		if matches!(offered, Argument::Void) {
			return Ok(false);
		}
		let reader = Self::capability(&offered)?;
		let reply = self
			.caller
			.call(
				&reader,
				"room-membership-ready",
				&args,
				"the room membership worker did not answer",
			)
			.await?;
		match reply {
			Argument::Boolean(ready) => Ok(ready),
			_ => Err(loam::refusal("invalid room readiness reply").into()),
		}
	}
	/// Join one exact publication through the held directory. The session constructs
	/// the new room and saves this invoking grant as its membership source.
	pub async fn join_listed_room(
		&self,
		selection: PublicRoomImport,
		access: custody::FieldKey<custody::DirectoryAccess>,
	) -> Result<String, Error> {
		let selection =
			serde_json::to_string(&(selection, access)).map_err(|_| loam::refusal("invalid room selection"))?;
		let reply = self
			.call("join-listed-room", &[selection.into(), self.reference.clone().into()])
			.await?;
		reply
			.as_str()
			.map(str::to_owned)
			.ok_or_else(|| loam::refusal("invalid joined conversation").into())
	}

	/// Retain one complete candidate and its actual invoking source. Acquisition
	/// installs them atomically. Membership belongs to the managed supervisor.
	/// The public directory row supplies held authority, while the exact listing
	/// publication supplies the generation. No accepted visit is persisted.
	pub async fn prepare_public_room(
		&self,
		expected: u64,
		selected: PublicRoomImport,
	) -> Result<Acquisition<D>, Error> {
		let mut snapshot = self.snapshot().await?;
		if snapshot.revision != expected {
			return Err(Error::WorkspaceConflict);
		}
		if snapshot
			.intent
			.conversations
			.as_slice()
			.iter()
			.any(|row| row.id() == &selected.id)
		{
			return Err(loam::refusal("public room selection is already installed").into());
		}
		let access = snapshot
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id == selected.directory)
			.ok_or_else(|| loam::refusal("public room directory is no longer held"))?
			.access;
		let source = selected.source;
		let room = selected.into_room(access);
		snapshot
			.intent
			.conversations
			.try_push(workspace::Conversation::Room(Box::new(room)))
			.map_err(|_| loam::refusal("workspace conversations are full"))?;
		Ok(self.prepare_acquisition(
			expected,
			vec![Import {
				coordinate: custody::Coordinate {
					role: custody::Role::SessionAccess,
					key: source.retag(),
				},
				reference: self.reference.clone(),
				uri: None,
			}],
			&[],
			&snapshot.intent,
		)?)
	}
}
