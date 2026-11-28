//! Opening a direct conversation from an attached view, in two steps. The
//! first reads the directory: it names the peer's current registration, and
//! an open conversation that already reaches that registration is the answer.
//! Otherwise it returns the introduction to send, and the second step sends
//! that exact introduction with one `startDirect` and keeps its route the way
//! a posted line is kept. A caller that keeps the introduction can send it
//! again under the same operation and base after an uncertain outcome, so the
//! directory is never read again for an open already sent.
use super::{
	Error, Failed, Sent, View, fault,
	fault::ViewFault,
	keep::{Effect, text},
};
use rooms_application::{
	content::session::workspace::{StartDirect, open_direct},
	room::inbox::same_nick,
};
use rooms_glowcap::client::{
	Deadline, Tasks,
	workspace::{EffectStatus, Release},
};
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
#[derive(Debug)]
pub enum Opened {
	/// This call's `startDirect` committed, and the conversation holds its
	/// route.
	Opened {
		conversation: String,
		opening: String,
		sent: Sent,
	},
	/// This call's `startDirect` committed while another open conversation
	/// already reached the peer. Its receipt was given back, and the peer is
	/// reached through that conversation.
	Reused {
		conversation: String,
		opening: String,
		sent: Sent,
	},
	/// This call's `startDirect` committed nothing: it was `Conflict` or
	/// `Unsent`.
	Unapplied(Sent),
	/// This call's `startDirect` is `Pending` or `Unknown` and may still
	/// commit. Introduce again under the same operation and base.
	Uncertain(Sent),
}

/// What [`View::introduce_first`] did: an [`Opened`], or the proof that the
/// operation was never sent.
#[derive(Debug)]
pub enum First {
	Sent(Opened),
	/// Nothing was submitted: the workspace could not be read, the command
	/// was refused locally, or the session proved it never dispatched it. The
	/// cause says why. This is the operation's first call, so the caller owes
	/// it no look and may open again under a new one. The same answer to a
	/// look again proves nothing about the first call, so
	/// [`View::introduce`] never gives it.
	Unsent(Box<Error>),
}

impl<D: Deadline + Tasks + Clone + 'static> View<D> {
	/// Find the member registered as `peer` in `directory`: the open
	/// conversation that reaches the registration the directory names now, or
	/// the introduction that would open one. A peer with no live registration,
	/// or this session's own nickname, is refused. Nothing is sent.
	pub async fn reach_direct(&self, directory: &str, peer: &str) -> Result<Reach, Error> {
		let before = self.snapshot().await?;
		self.reach_direct_from(&before, directory, peer).await
	}

	/// Resolve the registration against the exact workspace used to select
	/// and retain the destination of the following post.
	pub async fn reach_direct_from(
		&self,
		before: &super::Snapshot,
		directory: &str,
		peer: &str,
	) -> Result<Reach, Error> {
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
	/// Give back the receipt of an `introduce` the caller gives up on, so it
	/// holds none of the session's places. The peer may already have been
	/// introduced, and no conversation will reach them through it. A receipt
	/// the session no longer holds answers [`Release::Released`], one whose
	/// executor runs answers [`Release::Running`] and stays, and one whose
	/// route was adopted answers [`Release::Kept`] and stays adopted.
	pub async fn release_open(
		&self,
		operation: &str,
		base: u64,
		introduction: &Introduction,
	) -> Result<Release, Error> {
		let arguments = introduction.start(operation).arguments();
		let command = self.prepared(operation, base, "startDirect", &arguments).await?;
		match command.release().await {
			Ok(release) => Ok(release),
			Err(error) => Err(self.failure(error).await),
		}
	}
	/// Send `introduction` under `operation` for the first time, at the
	/// session's current revision, or at `base`, which the caller read. A call
	/// that submitted nothing is [`First::Unsent`].
	pub async fn introduce_first(
		&self,
		operation: &str,
		base: Option<u64>,
		introduction: &Introduction,
	) -> Result<First, Error> {
		self.send(operation, base, introduction).await
	}

	/// Send `introduction` under an `operation` that may already have been
	/// sent, at `base` or at the current revision, to look again after an
	/// uncertain outcome. The same operation at the same base with the same
	/// introduction is answered from its first receipt, so it never
	/// introduces twice. A route that cannot be kept is `Unopened`, with the
	/// receipt held for another attempt when keeping can still succeed. Once
	/// the receipt is released, another introduction starts a new open.
	/// An `Err` other than `Unopened` with `released` is an outcome the call
	/// could not prove unsent, so it is as uncertain as `Opened::Uncertain`,
	/// even when this call submitted nothing, because an earlier call under
	/// the operation may have committed.
	pub async fn introduce(
		&self,
		operation: &str,
		base: Option<u64>,
		introduction: &Introduction,
	) -> Result<Opened, Error> {
		match self.send(operation, base, introduction).await? {
			First::Sent(opened) => Ok(opened),
			First::Unsent(cause) => Err(*cause),
		}
	}

	async fn send(&self, operation: &str, base: Option<u64>, introduction: &Introduction) -> Result<First, Error> {
		let unsent = |cause| Ok(First::Unsent(Box::new(cause)));
		let before = match self.snapshot().await {
			Ok(before) if fault::conflicts(ViewFault::OpenConflict, operation) => {
				let sent = Sent {
					operation: operation.into(),
					base: base.unwrap_or(before.revision),
					status: EffectStatus::Conflict,
				};
				return Ok(First::Sent(Opened::Unapplied(sent)));
			}
			Ok(before) => {
				if let Some(cause) = fault::once(ViewFault::OpenLost) {
					return Err(Error::Uncertain {
						base: base.unwrap_or(before.revision),
						cause,
					});
				}
				if let Some(cause) = fault::once(ViewFault::IntroduceUnsent) {
					return unsent(Error::Unreachable(cause));
				}
				before
			}
			Err(cause) => return unsent(cause),
		};
		let start = introduction.start(operation);
		let arguments = start.arguments();
		let base = base.unwrap_or(before.revision);
		let command = match self.prepared(operation, base, "startDirect", &arguments).await {
			Ok(command) => command,
			Err(cause) => return unsent(cause),
		};
		let status = match self.submitted(&command, base).await {
			Ok(status) => status,
			Err(Failed::Unsent(cause)) => return unsent(cause),
			Err(Failed::Dispatched(cause)) => return Err(cause),
		};
		let sent = Sent {
			operation: operation.into(),
			base,
			status,
		};
		match status {
			// The open committed and its receipt is held, and the caller is told
			// it is still pending, as a lost answer would leave it.
			EffectStatus::Committed if fault::once(ViewFault::OpenUnconfirmed).is_some() => {
				let pending = Sent {
					status: EffectStatus::Pending,
					..sent
				};
				return Ok(First::Sent(Opened::Uncertain(pending)));
			}
			EffectStatus::Committed => {}
			EffectStatus::Conflict | EffectStatus::Unsent => return Ok(First::Sent(Opened::Unapplied(sent))),
			EffectStatus::Pending | EffectStatus::Unknown => return Ok(First::Sent(Opened::Uncertain(sent))),
		}
		let route = self
			.kept_route(Effect::Command(&command), base, &start, Ok(&before.intent))
			.await?;
		let conversation = route.conversation;
		Ok(First::Sent(if route.reused {
			Opened::Reused {
				conversation,
				sent,
				opening: route.opening,
			}
		} else {
			Opened::Opened {
				conversation,
				sent,
				opening: route.opening,
			}
		}))
	}
}
