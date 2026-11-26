//! The CapTP implementation of [`Rooms`]: an attached view over a session
//! capability the operator was granted. The bot is its own Host with its own
//! identity, so the session can be on another machine and the access can be
//! paused or revoked without touching the session's owner.
//!
//! The mapping is one view call to one method, named in `map`. The only
//! state kept here is the connection. A call that finds the connection gone
//! drops it, and the next call dials again, so reattaching is driven by the
//! engine's own backoff.
mod dial;
mod map;
mod names;

use super::{
	ActionSettled, Attachment, Base, Batch, ConversationId, Cursor, Echo, FETCH_DEADLINE, Handback, Holder,
	OpenSettled, Outcome, Outgoing, Rooms, RoomsError, RoomsErrorKind, Typing, Wait,
};
use crate::bot::{
	error::Error,
	identity,
	link::Link,
	store::{Log, Store},
};
pub use dial::{Dial, Failure, Live};
use map::Ask;
use names::Names;
use rooms_glowcap::client::workspace::EffectStatus;
use rooms_services::session::attached;
use std::{cell::RefCell, path::Path, rc::Rc};
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
	async fn failed(&self, live: &Rc<Live>, cause: attached::Error, ask: Ask) -> RoomsError {
		self.lost(live, &cause).await;
		map::failure(cause, ask)
	}

	/// The answer of a call made on `live`, mapped by `ok`, or its failure named
	/// for `ask`.
	async fn answered<T, U>(
		&self,
		live: &Rc<Live>,
		ask: Ask,
		result: Result<T, attached::Error>,
		ok: impl FnOnce(T) -> U,
	) -> Result<U, RoomsError> {
		match result {
			Ok(answer) => Ok(ok(answer)),
			Err(cause) => Err(self.failed(live, cause, ask).await),
		}
	}

	/// Drop the connection when `cause` says it is gone.
	async fn lost(&self, live: &Rc<Live>, cause: &attached::Error) {
		if map::connection_lost(cause) {
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
	}
}

