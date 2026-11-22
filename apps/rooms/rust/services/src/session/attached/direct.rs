//! Opening a direct conversation from an attached view, in two steps. The
//! first reads the directory: it names the peer's current registration, and
//! an open conversation that already reaches that registration is the answer.
//! Otherwise it returns the introduction to send, and the second step sends
//! that exact introduction with one `startDirect` and keeps its route the way
//! a posted line is kept. A caller that keeps the introduction can send it
//! again under the same operation and base after an uncertain outcome, so the
//! directory is never read again for an open already sent.
use super::{Error, Sent, View, keep::text};
use rooms_application::{
	content::session::workspace::{StartDirect, open_direct},
	room::inbox::same_nick,
};
use rooms_glowcap::client::{Deadline, Tasks, workspace::EffectStatus};
use serde::{Deserialize, Serialize};

/// Where `View::reach_direct` found the peer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reach {
	/// An open conversation already reaches the peer.
	Open(String),
	/// No open conversation reaches the peer, and this introduction would.
	Introduce(Introduction),
}

/// The peer one `startDirect` introduces: the directory row, the nickname,
/// and the registration the directory named for it when it was read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Introduction {
	pub directory: String,
	pub peer: String,
	pub registration: String,
}
impl Introduction {
	/// The command that sends this introduction under `operation`, which is
	/// also its opening.
	fn start<'a>(&'a self, operation: &'a str) -> StartDirect<'a> {
		StartDirect {
			directory: &self.directory,
			peer: &self.peer,
			registration: &self.registration,
			opening: operation,
		}
	}
}

/// What `View::introduce` did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Opened {
	/// This call's `startDirect` committed, and the conversation holds its
	/// route.
	Opened { conversation: String, sent: Sent },
	/// This call's `startDirect` committed while another open conversation
	/// already reached the peer. Its receipt was given back, and the peer is
	/// reached through that conversation.
	Reused { conversation: String, sent: Sent },
	/// This call's `startDirect` committed nothing: it was `Conflict` or
	/// `Unsent`.
	Unapplied(Sent),
	/// This call's `startDirect` is `Pending` or `Unknown` and may still
	/// commit. Introduce again under the same operation and base.
	Uncertain(Sent),
}

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Find the member registered as `peer` in `directory`: the open
	/// conversation that reaches the registration the directory names now, or
	/// the introduction that would open one. A peer with no live registration,
	/// or this session's own nickname, is refused. Nothing is sent.
	pub async fn reach_direct(&self, directory: &str, peer: &str) -> Result<Reach, Error> {
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
		if let Some(row) = open_direct(&before.intent, directory, registration.as_str()) {
			return Ok(Reach::Open(text(&row.id)?));
		}
		Ok(Reach::Introduce(Introduction {
			directory: directory.into(),
			peer: peer.into(),
			registration: registration.as_str().into(),
		}))
	}
	/// Send `introduction` under the caller's `operation` at the session's
	/// current revision, or at `base` to look again after an uncertain
	/// outcome. The same operation at the same base with the same introduction
	/// is answered from its first receipt, so it never introduces twice. A
	/// route that cannot be kept is `Unopened`, with its receipt given back,
	/// and introducing again after that introduces again.
	pub async fn introduce(
		&self,
		operation: &str,
		base: Option<u64>,
		introduction: &Introduction,
	) -> Result<Opened, Error> {
		let before = self.snapshot().await?;
		let start = introduction.start(operation);
		let arguments = start.arguments();
		let base = base.unwrap_or(before.revision);
		let command = self.prepared(operation, base, "startDirect", &arguments).await?;
		let status = self.submit(&command, base).await?;
		let sent = Sent {
			operation: operation.into(),
			base,
			status,
		};
		match status {
			EffectStatus::Committed => {}
			EffectStatus::Conflict | EffectStatus::Unsent => return Ok(Opened::Unapplied(sent)),
			EffectStatus::Pending | EffectStatus::Unknown => return Ok(Opened::Uncertain(sent)),
		}
		let route = self.kept_route(&command, base, &start, Ok(&before.intent)).await?;
		let conversation = route.conversation;
		Ok(if route.reused {
			Opened::Reused { conversation, sent }
		} else {
			Opened::Opened { conversation, sent }
		})
	}
}
