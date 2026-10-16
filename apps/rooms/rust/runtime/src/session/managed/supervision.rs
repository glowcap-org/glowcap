//! Live membership owns its callback and original requests through settlement.
//! Observation wakes progress. Abandoning readiness never cancels the worker.
use super::{Inbox, Session, realization};
use glowcap::{Argument, Result, loam};
use rooms_application::content::session::{custody, results, workspace};
use rooms_glowcap::client::{
	Deadline, Tasks,
	workspace::{EffectStatus, Workspace},
};
use std::{cell::Cell, future::Future, num::NonZeroU64, rc::Rc};
use tokio::sync::watch;

mod connection;
mod observation;
mod ownership;
mod rate_retry;
pub(super) mod retirement;
mod standing;
mod startup;
pub(super) use ownership::Budget;
pub(super) use ownership::Permit;
pub(super) use ownership::{Signals, spawn};

/// Keep this owner alongside the directory or conversation it realizes.
/// Readiness observers may be cancelled independently. A failed stage retains
/// its original request until retry or close. It cannot acquire newer intent.
pub struct Membership<P: Tasks> {
	_budget: Rc<Budget<P>>,
	stop: watch::Sender<bool>,
	retry: watch::Sender<u64>,
	ready: watch::Sender<Option<Result<()>>>,
	ended: watch::Sender<Option<Result<()>>>,
	active: Rc<Cell<bool>>,
}
impl<P: Tasks> Membership<P> {
	pub(super) fn retry_retirement(&self) -> bool {
		if self.active.get() && self.ended.borrow().is_some() {
			self.request_close();
			true
		} else {
			false
		}
	}
	pub(super) fn retry_signal(&self) -> watch::Sender<u64> {
		self.retry.clone()
	}
	pub fn is_active(&self) -> bool {
		self.active.get()
	}
	pub fn status(&self) -> Option<Result<()>> {
		match self.ended.borrow().as_ref() {
			Some(Ok(())) => None,
			Some(Err(error)) => Some(Err(error.clone())),
			None => self.ready.borrow().clone(),
		}
	}
	pub(super) fn retirement_status(&self) -> Option<Result<()>> {
		self.ended.borrow().clone()
	}
	pub async fn ready(&self) -> Result<()> {
		// Retry may clear a startup failure while this worker is already
		// retiring. Its completion is an independent readiness barrier: no
		// sender will publish another ready value after cleanup finishes.
		tokio::select! {
			biased;
			ended = self.ended() => ended.and(Err(loam::refusal("Membership worker has retired"))),
			ready = outcome(self.ready.subscribe()) => ready,
		}
	}
	/// Retry the retained stage, including an acquisition with a lost reply.
	/// A committed or unknown effect is observed, never sent as a fresh command.
	pub fn retry(&self) {
		if self.ended.borrow().is_some() || *self.stop.borrow() {
			return;
		}
		if !matches!(&*self.ready.borrow(), Some(Ok(()))) {
			self.ready.send_replace(None);
		}
		self.retry
			.send_modify(|generation| *generation = generation.wrapping_add(1));
	}
	pub async fn ended(&self) -> Result<()> {
		outcome(self.ended.subscribe()).await
	}
	pub async fn close(&mut self) -> Result<()> {
		self.request_close();
		self.ended().await
	}
	pub(super) fn request_close(&self) {
		if self.active.get() {
			self.ended.send_replace(None);
		}
		self.stop.send_replace(true);
	}
}
impl<P: Tasks> Drop for Membership<P> {
	fn drop(&mut self) {
		self.stop.send_replace(true);
	}
}
async fn outcome(mut state: watch::Receiver<Option<Result<()>>>) -> Result<()> {
	loop {
		if let Some(result) = state.borrow_and_update().clone() {
			return result;
		}
		state
			.changed()
			.await
			.map_err(|_| loam::refusal("Membership worker lost its close barrier"))?;
	}
}

