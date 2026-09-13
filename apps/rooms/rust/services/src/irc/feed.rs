//! One demand-owned, reconnecting socket for a gateway network. Channel
//! membership remains in the portable gateway; timers and receipts stay here.
use super::{Connection, Endpoint, Event, Events, Tls, WriteError};
use futures_util::{StreamExt, stream::FuturesUnordered};
use rooms_application::server::irc::{
	gateway::{FeedStatus, Gateway},
	protocol::{Message, encode},
	registration::Role,
	relay::Action,
	room::Effects,
};
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	future::Future,
	pin::Pin,
	rc::Rc,
	time::Duration,
};
use tokio::{
	sync::{mpsc, watch},
	time::Instant,
};

const INTERVAL: Duration = Duration::from_millis(1200);
const JOIN_TIMEOUT: Duration = Duration::from_secs(30);
type Receipt = Pin<Box<dyn Future<Output = Result<(), WriteError>>>>;
type Emit<C, R> = Rc<dyn Fn(&str, Effects<C, R>) -> Result<(), String>>;

#[derive(Clone)]
pub struct Feed {
	changed: watch::Sender<()>,
	stop: watch::Sender<bool>,
	generation: Rc<Cell<u64>>,
	actions: mpsc::Sender<Batch>,
	failure: watch::Sender<Option<String>>,
}
struct Batch {
	key: String,
	publication: String,
	generation: u64,
	actions: Vec<Action>,
}
impl Feed {
	/// Wake after channel admission, retirement or reader-count changes.
	pub fn changed(&self) {
		self.changed.send_replace(());
	}
	pub fn stop(&self) {
		self.stop.send_replace(true);
	}
	/// Submit the relay actions a room operation produced. Overflow retires
	/// this feed incarnation so its next connection can resynchronize state.
	pub fn apply(&self, key: &str, publication: &str, mut actions: Vec<Action>) -> Result<(), String> {
		if actions.is_empty() {
			return Ok(());
		}
		let bounded = key.len() <= 1024
			&& publication.len() <= 128
			&& actions.len() <= 4
			&& actions.iter().all(|action| match action {
				Action::Send(bytes) => bytes.len() <= 512,
				Action::Fail(reason) => reason.len() <= 1024,
				Action::ArmJoinTimer(_) => true,
			});
		if !bounded {
			self.failure
				.send_replace(Some("IRC relay action exceeds its budget".into()));
			return Err("IRC relay action exceeds its budget".into());
		}
		for action in &mut actions {
			match action {
				Action::Send(bytes) => *bytes = std::mem::take(bytes).into_boxed_slice().into_vec(),
				Action::Fail(reason) => *reason = std::mem::take(reason).into_boxed_str().into_string(),
				Action::ArmJoinTimer(_) => {}
			}
		}
		let actions = actions.into_boxed_slice().into_vec();
		let batch = Batch {
			key: key.into(),
			publication: publication.into(),
			generation: self.generation.get(),
			actions,
		};
		if self.actions.try_send(batch).is_err() {
			self.failure.send_replace(Some("IRC relay action queue is full".into()));
			return Err("IRC relay action queue is full".into());
		}
		Ok(())
	}
}
pub struct Worker<C: Copy + Ord, R: Clone> {
	finished: bool,
	gateway: Rc<RefCell<Gateway<C, R>>>,
	network: String,
	tls: Option<Tls>,
	changed: watch::Receiver<()>,
	stop: watch::Receiver<bool>,
	emit: Emit<C, R>,
	notify: Rc<dyn Fn()>,
	actions: mpsc::Receiver<Batch>,
	generation: Rc<Cell<u64>>,
	failure: watch::Receiver<Option<String>>,
}
#[derive(Clone, PartialEq, Eq)]
struct Channel {
	publication: String,
	channel: String,
}
struct Live {
	connection: Connection,
	channels: BTreeMap<String, Channel>,
	timers: BTreeMap<String, (String, u64, Instant)>,
	receipts: FuturesUnordered<Receipt>,
	registered: Option<Instant>,
}

