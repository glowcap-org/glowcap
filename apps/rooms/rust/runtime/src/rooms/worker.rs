//! The room worker: joins the rooms the checkpoint intends, pumps each one's
//! messages into the session's event stream, folds what the room says about
//! itself back into durable intent, and retires rooms the checkpoint drops
//! or that end their membership. This file is the loop and the notices it
//! hears; the diff, the joins, the facts, and the bridges each have a file.
mod bridge;
mod custody;
mod facts;
pub(super) mod joining;
mod reconcile;
mod retirement;
use super::{pump::pump, *};
use crate::session::commands::SessionCommands;
pub(super) use joining::Wanted;
use joining::{Finished, Joined};
use rooms_application::{
	room::{policy::RoomPolicy, stewardship::Kind},
	session::{
		checkpoint::{
			RoomReconnect,
			reconciliation::{Authority, Bearer, Fact, RoomContext, Text as FactText},
		},
		snapshot::{Field, Id, List, Nullable, Presence, views::RoomView},
	},
	text::DocumentText,
};
use rooms_glowcap::client::room::{Event, Messages, Room, SubscribeOptions};
use std::{collections::HashMap, rc::Rc, time::Duration};
use tokio::{
	sync::{mpsc, watch},
	task::JoinSet,
};

/// How long a retired or failed room waits before the worker tries it again.
const REJOIN_DELAY: Duration = Duration::from_secs(2);

pub struct RoomWorker<P: Platform> {
	platform: P,
	entropy: EntropySource,
	directories: crate::directories::runtime::DirectoryRuntime<P>,
	commands: SessionCommands,
	bridge_secrets: crate::session::bridge_secrets::BridgeSecrets,
	shared: Rc<RefCell<LiveRooms<P>>>,
	events: mpsc::Sender<ConversationEvent>,
	notices: mpsc::Sender<Notice>,
	notice_inbox: mpsc::Receiver<Notice>,
	stopping: watch::Receiver<bool>,
	finished: watch::Sender<Option<Result<(), Error>>>,
	changed: watch::Sender<()>,
	completed: JoinSet<Finished<P>>,
	bridges: JoinSet<bridge::Finished>,
	/// One pump per live room, owned here so retirement observes its end.
	pumps: JoinSet<()>,
	recorder: Option<Recorder>,
	retry_at: Option<P::Instant>,
}

pub(super) struct Parts<P: Platform> {
	pub platform: P,
	pub entropy: EntropySource,
	pub directories: crate::directories::runtime::DirectoryRuntime<P>,
	pub commands: SessionCommands,
	pub bridge_secrets: crate::session::bridge_secrets::BridgeSecrets,
	pub shared: Rc<RefCell<LiveRooms<P>>>,
	pub events: mpsc::Sender<ConversationEvent>,
	pub notices: mpsc::Sender<Notice>,
	pub notice_inbox: mpsc::Receiver<Notice>,
	pub stopping: watch::Receiver<bool>,
	pub finished: watch::Sender<Option<Result<(), Error>>>,
	pub changed: watch::Sender<()>,
	pub recorder: Option<Recorder>,
}

#[derive(Clone)]
pub(super) struct Recorder {
	pub archive: Rc<dyn crate::archive::recording::Recorder>,
	pub source: DocumentText,
	pub generation: DocumentText,
}

/// What a live room tells the worker about itself. Each names the room's
/// epoch, so a notice from a room that was since replaced is ignored.
pub(super) enum Notice {
	Authority {
		id: String,
		epoch: u64,
		kind: Kind,
		token: String,
		claimable: bool,
	},
	Policy {
		id: String,
		epoch: u64,
		policy: RoomPolicy,
	},
	/// The room's message stream ended: membership over, or the room gone.
	Retired {
		id: String,
		epoch: u64,
		reason: String,
		terminal: bool,
	},
}

