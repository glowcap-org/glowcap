//! Live room realization driven by committed session conversations. The
//! handle reads and acts on live rooms; the worker joins, watches, and
//! retires them as the checkpoint and the rooms themselves change.
mod entry;
mod events;
mod file_commands;
mod file_mutations;
pub use file_commands::FileCommand;
mod history;
mod intent;
mod join;
mod pump;
mod recording;
mod standing;
mod worker;
use crate::directory_runtime::DirectoryRuntime;
pub use crate::platform::Platform;
use crate::{bridge_secrets::BridgeSecrets, entropy::Entropy, session_commands::SessionCommands};
type EntropySource = Rc<RefCell<Box<dyn Entropy>>>;
pub use events::{typing, ConversationEvent};
use rooms_application::session::{checkpoint::RoomIntent, snapshot::views::RoomView};
use rooms_glowcap::client::{posted_line::PostedLine, room::Room};
use std::{
	cell::RefCell,
	collections::{HashMap, VecDeque},
	rc::Rc,
};
use tokio::sync::{mpsc, watch};
pub use worker::RoomWorker;

const EVENT_LIMIT: usize = 256;
const PENDING_LINES: usize = 2000;
/// Room-side notices (authority, policy, membership end) in flight to the
/// worker. Rare per room; a full channel asks for a resynchronizing rejoin.
const NOTICE_LIMIT: usize = 256;

#[derive(Clone)]
pub struct RoomRuntime<P: Platform> {
	events: mpsc::Sender<ConversationEvent>,
	notices: mpsc::Sender<worker::Notice>,
	platform: P,
	commands: SessionCommands,
	incarnation: [u8; 16],
	file_inputs: Rc<file_commands::Inputs>,
	shared: Rc<RefCell<LiveRooms<P>>>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Result<(), String>>>,
	changed: watch::Receiver<()>,
}

pub(super) struct LiveRooms<P: Platform> {
	entry: Option<worker::joining::Joined<P>>,
	rooms: HashMap<String, LiveRoom<P>>,
	joining: HashMap<String, worker::Wanted>,
	bridge_locks: HashMap<(String, String), std::rc::Weak<tokio::sync::Mutex<()>>>,
	/// Explicit room-retired notices block name-based recreation until durable
	/// intent changes. Transport loss never enters this map.
	terminal: HashMap<String, intent::Intent>,
	issues: HashMap<String, String>,
	/// The media every live room's lines carry, one pool for all rooms and one
	/// selection per (room, line).
	media: super::media::Media<(String, u64), P>,
	history: history::History,
	/// Numbers each realized room, so a notice or stream end from a room that
	/// has since been replaced names the old one and is ignored.
	next_epoch: u64,
}

pub(super) struct LiveRoom<P: Platform> {
	pub id: String,
	pub epoch: u64,
	intent: intent::Intent,
	scope: Rc<crate::session_commands::FactScope>,
	pub directory: String,
	pub nick: String,
	pub room: Rc<Room<P>>,
	pub view: RoomView,
	bridge_scope: Option<rooms_application::text::DocumentText>,
	bridge_scope_known: bool,
	bridge_scope_pending: bool,
	bridge_pending: Option<intent::Bridge>,
	applied_bridge: Option<intent::Bridge>,
	pub pending: VecDeque<(u64, PendingLine<P>)>,
	pub next_pending: u64,
	pub posted: HashMap<u64, Rc<PostedLine<P>>>,
	/// Set when a room notice could not be queued; the worker rejoins to
	/// resynchronize rather than carry on with a view it knows is behind.
	pub resync: bool,
	file_batch: file_mutations::Slot,
	file_queue: Rc<tokio::sync::Mutex<()>>,
}

pub(super) enum PendingLine<P: Platform> {
	Wait(tokio::sync::oneshot::Receiver<Option<Rc<PostedLine<P>>>>),
}

