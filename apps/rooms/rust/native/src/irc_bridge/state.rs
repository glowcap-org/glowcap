use super::outbound;
use glowcap::{Argument, Ref, Session};
use rooms_application::{
	directory::{wire, Event, RoomChange, Shape},
	server::{
		directory::Directory,
		irc::{
			relay::Action,
			room::{Effects, Room},
		},
	},
};
use rooms_glowcap::snapshot::Arguments;
use std::{
	cell::RefCell,
	collections::{BTreeMap, BTreeSet, VecDeque},
	rc::Rc,
};
use tokio::sync::watch;

pub(super) type Shared = Rc<RefCell<State>>;
pub(super) struct Seat {
	pub generation: u64,
	pub capability: Ref,
}
pub(super) struct State {
	pub room: Room<u64, Ref>,
	pub directory: Directory<u64, Ref>,
	pub sessions: BTreeMap<u64, Session>,
	pub seats: BTreeMap<u64, Seat>,
	pub posts: outbound::Handle,
	pub changed: watch::Sender<()>,
	pub actions: VecDeque<Action>,
	pub failure: Option<String>,
	pub broken: BTreeSet<u64>,
	pub stopping: bool,
	pub writable: bool,
	next: u64,
	pub generation: u64,
}
impl State {
	pub fn new(room: Room<u64, Ref>, posts: outbound::Handle, changed: watch::Sender<()>, writable: bool) -> Self {
		Self {
			room,
			posts,
			changed,
			writable,
			directory: Directory::default(),
			sessions: BTreeMap::new(),
			seats: BTreeMap::new(),
			actions: VecDeque::new(),
			failure: None,
			broken: BTreeSet::new(),
			stopping: false,
			next: 1,
			generation: 0,
		}
	}
	pub fn admit(&mut self, session: Session) -> Result<u64, String> {
		if self.stopping {
			return Err("the IRC bridge is stopping".into());
		}
		if let Some((id, _)) = self.sessions.iter().find(|(_, held)| held.same_session(&session)) {
			return Ok(*id);
		}
		if self.sessions.len() >= super::peer::CONNECTIONS {
			return Err("the IRC bridge connection limit is full".into());
		}
		let id = self.next;
		self.next = self
			.next
			.checked_add(1)
			.ok_or("bridge connection identities exhausted")?;
		self.sessions.insert(id, session);
		Ok(id)
	}
	pub fn caller(&mut self) -> Result<(u64, Session), String> {
		let session = glowcap::current_session()
			.map_err(|e| e.to_string())?
			.ok_or("an IRC bridge is reachable only over a session")?;
		let id = self.admit(session.borrowed())?;
		Ok((id, session))
	}
	pub fn release(&self, id: u64, capability: Ref) {
		if let Some(session) = self.sessions.get(&id).filter(|s| s.is_open()) {
			if let Err(error) = session.release(capability) {
				eprintln!("rooms IRC bridge: capability release failed: {error}");
			}
		}
	}
	pub fn retire(&mut self, id: u64) {
		if let Some(seat) = self.seats.remove(&id) {
			self.release(id, seat.capability);
		}
		let effects = self.room.leave(id);
		self.apply(effects);
	}
	pub fn closed(&mut self, id: u64) {
		if !self.sessions.contains_key(&id) {
			return;
		}
		self.retire(id);
		for release in self.directory.connection_closed(id).releases {
			self.release(id, release.capability);
		}
		self.sessions.remove(&id);
		self.broken.remove(&id);
	}
	fn tell(&mut self, id: u64, inbox: &Ref, args: &[Argument]) {
		if let Some(session) = self.sessions.get(&id) {
			if let Err(error) = session.tell(inbox, "notify", args) {
				if session.is_open() {
					eprintln!("rooms IRC bridge: subscriber delivery failed: {error}");
				}
				self.broken.insert(id);
				self.changed.send_replace(());
			}
		}
	}
	pub fn actions(&mut self, actions: Vec<Action>) {
		if actions.is_empty() || self.failure.is_some() {
			return;
		}
		if self.actions.len() + actions.len() > 64 {
			self.failure = Some("IRC channel control queue is full".into());
		} else {
			self.actions.extend(actions);
		}
		self.changed.send_replace(());
	}
	pub fn apply(&mut self, effects: Effects<u64, Ref>) {
		self.actions(effects.relay);
		for (id, inbox, notice) in effects.tells {
			let args = rooms_application::server::irc::wire::arguments(&notice, &mut Arguments);
			self.tell(id, &inbox, &args);
		}
		for (id, inbox) in effects.releases {
			self.release(id, inbox);
		}
		for id in effects.presence {
			if let Some(session) = self.sessions.get(&id) {
				glowcap::annotate_session(session, self.room.member_nick(id));
			}
		}
		if effects.count_changed {
			let event = Event::Room {
				kind: RoomChange::Count,
				entry: self.room.info(),
			};
			let baseline = wire::event::<Arguments>(&event, Shape::Baseline);
			let publication = wire::event::<Arguments>(&event, Shape::Publication);
			let watchers: Vec<_> = self
				.directory
				.watchers()
				.map(|(id, inbox, shape)| (id, inbox.clone(), shape))
				.collect();
			for (id, inbox, shape) in watchers {
				self.tell(
					id,
					&inbox,
					if shape == Shape::Baseline {
						&baseline
					} else {
						&publication
					},
				);
			}
		}
	}
	pub fn demand(&mut self) {
		let actions = self.room.relay().set_pending_posts(self.posts.pending());
		self.actions(actions);
	}
}