impl<P: Platform> RoomWorker<P> {
	pub(super) fn new(parts: Parts<P>) -> Self {
		Self {
			platform: parts.platform,
			entropy: parts.entropy,
			directories: parts.directories,
			commands: parts.commands,
			bridge_secrets: parts.bridge_secrets,
			shared: parts.shared,
			events: parts.events,
			notices: parts.notices,
			notice_inbox: parts.notice_inbox,
			stopping: parts.stopping,
			finished: parts.finished,
			changed: parts.changed,
			completed: JoinSet::new(),
			bridges: JoinSet::new(),
			pumps: JoinSet::new(),
			recorder: parts.recorder,
			retry_at: None,
		}
	}
	pub async fn run(mut self) -> Result<(), Error> {
		let mut result = self.drive().await;
		result = Error::fold(result, self.retire_all().await);
		let staged = self.shared.borrow_mut().entry.take();
		if let Some(staged) = staged {
			result = Error::fold(result, staged.room.leave().await.map_err(Error::peer));
		}
		self.finished.send_replace(Some(result.clone()));
		result
	}
	async fn drive(&mut self) -> Result<(), Error> {
		self.reconcile().await?;
		let mut directory_changes = self.directories.changes();
		// Keep one receiver and mark it seen. Cloning the runtime's unread
		// receiver every loop treats every prior send as a new change and
		// starves join tasks on this LocalSet.
		directory_changes.mark_unchanged();
		loop {
			if *self.stopping.borrow() || self.stopping.has_changed().is_err() {
				return Ok(());
			}
			let retry = self.retry_at;
			let platform = self.platform.clone();
			tokio::select! {
				_ = self.stopping.changed() => return Ok(()),
				_ = directory_changes.changed() => self.reconcile().await?,
				Some(finished) = self.completed.join_next(), if !self.completed.is_empty() => {
					self.install(finished.map_err(|e| Error::closed(format!("room join ended: {e}")))?).await?;
				}
				Some(finished) = self.bridges.join_next(), if !self.bridges.is_empty() => {
					self.finish_bridge(finished.map_err(|e| Error::closed(format!("room bridge operation ended: {e}")))?).await;
				}
				// A pump ends with its room's stream; a pump that panicked is
				// this worker's failure, because its room is now unwatched.
				Some(ended) = self.pumps.join_next(), if !self.pumps.is_empty() => {
					ended.map_err(|e| Error::closed(format!("a room pump ended: {e}")))?;
				}
				Some(notice) = self.notice_inbox.recv() => self.notice(notice).await?,
				_ = platform.sleep_until(retry.unwrap_or_else(|| platform.now())), if retry.is_some() => {
					self.retry_at = None;
					self.reconcile().await?;
				}
			}
			self.resynchronize().await;
		}
	}
	/// Take a finished join: seat the membership, start its pump, and commit
	/// what the join learned. A join the checkpoint no longer wants is left.
	async fn install(&mut self, finished: Finished<P>) -> Result<(), Error> {
		match finished {
			Finished::Failed { wanted, error } => {
				if !self.accepts(&wanted)? {
					self.clear_attempt(&wanted);
					self.schedule_retry();
					return Ok(());
				}
				let reason = match error {
					join::Failure::Unavailable(reason) => reason.to_string(),
					join::Failure::Retired { kind, token } => {
						self.retired_authority(&wanted.intent, kind, token).await?;
						"the saved room authority was retired".into()
					}
				};
				let mut state = self.shared.borrow_mut();
				state.joining.remove(&wanted.intent.id);
				state.issues.insert(wanted.intent.subject, reason);
				drop(state);
				self.schedule_retry();
			}
			Finished::Ready(joined) => {
				let Joined {
					wanted,
					room,
					messages,
					view,
					acquired,
					..
				} = *joined;
				if !self.accepts(&wanted)? {
					self.clear_attempt(&wanted);
					// tolerant: a leave the room refuses still ends this session's
					// side of a membership the checkpoint no longer wants.
					let _ = room.leave().await;
					self.schedule_retry();
					return Ok(());
				}
				let id = wanted.intent.id.clone();
				let epoch = wanted.epoch;
				let scope = Rc::new(crate::session::commands::FactScope::new());
				let room = Rc::new(room);
				let standing = super::standing::maintain(
					room.clone(),
					wanted.intent.clone(),
					epoch,
					self.commands.clone(),
					self.directories.changes(),
					self.notices.clone(),
				);
				{
					let mut state = self.shared.borrow_mut();
					state.joining.remove(&id);
					state.issues.remove(&wanted.intent.subject);
					state.rooms.insert(
						id.clone(),
						LiveRoom {
							epoch,
							intent: wanted.intent.clone(),
							scope: scope.clone(),
							directory: wanted.intent.directory.text().as_str().unwrap_or("").to_owned(),
							nick: self
								.directories
								.connected(&wanted.intent.directory)
								.map(|(_, nick)| nick)
								.unwrap_or_default(),
							room,
							view,
							bridge_scope: None,
							bridge_scope_known: false,
							bridge_scope_pending: false,
							bridge_pending: None,
							applied_bridge: None,
							pending: Default::default(),
							next_pending: 0,
							posted: HashMap::new(),
							resync: false,
							file_batch: Default::default(),
							file_queue: Default::default(),
							id: id.clone(),
						},
					);
				}
				let pumping = pump(
					self.platform.clone(),
					id.clone(),
					epoch,
					messages,
					self.shared.clone(),
					self.events.clone(),
					self.notices.clone(),
					self.changed.clone(),
					self.commands.clone(),
					self.recorder.clone(),
				);
				// Membership retirement also wakes a pump blocked on an unconsumed
				// event or line receipt. Its archive work remains owned by the archive.
				self.pumps.spawn_local(async move {
					tokio::select! { biased; _ = scope.retired() => {}, () = pumping => {}, () = standing => {} }
				});
				self.reconcile_bridges().await;
				self.commit_joined(&id, epoch, &wanted.intent, acquired).await?;
			}
		}
		self.changed.send_replace(());
		Ok(())
	}
	/// Fold a room's notice into durable intent or the live view.
	async fn notice(&mut self, notice: Notice) -> Result<(), Error> {
		match notice {
			Notice::Authority {
				id,
				epoch,
				kind,
				token,
				claimable,
			} => {
				if !self.current(&id, epoch) {
					return Ok(());
				}
				let conversation = Id::new(id.clone().into())
					.ok_or_else(|| Error::invalid("room conversation id exceeds its field"))?;
				let kind = match kind {
					Kind::Room => Authority::Room,
					Kind::Manager => Authority::Manager,
					Kind::Steward => Authority::Steward,
				};
				let token =
					FactText::new(token.into()).ok_or_else(|| Error::invalid("authority token exceeds its field"))?;
				self.commit(&id, epoch, |context| {
					Ok(Fact::RoomAuthority {
						context,
						conversation,
						kind,
						token,
						claimable,
					})
				})
				.await?;
			}
			Notice::Policy { id, epoch, policy } => {
				let mut state = self.shared.borrow_mut();
				if let Some(live) = state.rooms.get_mut(&id).filter(|live| live.epoch == epoch) {
					live.view.policy = policy;
					drop(state);
					self.changed.send_replace(());
				}
			}
			Notice::Retired {
				id,
				epoch,
				reason,
				terminal,
			} => self.retired(id, epoch, reason, terminal).await,
		}
		Ok(())
	}
	/// Rejoin any room whose notices overflowed: its view is behind and the
	/// room's own state is the only way to catch up.
	async fn resynchronize(&mut self) {
		let behind: Vec<LiveRoom<P>> = {
			let mut state = self.shared.borrow_mut();
			let ids: Vec<String> = state
				.rooms
				.iter()
				.filter(|(_, live)| live.resync)
				.map(|(id, _)| id.clone())
				.collect();
			ids.into_iter().filter_map(|id| state.rooms.remove(&id)).collect()
		};
		if behind.is_empty() {
			return;
		}
		for live in behind {
			self.retire_live(live).await;
		}
		self.changed.send_replace(());
		self.schedule_retry();
	}
	fn current(&self, id: &str, epoch: u64) -> bool {
		self.shared
			.borrow()
			.rooms
			.get(id)
			.is_some_and(|live| live.epoch == epoch)
	}
	fn schedule_retry(&mut self) {
		let at = self.platform.now() + REJOIN_DELAY;
		self.retry_at = Some(self.retry_at.map_or(at, |held| held.min(at)));
	}
	async fn retire_all(&mut self) -> Result<(), Error> {
		// Joins use deadline-bound client calls. Observe their completion so a
		// successfully subscribed obsolete seat is explicitly left.
		let mut joins = Ok(());
		while let Some(result) = self.completed.join_next().await {
			match result {
				Ok(Finished::Ready(joined)) => {
					let _ = joined.room.leave().await;
				}
				Ok(Finished::Failed { .. }) => {}
				Err(error) => {
					joins = Error::fold(
						joins,
						Err(Error::closed(format!("room join ended during shutdown: {error}"))),
					)
				}
			}
		}
		let bridges = self.shutdown_bridges().await;
		let rooms = std::mem::take(&mut self.shared.borrow_mut().rooms);
		for live in rooms.into_values() {
			self.retire_live(live).await;
		}
		// Every pump ends with its room's stream, which retirement closed.
		let mut pumps = Ok(());
		while let Some(ended) = self.pumps.join_next().await {
			if let Err(error) = ended {
				pumps = Error::fold(pumps, Err(Error::closed(format!("a room pump ended: {error}"))));
			}
		}
		self.shared.borrow_mut().joining.clear();
		let mut media = std::mem::replace(
			&mut self.shared.borrow_mut().media,
			crate::files::media::Media::new(self.platform.clone()),
		);
		Error::fold(Error::fold(Error::fold(joins, bridges), pumps), media.close().await)
	}
	/// Leave a room and release the media its lines were holding.
	async fn retire_live(&self, live: LiveRoom<P>) {
		live.scope.retire();
		let room = live.id.clone();
		{
			let mut shared = self.shared.borrow_mut();
			shared.media.forget(|(held, _)| *held == room);
			shared.history.forget(&room);
		}
		retire(live).await;
	}
}

/// Leave the room now. A verb still holding the room, mid-upload say, is
/// refused by its retired seat rather than waited for.
async fn retire<P: Platform>(live: LiveRoom<P>) {
	// tolerant: a leave the room refuses still ends this session's membership
	// from its side, which is all retirement needs.
	let _ = live.room.leave().await;
}