impl<P: Platform> RoomRuntime<P> {
	/// CapTP reference identity, within the exact live connection, decides
	/// whether a pasted link already names one of this session's memberships.
	pub fn holding(&self, session: &glowcap::Session, reference: &glowcap::Ref) -> Option<String> {
		self.shared
			.borrow()
			.rooms
			.values()
			.find(|live| {
				live.scope.current()
					&& live.room.client().session().same_session(session)
					&& live.room.reference() == reference
			})
			.map(|live| live.id.clone())
	}
	/// Drive the returned worker on the same LocalSet as directory realization.
	/// Fails only when no entropy is available to name this incarnation's
	/// recordings and line identities; a generation drawn from nothing would collide.
	pub fn open(
		platform: P,
		mut entropy: impl Entropy + 'static,
		directories: DirectoryRuntime<P>,
		commands: SessionCommands,
		bridge_secrets: BridgeSecrets,
		archive: Option<(
			Rc<dyn crate::archive_recording::Recorder>,
			rooms_application::text::DocumentText,
		)>,
	) -> Result<(Self, RoomWorker<P>, Events), String> {
		let shared = Rc::new(RefCell::new(LiveRooms {
			entry: None,
			rooms: HashMap::new(),
			joining: HashMap::new(),
			bridge_locks: HashMap::new(),
			terminal: HashMap::new(),
			issues: HashMap::new(),
			media: crate::media::Media::new(platform.clone()),
			history: Default::default(),
			next_epoch: 0,
		}));
		let (events, received) = mpsc::channel(EVENT_LIMIT);
		let (notices, notice_inbox) = mpsc::channel(NOTICE_LIMIT);
		let (stop, stopping) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let (changed, changes) = watch::channel(());
		let mut incarnation = [0u8; 16];
		entropy
			.fill(&mut incarnation)
			.map_err(|_| "room incarnation entropy is unavailable")?;
		let recorder = match archive {
			Some((archive, source)) => {
				let generation: String = incarnation.iter().map(|byte| format!("{byte:02x}")).collect();
				Some(worker::Recorder {
					archive,
					source,
					generation: generation.into(),
				})
			}
			None => None,
		};
		let worker = RoomWorker::new(worker::Parts {
			platform: platform.clone(),
			entropy: Rc::new(RefCell::new(Box::new(entropy))),
			directories,
			commands: commands.clone(),
			bridge_secrets,
			shared: shared.clone(),
			events: events.clone(),
			notices: notices.clone(),
			notice_inbox,
			stopping,
			finished,
			changed,
			recorder,
		});
		Ok((
			Self {
				events,
				notices,
				platform,
				commands,
				incarnation,
				file_inputs: Default::default(),
				shared,
				stop,
				done,
				changed: changes,
			},
			worker,
			Events(received),
		))
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.changed.clone()
	}
	pub fn views(&self) -> Vec<RoomView> {
		self.shared
			.borrow()
			.rooms
			.values()
			.map(|live| {
				let mut view = live.view.clone();
				// Custody changes independently of room messages. Never cache a
				// capability grant in the initial subscription's display row.
				view.can_set_topic = Some(live.room.can_set_topic());
				view.can_moderate = Some(live.room.stewardship().held());
				view
			})
			.collect()
	}
	pub fn issues(&self) -> Vec<(String, String)> {
		self.shared
			.borrow()
			.issues
			.iter()
			.map(|(subject, reason)| (subject.clone(), reason.clone()))
			.collect()
	}
	pub fn connected(&self, conversation: &str) -> bool {
		self.shared.borrow().rooms.contains_key(conversation)
	}
	pub fn live(&self, conversation: &str) -> Result<Rc<Room<P>>, String> {
		self.room(conversation)
	}
	pub fn source(&self, conversation: &str) -> Result<(String, Rc<Room<P>>), String> {
		let state = self.shared.borrow();
		let live = connected(&state, conversation)?;
		Ok((live.directory.clone(), live.room.clone()))
	}
	pub fn typing(&self, conversation: &str, on: bool) -> Result<(), String> {
		self.room(conversation)?.typing(on).map_err(|e| e.to_string())
	}
	pub async fn say(&self, conversation: &str, text: &str) -> Result<(), Failure> {
		if utf16_len(text) > rooms_application::room::line::MAX_LINE_BYTES {
			return Err(Failure::NotApplied(
				"say takes a conversation id and bounded text".into(),
			));
		}
		let (room, slot) = self.reserve_pending(conversation).map_err(Failure::NotApplied)?;
		match room.say(text).await {
			Ok(posted) => {
				slot.complete(posted);
				Ok(())
			}
			Err(error) => {
				slot.abort();
				Err(failure(error))
			}
		}
	}
	pub async fn edit(&self, conversation: &str, line: u64, text: &str) -> Result<(), Failure> {
		self.line(conversation, line)
			.map_err(Failure::NotApplied)?
			.edit(text)
			.await
			.map_err(failure)
	}
	pub async fn withdraw(&self, conversation: &str, line: u64) -> Result<(), Failure> {
		self.line(conversation, line)
			.map_err(Failure::NotApplied)?
			.withdraw()
			.await
			.map_err(failure)?;
		if let Some(live) = self.shared.borrow_mut().rooms.get_mut(conversation) {
			live.posted.remove(&line);
		}
		Ok(())
	}
	pub async fn bridge_form(&self, conversation: &str) -> Result<Option<rooms_application::bridge::Form>, String> {
		self.room(conversation)?.bridge_form().await.map_err(|e| e.to_string())
	}
	pub fn bridge_scope(
		&self,
		conversation: &rooms_application::text::DocumentText,
	) -> Option<rooms_application::text::DocumentText> {
		let conversation = conversation.as_str()?;
		self.shared.borrow().rooms.get(conversation)?.bridge_scope.clone()
	}
	pub async fn set_topic(&self, conversation: &str, text: &str) -> Result<(), Failure> {
		self.effect(conversation)?.set_topic(text).await.map_err(failure)
	}
	pub async fn kick(&self, conversation: &str, nick: &str) -> Result<(), Failure> {
		self.effect(conversation)?
			.stewardship()
			.kick(nick)
			.await
			.map_err(failure)
	}
	pub async fn revoke_authority(&self, conversation: &str, kind: &str, token: &str) -> Result<(), Failure> {
		let room = self.effect(conversation)?;
		match kind {
			"room" => room.stewardship().revoke_room_link(token).await.map_err(failure),
			"steward" => room.stewardship().revoke_steward(token).await.map_err(failure),
			_ => Err(Failure::NotApplied(
				"managed room revocation takes a room, authority kind, and exact token".into(),
			)),
		}
	}
	pub async fn unregister(&self, conversation: &str) -> Result<(), Failure> {
		self.effect(conversation)?
			.stewardship()
			.unregister()
			.await
			.map(|_| ())
			.map_err(failure)
	}
	pub async fn set_policy(
		&self,
		conversation: &str,
		name: &str,
		policy: rooms_application::room::policy::RoomPolicy,
	) -> Result<(), Failure> {
		self.effect(conversation)?
			.stewardship()
			.set_policy(policy, name)
			.await
			.map(|_| ())
			.map_err(failure)
	}
	fn room(&self, conversation: &str) -> Result<Rc<Room<P>>, String> {
		Ok(connected(&self.shared.borrow(), conversation)?.room.clone())
	}
	/// `room` for an effect: a conversation this session is not in applies
	/// nothing.
	fn effect(&self, conversation: &str) -> Result<Rc<Room<P>>, Failure> {
		self.room(conversation).map_err(Failure::NotApplied)
	}
	fn reserve_pending(&self, conversation: &str) -> Result<(Rc<Room<P>>, PendingSlot<P>), String> {
		let mut state = self.shared.borrow_mut();
		let live = state
			.rooms
			.get_mut(conversation)
			.ok_or_else(|| "that room is not connected in this Rooms session".to_owned())?;
		if live.pending.len() >= PENDING_LINES {
			return Err("that room has too many line capabilities waiting for their echoes".into());
		}
		let (tx, rx) = tokio::sync::oneshot::channel();
		let id = live.next_pending;
		live.next_pending = live.next_pending.saturating_add(1);
		live.pending.push_back((id, PendingLine::Wait(rx)));
		Ok((
			live.room.clone(),
			PendingSlot {
				conversation: conversation.to_owned(),
				epoch: live.epoch,
				id,
				tx,
				shared: self.shared.clone(),
			},
		))
	}
	fn line(&self, conversation: &str, line: u64) -> Result<Rc<PostedLine<P>>, String> {
		connected(&self.shared.borrow(), conversation)?
			.posted
			.get(&line)
			.cloned()
			.ok_or_else(|| "this Rooms session does not hold authority over that line".into())
	}
	pub async fn close(&self) -> Result<(), String> {
		self.file_inputs.close().await;
		self.stop.send_replace(true);
		let mut done = self.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| "room worker retired without completing shutdown".to_string())?;
		}
	}
}

