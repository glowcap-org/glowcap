//! Opening a direct conversation from an attached view. The directory names
//! the peer's current registration, an open conversation that already
//! reaches that registration is reused, and otherwise one `startDirect`
//! introduces the peer and its route is kept the way a posted line is.
use super::{Error, Sent, View};
use rooms_application::{
	content::session::workspace::{Adoption, Id, StartDirect, open_direct},
	room::inbox::same_nick,
};
use rooms_glowcap::client::{Deadline, Tasks, workspace::EffectStatus};

/// What `View::open_direct` did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Opened {
	/// An open conversation already reached the peer, and nothing was sent.
	Reused(String),
	/// This call's `startDirect` committed and the conversation holds its
	/// route.
	Opened { conversation: String, sent: Sent },
	/// This call's `startDirect` did not commit. `Conflict` and `Unsent`
	/// committed nothing. `Pending` and `Unknown` may still commit: open again
	/// under the same operation and base.
	Unsettled(Sent),
}

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Open a direct conversation with the member registered as `peer` in
	/// `directory`, or reuse the open one, under the caller's `operation` at
	/// the session's current revision, or at `base` to open again after an
	/// uncertain outcome. A peer with no live registration, or this session's
	/// own nickname, is refused before anything is sent. Reuse is keyed on the
	/// registration the directory names now, so calling again after a kept
	/// open reuses it, and the same operation at the same base is answered
	/// from its first receipt, so it never introduces twice. A route that
	/// cannot be kept is `Unopened`, with its receipt given back, and opening
	/// again after that introduces again.
	pub async fn open_direct(
		&self,
		operation: &str,
		base: Option<u64>,
		directory: &str,
		peer: &str,
	) -> Result<Opened, Error> {
		let before = self.snapshot().await?;
		let own = before
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id.text().as_str() == Some(directory))
			.ok_or_else(|| Error::Input(format!("this session holds no directory {directory}")))?;
		let nick = own.assigned_nick.as_ref().unwrap_or(&own.nick).text();
		if nick.as_str().is_some_and(|nick| same_nick(nick, peer)) {
			return Err(Error::Input(format!("{peer} is this session's own nickname")));
		}
		let reader = self.settled(self.workspace.directory_reader(directory).await).await?;
		let registration = self.settled(reader.member_registration(peer).await).await?;
		let registration = registration.as_str();
		if let Some(row) = open_direct(&before.intent, directory, registration) {
			return Ok(Opened::Reused(text(&row.id)?));
		}
		let start = StartDirect {
			directory,
			peer,
			registration,
			opening: operation,
		};
		let arguments = start.arguments();
		let base = base.unwrap_or(before.revision);
		let command = self.prepared(operation, base, "startDirect", &arguments).await?;
		let status = self.submit(&command, base).await?;
		let sent = Sent {
			operation: operation.into(),
			base,
			status,
		};
		if status != EffectStatus::Committed {
			return Ok(Opened::Unsettled(sent));
		}
		self.kept(&command, base, Adoption::Direct(start), Ok(&before.intent))
			.await?;
		let now = self.snapshot().await?;
		let conversation = open_direct(&now.intent, directory, registration)
			.ok_or_else(|| Error::Input(format!("the conversation with {peer} closed as it opened")))
			.and_then(|row| text(&row.id))?;
		Ok(Opened::Opened { conversation, sent })
	}
}
fn text(id: &Id) -> Result<String, Error> {
	id.text()
		.as_str()
		.map(str::to_owned)
		.ok_or(Error::Malformed("a direct conversation id is not text"))
}