impl Rooms for Attached {
	async fn events(&self, after: &Cursor, wait: Wait) -> Result<Batch, RoomsError> {
		let live = self.live().await?;
		let raw = match live.view.events(after.as_str(), wait == Wait::Hold).await {
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
					Err(cause) => return Err(self.failed(&live, cause, Ask::Read).await),
				}
			}
			Err(cause) => return Err(self.failed(&live, cause, Ask::Read).await),
		};
		let in_rooms = raw
			.events
			.iter()
			.any(|event| event.conversation.kind == attached::Kind::Room);
		let names = if in_rooms {
			match live.view.snapshot().await {
				Ok(snapshot) => Names::of(&snapshot),
				Err(cause) => return Err(self.failed(&live, cause, Ask::Read).await),
			}
		} else {
			Names::default()
		};
		map::batch(raw, &names)
	}

	async fn base(&self) -> Result<Base, RoomsError> {
		let live = self.live().await?;
		self.answered(&live, Ask::Read, live.view.revision().await, Base).await
	}

	async fn send(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		let live = self.live().await?;
		let said = live
			.view
			.say_at(line.operation, base.0, line.conversation.as_str(), line.text)
			.await;
		self.answered(&live, Ask::Send, said, map::outcome).await
	}

	async fn observe(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		let live = self.live().await?;
		let arguments = [line.conversation.as_str().to_owned(), line.text.to_owned()];
		match live.view.observe(line.operation, base.0, "say", &arguments).await {
			Ok(status) => Ok(map::outcome(status)),
			Err(cause) if map::connection_lost(&cause) => Err(self.failed(&live, cause, Ask::Send).await),
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
			// The view owns which failures never clear (`refuses_keeping`): the
			// line's receipt is released for those and kept, to try again, for
			// the rest.
			Err(cause) => {
				let refused = cause.refuses_keeping();
				let mut error = self.failed(&live, cause, Ask::Send).await;
				if refused {
					error.kind = RoomsErrorKind::Refused;
				} else if error.kind == RoomsErrorKind::Refused {
					error.kind = RoomsErrorKind::Unreachable;
				}
				Err(error)
			}
		}
	}

	async fn release(&self, line: &Outgoing<'_>, base: Base) -> Result<Handback, RoomsError> {
		let live = self.live().await?;
		let released = live
			.view
			.release_line(line.operation, base.0, line.conversation.as_str(), line.text)
			.await;
		self.answered(&live, Ask::Send, released, map::handback).await
	}

	async fn holder(&self, operation: &str) -> Result<Holder, RoomsError> {
		let live = self.live().await?;
		self.answered(&live, Ask::Holder, live.view.holder(operation).await, |holder| holder)
			.await
	}

	async fn held(&self) -> Result<Vec<String>, RoomsError> {
		if crate::bot::fault::fails(crate::bot::fault::Fail::HeldList) {
			return Err(RoomsError::new(
				RoomsErrorKind::Unreachable,
				"a fault made the list fail",
			));
		}
		let live = self.live().await?;
		self.answered(&live, Ask::Read, live.view.held().await, |held| held)
			.await
	}

	async fn typing(&self, conversation: &ConversationId, typing: Typing) -> Result<(), RoomsError> {
		let live = self.live().await?;
		let shown = live.view.typing(conversation.as_str(), typing == Typing::Show).await;
		self.answered(&live, Ask::Read, shown, |()| ()).await
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
				Err(cause) => return Err(self.failed(&live, cause, Ask::Read).await),
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
			Ok(Err(cause)) => Err(self.failed(&live, cause, Ask::Read).await),
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
	) -> Result<OpenSettled, RoomsError> {
		if crate::bot::fault::fails(crate::bot::fault::Fail::SettlePending) {
			return Ok(OpenSettled::Pending);
		}
		if crate::bot::fault::fails(crate::bot::fault::Fail::SettleUnknown) {
			return Ok(OpenSettled::Unknown);
		}
		let live = self.live().await?;
		match live.view.introduce(operation, Some(base.0), introduction).await {
			Ok(attached::Opened::Opened { conversation, .. }) => Ok(OpenSettled::Opened(conversation)),
			Ok(attached::Opened::Reused { conversation, .. }) => Ok(OpenSettled::Reused(conversation)),
			Ok(attached::Opened::Unapplied(_)) => Ok(OpenSettled::Unapplied),
			Ok(attached::Opened::Uncertain(sent)) => Ok(match sent.status {
				EffectStatus::Unknown => OpenSettled::Unknown,
				// The open's own receipt may still settle, so the look repeats.
				EffectStatus::Pending | EffectStatus::Committed | EffectStatus::Unsent | EffectStatus::Conflict => {
					OpenSettled::Pending
				}
			}),
			Err(attached::Error::Unopened {
				receipt: attached::GiveBack::Released,
				..
			}) => Ok(OpenSettled::Released),
			Err(cause) => {
				let ask = map::open_ask(&cause);
				Err(self.failed(&live, cause, ask).await)
			}
		}
	}

	async fn release_open(
		&self,
		operation: &str,
		base: Base,
		introduction: &attached::Introduction,
	) -> Result<Handback, RoomsError> {
		let live = self.live().await?;
		match live.view.release_open(operation, base.0, introduction).await {
			Ok(answer) => Ok(map::handback(answer)),
			Err(cause) => {
				let ask = map::open_ask(&cause);
				Err(self.failed(&live, cause, ask).await)
			}
		}
	}

	async fn settle_action(&self, operation: &str) -> Result<ActionSettled, RoomsError> {
		if crate::bot::fault::fails(crate::bot::fault::Fail::SettlePending) {
			return Ok(ActionSettled::Pending);
		}
		let live = self.live().await?;
		match map::listed(live.view.settle_effect(operation).await) {
			Ok(settled) => Ok(settled),
			// A look sends nothing, so its refusal is the session's verdict on
			// the receipt, never one a later try clears.
			Err(cause) => Err(self.failed(&live, cause, Ask::Send).await),
		}
	}

	async fn release_action(&self, operation: &str) -> Result<Handback, RoomsError> {
		let live = self.live().await?;
		let released = live.view.release_effect(operation).await;
		self.answered(&live, Ask::Send, released, map::handback).await
	}
}
