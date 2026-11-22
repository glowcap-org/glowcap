//! The CapTP implementation of [`Rooms`]: an attached view over a session
//! capability the operator was granted. The bot is its own Host with its own
//! identity, so the session can be on another machine and the access can be
//! paused or revoked without touching the session's owner.
//!
//! The mapping is one view call to one method, named in `map`. The only
//! state kept here is the connection. A call that finds the connection gone
//! drops it, and the next call dials again, so reattaching is driven by the
//! engine's own backoff. The one wait inside a call is a read's bounded wait
//! for a private sender's name, in `names`.
mod dial;
mod identity;
mod map;
mod names;

use super::{
	Attachment, Base, Batch, ConversationId, Cursor, Echo, FETCH_DEADLINE, Outcome, Outgoing, Rooms, RoomsError,
	RoomsErrorKind, Settled,
};
use crate::bot::{
	error::Error,
	link::Link,
	store::{Log, Store},
};
pub use dial::{Dial, Failure, Live};
use names::Names;
use rooms_services::session::attached;
use std::{cell::RefCell, collections::BTreeSet, path::Path, rc::Rc};
use tokio::{sync::Mutex, time::timeout};

/// The most reads one echo check makes: enough to pass every event a
/// session retains, a page of [`attached::MAX_BATCH`] at a time.
const MAX_ECHO_READS: usize = attached::MAX_ACTIVITY_EVENTS / attached::MAX_BATCH + 1;

pub struct Attached {
	dial: Dial,
	log: Log,
	connection: RefCell<Option<Rc<Live>>>,
	/// Held while dialing, so two calls that find no connection dial once.
	dialing: Mutex<()>,
	/// The direct conversations whose sender a read waited for in vain.
	waited: RefCell<BTreeSet<String>>,
}

impl Attached {
	/// Prepare to attach with the bot's own identity. Nothing is dialed yet.
	pub fn open(store: &Store, link: Link) -> Result<Self, Error> {
		let seed = identity::seed(store)?;
		Ok(Self {
			dial: Dial::new(link, Some(seed))?,
			log: store.logger(),
			connection: RefCell::new(None),
			dialing: Mutex::new(()),
			waited: RefCell::default(),
		})
	}

	/// Close the connection, if there is one.
	pub async fn close(&self) {
		let held = self.connection.borrow_mut().take();
		if let Some(live) = held
			&& let Err(error) = live.close().await
		{
			self.log.line(&format!("closing the session connection: {error}"));
		}
	}

	async fn live(&self) -> Result<Rc<Live>, RoomsError> {
		if let Some(live) = self.connection.borrow().clone() {
			return Ok(live);
		}
		let _dialing = self.dialing.lock().await;
		if let Some(live) = self.connection.borrow().clone() {
			return Ok(live);
		}
		let live = Rc::new(self.dial.attach().await.map_err(map::dial_failure)?);
		self.log.line("attached to the session");
		*self.connection.borrow_mut() = Some(live.clone());
		Ok(live)
	}

	/// Name a failed call, and drop the connection when the failure says it is
	/// gone so the next call dials again.
	async fn failed(&self, live: &Rc<Live>, cause: attached::Error, sending: bool) -> RoomsError {
		if map::connection_lost(&cause) {
			let current = {
				let mut held = self.connection.borrow_mut();
				if held.as_ref().is_some_and(|held| Rc::ptr_eq(held, live)) {
					held.take()
				} else {
					None
				}
			};
			if let Some(lost) = current {
				self.log.line(&format!("lost the session: {cause}"));
				if let Err(error) = lost.close().await {
					self.log.line(&format!("closing the lost connection: {error}"));
				}
			}
		}
		map::failure(cause, sending)
	}
}

impl Rooms for Attached {
	async fn events(&self, after: &Cursor, wait: bool) -> Result<Batch, RoomsError> {
		let live = self.live().await?;
		let raw = match live.view.events(after.as_str(), wait).await {
			Ok(raw) => raw,
			// A cursor does not outlive its session's run. Follow what the
			// restarted session reports now. Whatever it held between the last
			// read and the restart is gone, so the read is reported as a gap.
			Err(attached::Error::Stale) => {
				self.log
					.line("the session restarted. Reading its new activity from the start of this run");
				match live.view.events("", false).await {
					Ok(mut raw) => {
						raw.gap = true;
						raw
					}
					Err(cause) => return Err(self.failed(&live, cause, false).await),
				}
			}
			Err(cause) => return Err(self.failed(&live, cause, false).await),
		};
		let has_lines = raw
			.events
			.iter()
			.any(|event| matches!(event.conversation.kind, attached::Kind::Room | attached::Kind::Direct));
		let names = if has_lines {
			match live.view.snapshot().await {
				Ok(snapshot) => Names::of(&snapshot),
				Err(cause) => return Err(self.failed(&live, cause, false).await),
			}
		} else {
			Names::default()
		};
		let mut batch = map::batch(raw, &names)?;
		let renamed = names::name_unnamed(&mut batch, &self.waited, async || {
			live.view.snapshot().await.map(|snapshot| Names::of(&snapshot))
		})
		.await;
		match renamed {
			Ok(()) => Ok(batch),
			Err(cause) => Err(self.failed(&live, cause, false).await),
		}
	}

