//! Bounded join execution returns a membership to its installing owner.
use super::*;

#[derive(Clone)]
pub(in crate::rooms) struct Wanted {
	pub(in crate::rooms) intent: super::super::intent::Intent,
	pub(in crate::rooms) epoch: u64,
}

pub(in crate::rooms) struct Joined<P: Platform> {
	pub(in crate::rooms) committed: bool,
	pub(in crate::rooms) wanted: Wanted,
	pub(in crate::rooms) room: Room<P>,
	pub(in crate::rooms) messages: Messages,
	pub(in crate::rooms) view: RoomView,
	pub(in crate::rooms) acquired: Option<join::Acquired>,
}

pub(super) enum Finished<P: Platform> {
	Ready(Box<Joined<P>>),
	Failed { wanted: Box<Wanted>, error: join::Failure },
}

impl Wanted {
	pub(super) fn blocked(&self) -> Result<(), String> {
		match self.intent.reconnect {
			Some(RoomReconnect::Manual) => Err("needs an explicit rejoin or a current room link".into()),
			_ if self.intent.held && self.intent.link.is_none() => Err("needs a new room link or handoff".into()),
			_ => Ok(()),
		}
	}
}

pub(super) async fn join<P: Platform>(
	entropy: EntropySource,
	directories: crate::directory_runtime::DirectoryRuntime<P>,
	events: mpsc::Sender<ConversationEvent>,
	notices: mpsc::Sender<Notice>,
	shared: Rc<RefCell<LiveRooms<P>>>,
	wanted: Wanted,
) -> Finished<P> {
	match realize(entropy, directories, events, notices, shared, wanted.clone()).await {
		Ok(joined) => Finished::Ready(Box::new(joined)),
		Err(error) => Finished::Failed {
			wanted: Box::new(wanted),
			error,
		},
	}
}

async fn realize<P: Platform>(
	entropy: EntropySource,
	directories: crate::directory_runtime::DirectoryRuntime<P>,
	events: mpsc::Sender<ConversationEvent>,
	notices: mpsc::Sender<Notice>,
	shared: Rc<RefCell<LiveRooms<P>>>,
	wanted: Wanted,
) -> Result<Joined<P>, join::Failure> {
	let (directory, nick) = directories
		.connected(&wanted.intent.directory)
		.ok_or_else(|| "that directory is not connected in this Rooms session".to_owned())?;
	if nick.is_empty() {
		return Err("this session has no directory nick for that room".into());
	}
	let reached = join::room_reference(
		entropy,
		&directory,
		&wanted.intent.name,
		wanted.intent.link.as_deref(),
		wanted.intent.publication.as_deref(),
	)
	.await?;
	subscribe(
		Resolved {
			directory,
			nick,
			reached,
		},
		events,
		notices,
		shared,
		wanted,
	)
	.await
}

pub(in crate::rooms) struct Resolved<P: Platform> {
	pub directory: rooms_glowcap::client::directory::Directory<P>,
	pub nick: String,
	pub reached: join::Reached,
}

pub(in crate::rooms) async fn subscribe<P: Platform>(
	resolved: Resolved<P>,
	events: mpsc::Sender<ConversationEvent>,
	notices: mpsc::Sender<Notice>,
	shared: Rc<RefCell<LiveRooms<P>>>,
	wanted: Wanted,
) -> Result<Joined<P>, join::Failure> {
	let Resolved {
		directory,
		nick,
		reached,
	} = resolved;
	let conversation = wanted.intent.id.clone();
	let epoch = wanted.epoch;
	let platform = directory.client().platform().clone();
	let shared = Rc::downgrade(&shared);
	let (room, messages) = Room::subscribe(
		directory.client().clone(),
		reached.reference,
		&nick,
		SubscribeOptions {
			voucher: None,
			on_event: Box::new(move |event| {
				let Some(shared) = shared.upgrade() else {
					return;
				};
				let notice = match event {
					Event::Typing { name, on } => {
						if !shared
							.borrow()
							.rooms
							.get(&conversation)
							.is_some_and(|live| live.epoch == epoch)
						{
							return;
						}
						// Typing is transient: under pressure the newest state
						// wins and a dropped edge costs nothing durable.
						// tolerant: see above.
						match platform.unix_millis() {
							Ok(at) => {
								let _ =
									events.try_send(super::super::events::typing(conversation.clone(), name, on, at));
							}
							Err(error) => {
								let mut state = shared.borrow_mut();
								state.issues.insert(format!("clock:{conversation}"), error.to_string());
								if let Some(live) = state.rooms.get_mut(&conversation) {
									live.resync = true;
								}
							}
						}
						return;
					}
					Event::Authority { kind, token, claimable } => Notice::Authority {
						id: conversation.clone(),
						epoch,
						kind,
						token: token.to_owned(),
						claimable,
					},
					Event::Policy(policy) => Notice::Policy {
						id: conversation.clone(),
						epoch,
						policy,
					},
					// The stream end carries the reason to the worker.
					Event::Ended(_) => return,
				};
				if notices.try_send(notice).is_err() {
					if let Some(live) = shared
						.borrow_mut()
						.rooms
						.get_mut(&conversation)
						.filter(|live| live.epoch == epoch)
					{
						live.resync = true;
					}
				}
			}),
		},
	)
	.await
	.map_err(|e| e.to_string())?;
	let prepared = async {
		// A newly created room already handed this join its manager. Install
		// that authority before publishing the live membership and its facts.
		let manager = reached
			.acquired
			.as_ref()
			.map(|grant| grant.manager_link.as_str())
			.or(wanted.intent.manager.as_deref());
		if let Some(link) = manager {
			room.stewardship()
				.take_manager(link)
				.await
				.map_err(|error| join::Failure::authority(Kind::Manager, link, error))?;
		}
		if let Some(link) = wanted.intent.steward.as_deref() {
			room.stewardship()
				.take(link)
				.await
				.map_err(|error| join::Failure::authority(Kind::Steward, link, error))?;
		}
		// A room whose policy cannot be read is not joined as open: the policy
		// decides what the view may do, so failing here fails closed.
		let policy = room.policy().await.map_err(|e| e.to_string())?;
		let kind = room.kind().map_err(|e| e.to_string())?;
		let conversation_id = Id::new(wanted.intent.id.clone().into())
			.ok_or_else(|| "room conversation id exceeds its field".to_owned())?;
		Ok::<_, join::Failure>(RoomView {
			conversation_id,
			membership_kind: kind,
			policy,
			members: List::new(Vec::new()).expect("an empty member list fits"),
			members_more: Some(false),
			topic: Nullable::Null,
			line_bytes: Nullable::Null,
			bridge: Presence::Missing,
			can_set_topic: Some(false),
			can_moderate: Some(false),
		})
	}
	.await;
	let view = match prepared {
		Ok(view) => view,
		Err(error) => {
			return Err(match room.leave().await {
				Ok(()) => error,
				Err(cleanup) => join::Failure::Unavailable(format!("{error}; room leave failed: {cleanup}")),
			});
		}
	};
	Ok(Joined {
		committed: true,
		view,
		room,
		messages,
		acquired: reached.acquired,
		wanted,
	})
}
