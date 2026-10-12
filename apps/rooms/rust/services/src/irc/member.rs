//! One member's socket and independently retired channel memberships. A PART
//! must be confirmed before the same channel can acquire a new membership.
//! Otherwise a late JOIN could authorize the replacement accidentally.
use super::{Connection, Endpoint, Event, Events, Tls, WriteReceipt};
use rooms_application::server::irc::{
	MAX_BRIDGED_ROOMS,
	protocol::{Message, ctcp_action, encode, fold, nick_from_prefix},
	registration::{Role, SaslPlain},
};
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::Rc,
	time::Duration,
};
use tokio::{sync::watch, time::Instant};

const JOIN_TIMEOUT: Duration = Duration::from_secs(20);
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
	Starting,
	Registered(String),
	Ended(String),
}
#[derive(Clone)]
enum Phase {
	Joining,
	Joined,
	Retiring(String),
	Ended(String),
}
struct Channel {
	name: String,
	key: String,
	phase: watch::Sender<Phase>,
	deadline: Cell<Option<Instant>>,
}
struct State {
	channels: BTreeMap<String, Rc<Channel>>,
	status: watch::Sender<Status>,
	changed: watch::Sender<()>,
	nick: String,
}
#[derive(Clone)]
pub struct Member {
	connection: Connection,
	state: Rc<RefCell<State>>,
}
#[derive(Clone)]
pub struct Membership {
	member: Member,
	channel: Rc<Channel>,
}
pub struct Worker {
	member: Member,
	connection: Option<super::Worker>,
	events: Events,
}