pub fn open<C: Copy + Ord, R: Clone>(
	gateway: Rc<RefCell<Gateway<C, R>>>,
	network: &str,
	tls: Option<Tls>,
	emit: impl Fn(&str, Effects<C, R>) -> Result<(), String> + 'static,
	notify: impl Fn() + 'static,
) -> Result<(Feed, Worker<C, R>), String> {
	let key = gateway
		.borrow()
		.network(network)
		.ok_or("IRC network is not configured")?
		.choice
		.key();
	let (changed, changes) = watch::channel(());
	let (stop, stopping) = watch::channel(false);
	let (actions, received) = mpsc::channel(64);
	let (failure, failed) = watch::channel(None);
	let generation = Rc::new(Cell::new(0));
	Ok((
		Feed {
			changed,
			stop,
			actions,
			generation: generation.clone(),
			failure,
		},
		Worker {
			finished: false,
			actions: received,
			generation,
			failure: failed,
			gateway,
			network: key,
			tls,
			changed: changes,
			stop: stopping,
			emit: Rc::new(emit),
			notify: Rc::new(notify),
		},
	))
}
impl<C: Copy + Ord, R: Clone> Worker<C, R> {
	pub async fn run(mut self) -> Result<(), String> {
		let result = self.drive().await;
		let cleanup = self.disconnected();
		let result = crate::cleanup::combine(result, cleanup);
		match &result {
			Ok(()) => self.status(FeedStatus::Dormant, ""),
			Err(reason) => self.status(FeedStatus::Backoff, reason),
		}
		self.finished = true;
		result
	}
	fn stopped(&self) -> bool {
		*self.stop.borrow() || self.stop.has_changed().is_err()
	}
	async fn drive(&mut self) -> Result<(), String> {
		let mut delay = Duration::from_secs(1);
		while !self.stopped() {
			if !self.has_channels() {
				self.status(FeedStatus::Dormant, "");
				tokio::select! { _ = self.stop.changed() => {}, _ = self.changed.changed() => {} }
				continue;
			}
			let choice = self
				.gateway
				.borrow()
				.network(&self.network)
				.ok_or("IRC network retired")?
				.choice
				.clone();
			let endpoint = Endpoint::new(&choice.host, choice.port, choice.tls)?;
			let (connection, worker, mut events) = Connection::open(
				endpoint,
				self.tls.clone(),
				Role::Feed,
				&choice.nick,
				&choice.realname,
				choice.sasl.as_ref().map(Into::into),
				INTERVAL,
			)?;
			self.generation.set(
				self.generation
					.get()
					.checked_add(1)
					.ok_or("IRC feed generation exhausted")?,
			);
			self.failure.borrow_and_update();
			self.status(FeedStatus::Connecting, "");
			let mut live = Live {
				connection,
				channels: BTreeMap::new(),
				timers: BTreeMap::new(),
				receipts: FuturesUnordered::new(),
				registered: None,
			};
			let work = worker.run();
			tokio::pin!(work);
			let outcome = tokio::select! {
				result = &mut work => result,
				result = self.connected(&mut live, &mut events) => {
					live.connection.stop();
					crate::cleanup::combine(result, work.await)
				}
			};
			self.disconnected()?;
			if self.stopped() {
				return Ok(());
			}
			if !self.has_channels() {
				continue;
			}
			let reason = outcome.err().unwrap_or_else(|| "IRC feed ended".into());
			self.status(FeedStatus::Backoff, &reason);
			if live
				.registered
				.is_some_and(|at| at.elapsed() >= Duration::from_secs(30))
			{
				delay = Duration::from_secs(1);
			}
			tokio::select! { _ = self.stop.changed() => {}, _ = tokio::time::sleep(delay) => {} }
			delay = (delay * 2).min(Duration::from_secs(30));
		}
		Ok(())
	}
	fn has_channels(&self) -> bool {
		self.gateway
			.borrow()
			.bridges_of(&self.network)
			.any(|(_, bridge)| !bridge.stopped)
	}
	fn current(&self, key: &str, held: &Channel) -> bool {
		self.gateway.borrow().bridge(key).is_some_and(|bridge| {
			!bridge.stopped && bridge.network == self.network && bridge.room.publication_id() == held.publication
		})
	}
	fn channels(&self) -> BTreeMap<String, Channel> {
		self.gateway
			.borrow()
			.bridges_of(&self.network)
			.filter(|(_, bridge)| !bridge.stopped)
			.map(|(key, bridge)| {
				(
					key.into(),
					Channel {
						publication: bridge.room.publication_id().into(),
						channel: bridge.room.channel().into(),
					},
				)
			})
			.collect()
	}
	fn status(&self, status: FeedStatus, problem: &str) {
		let mut gateway = self.gateway.borrow_mut();
		if let Some(network) = gateway.network_mut(&self.network) {
			network.status = status;
			network.problem = problem.into();
		}
		let keys: Vec<_> = gateway
			.bridges_of(&self.network)
			.map(|(key, _)| key.to_owned())
			.collect();
		for key in keys {
			if let Some(bridge) = gateway.bridge_mut(&key) {
				bridge.status = status;
				bridge.problem = problem.into();
			}
		}
		drop(gateway);
		(self.notify)();
	}
	fn disconnected(&self) -> Result<(), String> {
		for key in self.channels().keys() {
			let effects = self.gateway.borrow_mut().feed_disconnected(key)?;
			(self.emit)(key, effects)?;
		}
		Ok(())
	}
	async fn connected(&mut self, live: &mut Live, events: &mut Events) -> Result<(), String> {
		loop {
			if self.stopped() || !self.has_channels() {
				return Ok(());
			}
			let deadline = live.timers.values().map(|(_, _, at)| *at).min();
			tokio::select! {
				_ = self.stop.changed() => {},
				_ = self.changed.changed() => { if live.registered.is_some() { self.reconcile(live)?; } },
				_ = self.failure.changed() => {
					if let Some(reason) = self.failure.borrow().clone() { return Err(reason); }
				},
				Some(batch) = self.actions.recv() => {
					if batch.generation == self.generation.get() && live.registered.is_some()
						&& live.channels.get(&batch.key).is_some_and(|held| held.publication == batch.publication && self.current(&batch.key, held)) {
						self.actions(live, &batch.key, batch.actions)?;
					}
				},
				event = events.next() => match event {
					Some(Event::Registered { nick }) => {
						let expected = self.gateway.borrow().network(&self.network).ok_or("IRC network retired")?.choice.nick.clone();
						if let Some(reason) = rooms_application::server::irc::registration::rename_refusal(&expected, &nick) { return Err(reason); }
						live.registered = Some(Instant::now());
						self.status(FeedStatus::Up, "");
						self.reconcile(live)?;
					}
					Some(Event::Message(message)) => self.observe(live, &message)?,
					None => return Err("IRC feed event stream ended".into()),
				},
				Some(result) = live.receipts.next(), if !live.receipts.is_empty() => { result.map_err(|e| e.reason)?; },
				_ = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now)), if deadline.is_some() => self.timed_out(live)?,
			}
		}
	}
	fn send(live: &mut Live, bytes: Vec<u8>) -> Result<(), String> {
		if live.receipts.len() >= 64 {
			return Err("IRC feed write receipts exceed their budget".into());
		}
		let receipt = live.connection.write(bytes).map_err(|e| e.reason)?;
		live.receipts.push(Box::pin(receipt.wait()));
		Ok(())
	}
	fn reconcile(&self, live: &mut Live) -> Result<(), String> {
		let wanted = self.channels();
		let retired: Vec<_> = live
			.channels
			.iter()
			.filter(|(key, held)| wanted.get(*key) != Some(*held))
			.map(|(key, held)| (key.clone(), held.clone()))
			.collect();
		for (key, held) in retired {
			Self::send(live, encode("PART", &[&held.channel]).map_err(|e| e.to_string())?)?;
			live.channels.remove(&key);
			live.timers.remove(&key);
		}
		for (key, held) in wanted {
			if live.channels.contains_key(&key) {
				continue;
			}
			let actions = self
				.gateway
				.borrow_mut()
				.bridge_mut(&key)
				.ok_or("IRC channel retired")?
				.room
				.relay()
				.connected();
			live.channels.insert(key.clone(), held);
			self.actions(live, &key, actions)?;
		}
		Ok(())
	}
	fn actions(&self, live: &mut Live, key: &str, actions: Vec<Action>) -> Result<(), String> {
		for action in actions {
			match action {
				Action::Send(bytes) => Self::send(live, bytes)?,
				Action::ArmJoinTimer(generation) => {
					let Some(channel) = live.channels.get(key) else {
						continue;
					};
					live.timers.insert(
						key.into(),
						(channel.publication.clone(), generation, Instant::now() + JOIN_TIMEOUT),
					);
				}
				Action::Fail(reason) => {
					live.timers.remove(key);
					let effects = self.gateway.borrow_mut().feed_refused(key, &reason)?;
					(self.emit)(key, effects)?;
					(self.notify)();
				}
			}
		}
		Ok(())
	}
	fn observe(&self, live: &mut Live, message: &Message) -> Result<(), String> {
		let keys: Vec<_> = live.channels.keys().cloned().collect();
		for key in keys {
			if !live.channels.get(&key).is_some_and(|held| self.current(&key, held)) {
				continue;
			}
			let refusal = rooms_application::server::irc::protocol::refused_channel(message).is_some_and(|channel| {
				rooms_application::server::irc::protocol::fold(channel)
					== rooms_application::server::irc::protocol::fold(&live.channels[&key].channel)
			});
			if refusal {
				self.actions(
					live,
					&key,
					vec![Action::Fail(format!(
						"IRC refused {}: {}",
						live.channels[&key].channel,
						message.last().unwrap_or(&message.command)
					))],
				)?;
				continue;
			}
			let mut effects = self.gateway.borrow_mut().feed_observe(&key, message)?;
			self.actions(live, &key, std::mem::take(&mut effects.relay))?;
			(self.emit)(&key, effects)?;
		}
		Ok(())
	}
	fn timed_out(&self, live: &mut Live) -> Result<(), String> {
		let due: Vec<_> = live
			.timers
			.iter()
			.filter(|(_, (_, _, at))| *at <= Instant::now())
			.map(|(key, (id, generation, _))| (key.clone(), id.clone(), *generation))
			.collect();
		for (key, publication, generation) in due {
			live.timers.remove(&key);
			let actions = self
				.gateway
				.borrow_mut()
				.bridge_mut(&key)
				.filter(|bridge| bridge.room.publication_id() == publication)
				.map(|bridge| bridge.room.relay().join_timed_out(generation))
				.unwrap_or_default();
			self.actions(live, &key, actions)?;
		}
		Ok(())
	}
}

impl<C: Copy + Ord, R: Clone> Drop for Worker<C, R> {
	fn drop(&mut self) {
		if !self.finished {
			let reason = self
				.disconnected()
				.err()
				.unwrap_or_else(|| "IRC feed worker retired".into());
			self.status(FeedStatus::Backoff, &reason);
		}
	}
}