enum Target {
	Direct,
	Directory {
		locator: String,
		name: custody::FieldKey<custody::DirectoryName>,
	},
	Room {
		seat: custody::FieldKey<custody::RoomSeat>,
		subject: custody::FieldKey<custody::RoomSubject>,
		files: custody::FieldKey<custody::RoomFiles>,
	},
}
#[derive(Clone, Copy)]
enum Lease {
	Directory(custody::FieldKey<custody::DirectoryName>),
	Room(custody::FieldKey<custody::RoomSeat>),
	Direct(custody::FieldKey<custody::DirectInbox>),
}
impl Target {
	fn lease(&self) -> Option<Lease> {
		match self {
			Self::Direct => None,
			Self::Directory { name, .. } => Some(Lease::Directory(*name)),
			Self::Room { seat, .. } => Some(Lease::Room(*seat)),
		}
	}
}
fn key<K>(entropy: &mut dyn crate::entropy::Entropy) -> Result<custody::FieldKey<K>> {
	let mut bytes = [0; 16];
	entropy
		.fill(&mut bytes)
		.map_err(|_| loam::refusal("Membership entropy is unavailable"))?;
	let malformed = || loam::refusal("Membership entropy is malformed");
	let slot = NonZeroU64::new(u64::from_be_bytes(bytes[..8].try_into().map_err(|_| malformed())?));
	let generation = NonZeroU64::new(u64::from_be_bytes(bytes[8..].try_into().map_err(|_| malformed())?));
	Ok(custody::FieldKey::new(
		slot.ok_or_else(|| loam::refusal("Empty membership custody identity"))?,
		generation.ok_or_else(|| loam::refusal("Empty membership custody generation"))?,
	))
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	pub async fn supervise_directory(
		&self,
		row: &workspace::Directory,
		locator: &str,
		entropy: &mut dyn crate::entropy::Entropy,
		mut receive: impl FnMut(&[Argument], &super::InboxOrigin) -> core::result::Result<(), String> + 'static,
	) -> Result<Membership<P>> {
		if locator.len() > 16384 {
			return Err(loam::refusal("Membership locator exceeds its bound"));
		}
		let permit = Permit::reserve(&self.state.memberships)?;
		let source = self.directory_source(row).await?;
		let mut selected = row.clone();
		selected.inbox = Some(key(entropy)?);
		let selection = workspace::InboxSelection::directory(&selected)
			.ok_or_else(|| loam::refusal("Directory has no exact initiating source"))?;
		let target = Target::Directory {
			locator: locator.into(),
			name: key(entropy)?,
		};
		self.start_membership(source, selection, target, entropy, permit, move |_, args, _, origin| {
			receive(args, origin).map(|()| Argument::Void)
		})
		.await
	}
	pub async fn supervise_room(
		&self,
		row: &workspace::Room,
		intent: &workspace::Intent,
		entropy: &mut dyn crate::entropy::Entropy,
		mut receive: impl FnMut(&[Argument], &super::InboxOrigin) -> core::result::Result<(), String> + 'static,
	) -> Result<Membership<P>> {
		let permit = Permit::reserve(&self.state.memberships)?;
		let source = self.room_source(row, intent).await?;
		let selection = workspace::InboxSelection::Room {
			id: row.id.clone(),
			directory: row.directory.clone(),
			nickname: workspace::RoomNickname::select(intent, &row.directory)
				.ok_or_else(|| loam::refusal("Room has no directory nickname"))?,
			access: row.access,
			accepted: row.accepted,
			public_entry: row.public_entry.clone(),
			publication: row.publication.clone(),
			source: row
				.source
				.ok_or_else(|| loam::refusal("Room has no initiating source"))?,
			inbox: key(entropy)?,
		};
		let target = Target::Room {
			seat: key(entropy)?,
			subject: key(entropy)?,
			files: key(entropy)?,
		};
		self.start_membership(source, selection, target, entropy, permit, move |_, args, _, origin| {
			receive(args, origin).map(|()| Argument::Void)
		})
		.await
	}
	pub async fn supervise_direct(
		&self,
		row: &workspace::Direct,
		entropy: &mut dyn crate::entropy::Entropy,
		receive: impl FnMut(
			&str,
			&[Argument],
			Option<glowcap::Session>,
			&super::InboxOrigin,
		) -> core::result::Result<Argument, String>
		+ 'static,
	) -> Result<Membership<P>> {
		let permit = Permit::reserve(&self.state.memberships)?;
		let source = self.direct_source(row).await?;
		let selected = workspace::InboxSelection::Direct {
			id: row.id.clone(),
			directory: row.directory.clone(),
			peer: row.peer.clone(),
			access: row.access,
			introduction: row.introduction.clone(),
			source: row
				.source
				.ok_or_else(|| loam::refusal("Direct has no initiating source"))?,
			inbox: key(entropy)?,
		};
		self.start_membership(source, selected, Target::Direct, entropy, permit, receive)
			.await
	}
	async fn start_membership(
		&self,
		source: realization::Source<P>,
		selected: workspace::InboxSelection,
		target: Target,
		entropy: &mut dyn crate::entropy::Entropy,
		permit: Permit<P>,
		receive: impl FnMut(
			&str,
			&[Argument],
			Option<glowcap::Session>,
			&super::InboxOrigin,
		) -> core::result::Result<Argument, String>
		+ 'static,
	) -> Result<Membership<P>> {
		let changes = self.state.changes.subscribe(&self.state)?;
		let operation = crate::entropy::random_id(entropy, "membership-").map_err(|e| loam::refusal(e.to_string()))?;
		let operation = operation
			.text()
			.as_str()
			.ok_or_else(|| loam::refusal("generated membership identifier is not text"))?
			.to_owned();
		let mut inbox = self.open_inbox(selected.clone(), receive).await?;
		if matches!(selected, workspace::InboxSelection::Direct { .. }) {
			let mut publication_entropy = [0; glowcap::Host::DURABLE_ENTROPY_BYTES];
			if let Err(error) = entropy
				.fill(&mut publication_entropy)
				.map_err(|e| loam::refusal(e.to_string()))
				.and_then(|()| inbox.publish(&self.state.writer.host, publication_entropy))
			{
				return Err(error.with_cleanup(inbox.close().await));
			}
		}
		let installation = match source.prepare_inbox(&selected, inbox.reference()).await {
			Ok(installation) => installation,
			Err(error) => return Err(error.with_cleanup(inbox.close().await)),
		};
		if self.state.closing.get() {
			return Err(loam::refusal("Session is closing").with_cleanup(inbox.close().await));
		}
		let budget = self.state.memberships.clone();
		if budget.contains(&operation) {
			return Err(loam::refusal("Membership identity is already active").with_cleanup(inbox.close().await));
		}
		let workspace = installation.1.workspace().clone();
		let retirement = Some(Rc::new(retirement::Owner::new(self.state.writer.host.clone())));
		let retained_retirement = retirement.clone();
		let startup_budget = budget.clone();
		let platform = self.state.platform.clone();
		let recovery = self.state.discovery_refresh.clone();
		let writer = self.state.writer.clone();
		let worker_budget = Rc::downgrade(&budget);
		Ok(ownership::spawn(
			&self.state.platform,
			&budget,
			operation.clone(),
			retained_retirement,
			move |signals| async move {
				let finished = signals.finished;
				let mut worker = Worker {
					lease: match &selected {
						workspace::InboxSelection::Direct { inbox, .. } => Some(Lease::Direct(*inbox)),
						_ => target.lease(),
					},
					writer,
					budget: worker_budget,
					inbox,
					selected,
					ready: signals.ready,
					finished: finished.clone(),
					stopping: signals.stopping,
					retrying: signals.retrying,
					workspace,
					changes,
					installed: false,
					live: false,
					connection_expiry_pending: false,
					platform,
					retirement,
					recovery,
					submission: None,
					standing: standing::Standing::default(),
					rate_retry: rate_retry::Window::new(&operation),
				};
				let mut cancellation = worker.stopping.clone();
				let retirement = worker.retirement.clone();
				let outcome = tokio::select! {
					biased;
					_ = cancellation.changed() => Ok(()),
					ended = async {
						match retirement {
							Some(owner) => owner.ended().await,
							None => std::future::pending().await,
						}
					} => {
						worker.live = false;
						worker.recovery.recover();
						ended
					},
					outcome = worker.run(installation, source, target, &operation, permit, startup_budget) => outcome,
				};
				if worker.ready.borrow().is_none() {
					worker.ready.send_replace(Some(match &outcome {
						Ok(()) => Err(loam::refusal("Membership closed before readiness")),
						Err(error) => Err(error.clone()),
					}));
				}
				loop {
					// The outer cancellation wait owns a different receiver. Consume
					// the signal that starts this cleanup so it cannot also retry a
					// failed barrier under the same expired deadline.
					worker.stopping.borrow_and_update();
					worker.retrying.borrow_and_update();
					let closed = worker.cleanup().await;
					if closed.is_ok()
						|| (worker.inbox.drained()
							&& worker.retirement.is_none()
							&& worker.submission.is_none()
							&& !worker.connection_expiry_pending)
					{
						return merge(outcome, closed);
					}
					// Requests arriving during this attempt receive its result.
					// Consume them before publishing failure so an abandoned view
					// cannot accidentally start another refused cleanup attempt.
					worker.stopping.borrow_and_update();
					worker.retrying.borrow_and_update();
					finished.send_replace(Some(merge(outcome.clone(), closed)));
					// Exact failed cleanup remains owned until a later close or retry.
					tokio::select! {
						_ = worker.stopping.changed() => {},
						_ = worker.retrying.changed() => {},
					}
				}
			},
		))
	}
}
fn merge(first: Result<()>, next: Result<()>) -> Result<()> {
	match first {
		Ok(()) => next,
		Err(error) => Err(error.with_cleanup(next)),
	}
}
/// A callback and its exact initiating source outlive readiness waits. Shared
/// change feeds wake this owner, which rechecks its own held authority.
/// Only the four permitted startup workers retain bounded encoded candidates.
/// Live workers keep scalar selections, never full workspace snapshots.
struct Worker<P: Tasks> {
	writer: Rc<super::executor::Writer>,
	budget: std::rc::Weak<Budget<P>>,
	lease: Option<Lease>,
	inbox: Inbox<P>,
	selected: workspace::InboxSelection,
	ready: watch::Sender<Option<Result<()>>>,
	finished: watch::Sender<Option<Result<()>>>,
	stopping: watch::Receiver<bool>,
	retrying: watch::Receiver<u64>,
	workspace: Workspace<P>,
	changes: super::changes::Wake,
	installed: bool,
	live: bool,
	// Cleanup can retire the observer before a refused workspace expiry is
	// retried. Retain affirmative loss until its exact lease is withdrawn.
	connection_expiry_pending: bool,
	platform: P,
	retirement: Option<Rc<retirement::Owner>>,
	recovery: Rc<super::watching::Refresh>,
	submission: Option<rooms_glowcap::client::workspace::Submission>,
	standing: standing::Standing<P>,
	rate_retry: rate_retry::Window,
}
impl<P: Tasks + Deadline + Clone + 'static> Worker<P> {
	async fn stage<T, F, Fut>(&mut self, mut attempt: F) -> Result<Option<T>>
	where
		F: FnMut() -> Fut,
		Fut: Future<Output = Result<T>>,
	{
		loop {
			let result = tokio::select! {
				biased;
				_ = self.stopping.changed() => return Ok(None),
				result = async {
					let _inspection = self.changes.inspect().await;
					attempt().await
				} => result,
			};
			match result {
				Ok(value) => return Ok(Some(value)),
				Err(failure) => {
					if !self.failed(failure).await? {
						return Ok(None);
					}
				}
			}
		}
	}
	async fn retry_selection_current(&mut self) -> Result<bool> {
		if *self.stopping.borrow() {
			return Ok(false);
		}
		if self.installed {
			let _inspection = self.changes.inspect().await;
			if let Ok(snapshot) = self.workspace.owner_snapshot(&self.writer.root()?).await
				&& !self.selected.matches(&snapshot.intent)
			{
				return Ok(false);
			}
		}
		Ok(!*self.stopping.borrow())
	}
	async fn retry_after(&mut self, advice: rooms_application::admission::RetryAdvice) -> Result<bool> {
		// A retry requested during an automatic cooldown cannot accumulate into
		// another window after exhaustion. Only a later explicit request resets it.
		self.retrying.borrow_and_update();
		let proceed = match self.rate_retry.delay(advice, self.platform.monotonic_millis()) {
			Some(delay) => rate_retry::wait(&self.platform, &mut self.stopping, delay).await,
			None => {
				// Exhaustion retains the exact worker and diagnostic. Ordinary
				// workspace wakes cannot start another automatic retry window.
				if *self.stopping.borrow() {
					return Ok(false);
				}
				tokio::select! {
					biased;
					_ = self.stopping.changed() => false,
					changed = self.retrying.changed() => {
						if changed.is_err() { false } else { self.rate_retry.reset(); true }
					}
				}
			}
		};
		if proceed {
			self.retry_selection_current().await
		} else {
			Ok(false)
		}
	}
	async fn failed(&mut self, failure: glowcap::Error) -> Result<bool> {
		let retry = rooms_application::failure::Failure::parse(&failure.to_string()).and_then(|f| f.retry_advice());
		self.ready.send_replace(Some(Err(failure)));
		if let Some(retry) = retry {
			return self.retry_after(retry).await;
		}
		let changed = self.changed().await?;
		if changed {
			self.rate_retry.reset();
			let snapshot = if self.installed {
				let _inspection = self.changes.inspect().await;
				self.workspace.owner_snapshot(&self.writer.root()?).await.ok()
			} else {
				None
			};
			if let Some(snapshot) = snapshot
				&& !self.selected.matches(&snapshot.intent)
			{
				return Ok(false);
			}
			self.ready.send_replace(self.live.then_some(Ok(())));
		}
		Ok(changed)
	}
}
fn error(error: rooms_glowcap::client::Error) -> glowcap::Error {
	match error {
		rooms_glowcap::client::Error::Binding(error) | rooms_glowcap::client::Error::Unsent(error) => *error,
		rooms_glowcap::client::Error::Observation(reason)
		| rooms_glowcap::client::Error::RefusedObservation(reason) => {
			// The retained reason already crossed the binding wrapper. Normalize only
			// validated Rooms carriers before placing it back in a binding error.
			match rooms_application::failure::Failure::parse(&reason) {
				Some(failure) => loam::refusal(failure.to_string()),
				None => loam::refusal(reason),
			}
		}
		error => loam::refusal(error.to_string()),
	}
}