pub fn open(
	endpoint: Endpoint,
	tls: Option<Tls>,
	nick: &str,
	sasl: Option<SaslPlain>,
) -> Result<(Member, Worker), String> {
	let (connection, worker, events) = Connection::open(
		endpoint,
		tls,
		Role::Member,
		nick,
		"glowcap Rooms member",
		sasl,
		Duration::ZERO,
	)?;
	let state = Rc::new(RefCell::new(State {
		channels: BTreeMap::new(),
		status: watch::channel(Status::Starting).0,
		changed: watch::channel(()).0,
		nick: nick.into(),
	}));
	let member = Member { connection, state };
	Ok((
		member.clone(),
		Worker {
			member,
			connection: Some(worker),
			events,
		},
	))
}
impl Member {
	pub fn changes(&self) -> watch::Receiver<Status> {
		self.state.borrow().status.subscribe()
	}
	pub async fn ready(&self) -> Result<String, String> {
		let mut status = self.changes();
		loop {
			match status.borrow().clone() {
				Status::Registered(nick) => return Ok(nick),
				Status::Ended(reason) => return Err(reason),
				Status::Starting => {}
			}
			status.changed().await.map_err(|_| "IRC member owner retired")?;
		}
	}
	/// Join returns immediately after bounded socket admission. `ready` on
	/// the membership observes the server's JOIN acknowledgement.
	pub fn join(&self, channel: &str) -> Result<Membership, String> {
		if !channel.starts_with('#')
			|| channel.len() > 200
			|| channel.chars().any(|c| c.is_control() || matches!(c, ' ' | ',' | ':'))
		{
			return Err("IRC membership needs one bounded channel name".into());
		}
		if !matches!(*self.state.borrow().status.borrow(), Status::Registered(_)) {
			return Err("IRC member is not registered".into());
		}
		let key = fold(channel);
		let mut state = self.state.borrow_mut();
		if let Some(held) = state.channels.get(&key) {
			if matches!(*held.phase.borrow(), Phase::Joining | Phase::Joined) {
				return Ok(Membership {
					member: self.clone(),
					channel: held.clone(),
				});
			}
			return Err("IRC channel departure is still awaiting confirmation".into());
		}
		if state.channels.len() >= MAX_BRIDGED_ROOMS {
			return Err("IRC member channel limit reached".into());
		}
		self.connection
			.write(encode("JOIN", &[channel]).map_err(|e| e.to_string())?)
			.map_err(|e| e.reason)?;
		let channel = Rc::new(Channel {
			name: channel.into(),
			key: key.clone(),
			phase: watch::channel(Phase::Joining).0,
			deadline: Cell::new(Some(Instant::now() + JOIN_TIMEOUT)),
		});
		state.channels.insert(key, channel.clone());
		state.changed.send_replace(());
		Ok(Membership {
			member: self.clone(),
			channel,
		})
	}
	pub fn stop(&self) {
		self.connection.stop();
	}
	pub async fn close(&self) -> Result<(), String> {
		self.connection.close().await
	}
	pub fn away(&self, reason: &str) -> Result<WriteReceipt, String> {
		let args = if reason.is_empty() { Vec::new() } else { vec![reason] };
		self.connection
			.write(encode("AWAY", &args).map_err(|e| e.to_string())?)
			.map_err(|e| e.reason)
	}
	fn end(&self, reason: String) {
		let mut state = self.state.borrow_mut();
		if matches!(*state.status.borrow(), Status::Ended(_)) {
			return;
		}
		for channel in std::mem::take(&mut state.channels).into_values() {
			channel.phase.send_replace(Phase::Ended(reason.clone()));
			channel.deadline.set(None);
		}
		state.status.send_replace(Status::Ended(reason));
	}
}
impl Membership {
	pub async fn ready(&self) -> Result<(), String> {
		let mut phase = self.channel.phase.subscribe();
		loop {
			match phase.borrow().clone() {
				Phase::Joined => return Ok(()),
				Phase::Retiring(reason) | Phase::Ended(reason) => return Err(reason),
				Phase::Joining => {}
			}
			phase.changed().await.map_err(|_| "IRC channel owner retired")?;
		}
	}
	pub async fn down(&self) -> String {
		let mut phase = self.channel.phase.subscribe();
		loop {
			if let Phase::Retiring(reason) | Phase::Ended(reason) = phase.borrow().clone() {
				return reason;
			}
			if phase.changed().await.is_err() {
				return "IRC channel owner retired".into();
			}
		}
	}
	pub fn say(&self, text: &str) -> Result<WriteReceipt, String> {
		self.post(text)
	}
	pub fn action(&self, text: &str) -> Result<WriteReceipt, String> {
		self.post(&ctcp_action(text))
	}
	fn post(&self, text: &str) -> Result<WriteReceipt, String> {
		if !matches!(*self.channel.phase.borrow(), Phase::Joined) {
			return Err("IRC channel membership is not active".into());
		}
		self.member
			.connection
			.write(encode("PRIVMSG", &[&self.channel.name, text]).map_err(|e| e.to_string())?)
			.map_err(|e| e.reason)
	}
	pub fn part(&self) -> Result<(), String> {
		self.retire(format!("left {}", self.channel.name))
	}
	fn retire(&self, reason: String) -> Result<(), String> {
		if matches!(*self.channel.phase.borrow(), Phase::Retiring(_) | Phase::Ended(_)) {
			return Ok(());
		}
		// The handle loses authority immediately; the row remains until PART
		// confirms it, preventing ambiguous reuse of the channel name.
		self.channel.phase.send_replace(Phase::Retiring(reason));
		self.channel.deadline.set(Some(Instant::now() + JOIN_TIMEOUT));
		self.member.state.borrow().changed.send_replace(());
		self.member
			.connection
			.write(encode("PART", &[&self.channel.name, "leaving the room"]).map_err(|e| e.to_string())?)
			.map_err(|e| e.reason)?;
		Ok(())
	}
}
impl Worker {
	pub async fn run(mut self) -> Result<(), String> {
		let worker = self.connection.take().ok_or("IRC member connection already started")?;
		let work = worker.run();
		tokio::pin!(work);
		let result = tokio::select! {
			result = &mut work => result,
			result = self.drive() => {
				self.member.stop();
				crate::cleanup::combine(result, work.await)
			}
		};
		self.member.end(
			result
				.as_ref()
				.err()
				.cloned()
				.unwrap_or_else(|| "IRC member closed".into()),
		);
		result
	}
	async fn drive(&mut self) -> Result<(), String> {
		let mut changes = self.member.state.borrow().changed.subscribe();
		loop {
			let deadline = self
				.member
				.state
				.borrow()
				.channels
				.values()
				.filter_map(|channel| channel.deadline.get())
				.min();
			tokio::select! {
				_ = changes.changed() => {},
				event = self.events.next() => match event {
					Some(Event::Registered { nick }) => {
						let mut state = self.member.state.borrow_mut();
						state.nick = nick.clone();
						state.status.send_replace(Status::Registered(nick));
					}
					Some(Event::Message(message)) => self.observe(&message)?,
					None => return self.member.connection.finished().await,
				},
				_ = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now)), if deadline.is_some() => self.expired()?,
			}
		}
	}
	fn observe(&self, message: &Message) -> Result<(), String> {
		let mut state = self.member.state.borrow_mut();
		let own = nick_from_prefix(message.prefix.as_deref()).is_some_and(|nick| fold(nick) == fold(&state.nick));
		if own && message.is("NICK") {
			if let Some(next) = message.param(0) {
				state.nick = next.into();
				state.status.send_replace(Status::Registered(next.into()));
			}
			return Ok(());
		}
		let refused = rooms_application::server::irc::protocol::refused_channel(message);
		let refusal = refused.is_some();
		let key = refused.or_else(|| message.param(0)).map(fold);
		let Some(channel) = key.and_then(|key| state.channels.get(&key).cloned()) else {
			return Ok(());
		};
		if own && message.is("JOIN") {
			if matches!(*channel.phase.borrow(), Phase::Joining) {
				channel.deadline.set(None);
				channel.phase.send_replace(Phase::Joined);
			}
			return Ok(());
		}
		let kicked = message.is("KICK") && message.param(1).is_some_and(|nick| fold(nick) == fold(&state.nick));
		let parted = own && message.is("PART");
		if parted || kicked || (refusal && matches!(*channel.phase.borrow(), Phase::Joining)) {
			state.channels.remove(&channel.key);
			channel.deadline.set(None);
			channel.phase.send_replace(Phase::Ended(format!(
				"IRC ended {}: {}",
				channel.name,
				message.last().unwrap_or(&message.command)
			)));
		}
		Ok(())
	}
	fn expired(&self) -> Result<(), String> {
		let due: Vec<_> = self
			.member
			.state
			.borrow()
			.channels
			.values()
			.filter(|channel| channel.deadline.get().is_some_and(|at| at <= Instant::now()))
			.cloned()
			.collect();
		for channel in due {
			if matches!(*channel.phase.borrow(), Phase::Retiring(_)) {
				return Err(format!(
					"IRC did not confirm leaving {}; retiring the connection",
					channel.name
				));
			}
			let reason = format!("IRC did not confirm joining {}", channel.name);
			Membership {
				member: self.member.clone(),
				channel,
			}
			.retire(reason)?;
		}
		Ok(())
	}
}
impl Drop for Worker {
	fn drop(&mut self) {
		self.member.stop();
		self.member.end("IRC member worker retired".into());
	}
}
