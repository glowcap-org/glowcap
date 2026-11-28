//! Select a listing in the requesting conversation's existing directory.
//! A repeated request adopts the same conversation even after a lost reply.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::PublicRoomImport;

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Read the current room through its exact seated membership. A direct
	/// conversation has no room seat, even when its peer shares a room with us.
	pub async fn room_members(
		&self,
		conversation: &str,
	) -> Result<Vec<rooms_application::room::profile::Entry<String>>, Error> {
		self.settled(self.workspace.room_members(conversation).await)
			.await?
			.ok_or_else(|| Error::Input("members requires a turn in a room with a live seat".into()))
	}

	pub async fn join_listed(&self, conversation: &str, name: &str) -> Result<String, Error> {
		let snapshot = self.snapshot().await?;
		let directory_id = snapshot
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(conversation))
			.ok_or_else(|| Error::Input("this turn's conversation no longer exists".into()))?
			.directory();
		let directory = snapshot
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| &row.id == directory_id)
			.ok_or_else(|| Error::Input("this turn's directory is no longer held".into()))?;
		let reader = self
			.settled(self.workspace.directory_reader(&keep::text(directory_id)?).await)
			.await?;
		let listings = self.settled(reader.named_rooms(name).await).await?;
		let [listing] = listings.as_slice() else {
			return Err(Error::Input(
				if listings.is_empty() {
					"no listed room has that name in this conversation's directory"
				} else {
					"several publications have that name in this conversation's directory"
				}
				.into(),
			));
		};
		if listing.offers.as_ref().is_none() {
			return Err(Error::Input(
				"this listing offers no public membership; a room invitation is required".into(),
			));
		}
		let same_listing = |row: &workspace::Room| {
			row.directory == directory.id
				&& row.publication.as_ref() == Some(&listing.id)
				&& row
					.public_entry
					.as_ref()
					.is_some_and(|entry| entry.access == directory.access)
		};
		if snapshot.intent.conversations.as_slice().iter().any(|row|matches!(row,workspace::Conversation::Room(room) if room.directory==directory.id && room.name==listing.name && !same_listing(room))) {
			return Err(Error::Input("a same-name room is already held through another entrance; the selected publication cannot be confirmed".into()));
		}
		let source = keep::fresh()?;
		let id = workspace::Id::new(
			format!("listed:{}:{}", source.slot(), source.generation())
				.as_str()
				.into(),
		)
		.ok_or(Error::Malformed("invalid public conversation identity"))?;
		let room = PublicRoomImport {
			id,
			directory: directory.id.clone(),
			name: listing.name.clone(),
			publication: listing.id.clone(),
			source,
		};
		let id = self
			.settled(self.workspace.join_listed_room(room, directory.access).await)
			.await?;
		let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(25);
		let mut pause = std::time::Duration::from_millis(100);
		loop {
			let snapshot = self.snapshot().await?;
			let room = snapshot
				.intent
				.room(&id)
				.ok_or_else(|| Error::Input("the joined room was removed".into()))?;
			if !same_listing(room) {
				return Err(Error::Input(
					"the joined conversation no longer holds the requested publication".into(),
				));
			}
			if let (Some(inbox), Some(seat)) = (room.inbox, room.seat)
				&& self
					.settled(self.workspace.room_membership_ready(inbox, seat).await)
					.await?
			{
				return Ok(id);
			}
			if !room.requests_membership() {
				return Err(Error::Input("the session stopped joining this room".into()));
			}
			if tokio::time::Instant::now() >= deadline {
				return Err(Error::Input("the session has requested membership but the room has not confirmed a seat; retrying the same listing reuses the request".into()));
			}
			tokio::time::sleep(pause).await;
			pause = (pause * 2).min(std::time::Duration::from_secs(1));
		}
	}
}