	async fn base(&self) -> Result<Base, RoomsError> {
		let live = self.live().await?;
		match live.view.revision().await {
			Ok(revision) => Ok(Base(revision)),
			Err(cause) => Err(self.failed(&live, cause, false).await),
		}
	}

	async fn send(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		let live = self.live().await?;
		match live
			.view
			.say_at(line.operation, base.0, line.conversation.as_str(), line.text)
			.await
		{
			Ok(status) => Ok(map::outcome(status)),
			Err(cause) => Err(self.failed(&live, cause, true).await),
		}
	}

	async fn observe(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		let live = self.live().await?;
		let arguments = [line.conversation.as_str().to_owned(), line.text.to_owned()];
		match live.view.observe(line.operation, base.0, "say", &arguments).await {
			Ok(status) => Ok(map::outcome(status)),
			Err(cause) if map::connection_lost(&cause) => Err(self.failed(&live, cause, true).await),
			Err(cause) => map::observed(cause),
		}
	}

	async fn keep(&self, line: &Outgoing<'_>, base: Base) -> Result<(), RoomsError> {
		let live = self.live().await?;
		match live
			.view
			.keep_line(line.operation, base.0, line.conversation.as_str(), line.text)
			.await
		{
			Ok(()) => Ok(()),
			// Each try met a workspace that moved under it and adopted nothing,
			// so keeping is tried again after a wait.
			Err(attached::Error::Peer(attached::ClientError::WorkspaceConflict)) => Err(RoomsError::new(
				RoomsErrorKind::Unreachable,
				"the workspace kept changing while the line was being kept",
			)),
			Err(cause) => Err(self.failed(&live, cause, true).await),
		}
	}

	async fn release(&self, line: &Outgoing<'_>, base: Base) -> Result<(), RoomsError> {
		let live = self.live().await?;
		match live
			.view
			.release_line(line.operation, base.0, line.conversation.as_str(), line.text)
			.await
		{
			Ok(()) => Ok(()),
			Err(cause) => Err(self.failed(&live, cause, true).await),
		}
	}

	async fn typing(&self, conversation: &ConversationId, on: bool) -> Result<(), RoomsError> {
		let live = self.live().await?;
		match live.view.typing(conversation.as_str(), on).await {
			Ok(()) => Ok(()),
			Err(cause) => Err(self.failed(&live, cause, false).await),
		}
	}

	/// Read activity from `after` to its head, at most [`MAX_ECHO_READS`]
	/// reads, looking for the line's event. A restarted session leaves only
	/// the receipt to tell. A gap, an event that can no longer be shown, a
	/// row that did not decode, or a head past the bound makes the answer
	/// unknowable.
	async fn echoed(&self, line: &Outgoing<'_>, after: &Cursor) -> Result<Echo, RoomsError> {
		let live = self.live().await?;
		let mut cursor = after.as_str().to_owned();
		for _ in 0..MAX_ECHO_READS {
			let batch = match live.view.events(&cursor, false).await {
				Ok(batch) => batch,
				Err(attached::Error::Stale) => return Ok(Echo::Restarted),
				Err(cause) => return Err(self.failed(&live, cause, false).await),
			};
			let conversation = line.conversation.as_str();
			if batch
				.events
				.iter()
				.any(|event| map::echoes(event, conversation, line.operation))
			{
				return Ok(Echo::Found);
			}
			// A row that did not decode may be the echo itself.
			if batch.gap || batch.unavailable || batch.unreadable > 0 {
				return Ok(Echo::Unknowable);
			}
			if batch.events.is_empty() {
				return Ok(Echo::NotFound);
			}
			cursor = batch.cursor;
		}
		Ok(Echo::Unknowable)
	}

	async fn fetch(&self, attachment: &Attachment, destination: &Path) -> Result<u64, RoomsError> {
		let live = self.live().await?;
		match timeout(FETCH_DEADLINE, live.view.fetch(attachment, destination)).await {
			Ok(Ok(saved)) => Ok(saved),
			Ok(Err(cause)) => Err(self.failed(&live, cause, false).await),
			Err(_) => Err(RoomsError::new(
				RoomsErrorKind::Unreachable,
				format!("the file did not arrive within {} seconds", FETCH_DEADLINE.as_secs()),
			)),
		}
	}

	async fn settle_open(
		&self,
		operation: &str,
		base: Base,
		introduction: &attached::Introduction,
	) -> Result<Settled, RoomsError> {
		let live = self.live().await?;
		match live.view.introduce(operation, Some(base.0), introduction).await {
			Ok(attached::Opened::Opened { conversation, .. }) => Ok(Settled::Opened(conversation)),
			Ok(attached::Opened::Reused { conversation, .. }) => Ok(Settled::Reused(conversation)),
			Ok(attached::Opened::Unapplied(_)) => Ok(Settled::Unapplied),
			Ok(attached::Opened::Uncertain(_)) => Ok(Settled::Uncertain),
			Err(attached::Error::Unopened { released: true, .. }) => Ok(Settled::Released),
			Err(cause) => Err(self.failed(&live, cause, true).await),
		}
	}
}
