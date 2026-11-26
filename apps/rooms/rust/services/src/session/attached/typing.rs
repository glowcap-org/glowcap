//! The typing sender an attached view can reuse for the same seat or route.
use super::{Deadline, Error, Tasks, View};
use rooms_application::content::session::{custody, workspace};
use rooms_glowcap::client::workspace::Typing;

/// A typing sender and the conversation seat or route it was opened for.
pub(super) struct KeptTyping<D> {
	conversation: String,
	target: custody::Coordinate,
	sender: Typing<D>,
}

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Show the member as typing in `conversation`, or stop, through the seat
	/// of a room or the route of an open direct message the workspace holds
	/// now. Readers clear a notice nobody renews within
	/// `rooms_application::room::membership::TYPING_CLEAR_MS`, so a caller
	/// that keeps typing says so again every `TYPING_RENEW_MS`. The view
	/// keeps the sender it opened, so the next signal in the same
	/// conversation costs one snapshot read and one call to the session. A
	/// signal for another conversation, a seat or route that changed, a lost
	/// connection, or an access no longer active lets the kept sender go, and
	/// the next signal opens its own. A conversation with no seat or open
	/// route is refused as input.
	pub async fn typing(&self, conversation: &str, on: bool) -> Result<(), Error> {
		let kept = self.typing.take();
		let now = self.snapshot().await?;
		let target = now
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(conversation))
			.and_then(|row| match row {
				workspace::Conversation::Room(row) => row
					.seat
					.map(|seat| custody::Coordinate::new(custody::Role::RoomSeat, seat)),
				workspace::Conversation::Direct(row) => row
					.installed_access()
					.map(|route| custody::Coordinate::new(custody::Role::DirectAccess, route)),
			})
			.ok_or_else(|| Error::Input(format!("{conversation} holds no seat or open route to show typing in")))?;
		let kept = match kept.filter(|kept| kept.conversation == conversation && kept.target == target) {
			Some(kept) => kept,
			None => KeptTyping {
				conversation: conversation.to_owned(),
				target,
				sender: match self.workspace.typing_sender(conversation, target).await {
					Ok(sender) => sender,
					Err(error) => return Err(self.failure(error).await),
				},
			},
		};
		let shown = match kept.sender.set(on).await {
			Ok(()) => Ok(()),
			Err(error) => Err(self.failure(error).await),
		};
		// A signal the session or the directory refused while this access
		// stays active, such as one sent too soon after the last, says
		// nothing against the sender. Any other failure lets it go.
		if matches!(shown, Ok(()) | Err(Error::Peer(_))) {
			self.typing.replace(Some(kept));
		}
		shown
	}
}