/// How room work that did not simply succeed ended. The ledger settles the
/// operation by this: an effect the room applied is committed, one it never
/// saw is abandoned, and only an answer that was lost is left for a reader
/// to decide.
pub enum Failure {
	/// The room applied nothing; the same intent can be sent again.
	NotApplied(String),
	/// The room applied the effect before the rest failed; the effect stands.
	Applied(String),
	/// The room's answer was lost, so whether it applied is unknown here.
	Unknown(String),
}
/// A failure with no room verdict in it is one nobody can settle here.
impl From<String> for Failure {
	fn from(reason: String) -> Self {
		Self::Unknown(reason)
	}
}
/// Local argument refusal precedes delivery. A remote exception does not prove
/// that no effect occurred before the exception; only acknowledgement proves it.
fn failure(error: rooms_glowcap::client::Error) -> Failure {
	use rooms_glowcap::client::Error;
	match &error {
		Error::Binding(_) | Error::Timeout(_) => Failure::Unknown(error.to_string()),
		_ => Failure::NotApplied(error.to_string()),
	}
}

struct PendingSlot<P: Platform> {
	conversation: String,
	epoch: u64,
	id: u64,
	tx: tokio::sync::oneshot::Sender<Option<Rc<PostedLine<P>>>>,
	shared: Rc<RefCell<LiveRooms<P>>>,
}
impl<P: Platform> PendingSlot<P> {
	fn complete(self, line: Option<PostedLine<P>>) {
		// tolerant: the pump that would receive this echo may have retired
		// with its room; the line is then not one this session can edit.
		let _ = self.tx.send(line.map(Rc::new));
	}
	fn abort(self) {
		if let Some(live) = self
			.shared
			.borrow_mut()
			.rooms
			.get_mut(&self.conversation)
			.filter(|live| live.epoch == self.epoch)
		{
			live.pending.retain(|(id, _)| *id != self.id);
		}
	}
}

pub struct Events(mpsc::Receiver<ConversationEvent>);
impl Events {
	pub async fn next(&mut self) -> Option<ConversationEvent> {
		self.0.recv().await
	}
}

fn connected<'a, P: Platform>(state: &'a LiveRooms<P>, conversation: &str) -> Result<&'a LiveRoom<P>, String> {
	state
		.rooms
		.get(conversation)
		.ok_or_else(|| "that room is not connected in this Rooms session".into())
}

fn utf16_len(text: &str) -> usize {
	text.encode_utf16()
		.take(rooms_application::room::line::MAX_LINE_BYTES + 1)
		.count()
}

pub(super) fn subject(intent: RoomIntent<'_>) -> String {
	format!(
		"room:{}:{}",
		intent.directory.text().as_str().unwrap_or(""),
		intent.id.text().as_str().unwrap_or("")
	)
}
