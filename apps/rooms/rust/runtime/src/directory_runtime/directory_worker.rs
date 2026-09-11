use super::*;
use crate::session_directory::{DirectoryConnection, DirectoryEvents, Notice, Register, Source};
use std::{
	future::{poll_fn, Future},
	task::{Context, Poll, Waker},
	time::Duration,
};

pub(super) struct Pending<P: Platform> {
	key: Rc<Generation>,
	connection: DirectoryConnection<P>,
}
pub(super) struct Stream<P: Platform> {
	key: Rc<Generation>,
	events: DirectoryEvents<P>,
}
pub struct DirectoryWorker<P: Platform> {
	pub(super) platform: P,
	pub(super) connections: crate::connections::Connections<P>,
	pub(super) commands: SessionCommands,
	pub(super) member_locator: String,
	pub(super) shared: Rc<RefCell<Directories<P>>>,
	pub(super) latest: watch::Receiver<Rc<Checkpoint>>,
	pub(super) stopping: watch::Receiver<bool>,
	pub(super) finished: watch::Sender<Option<Result<(), String>>>,
	pub(super) changed: watch::Sender<()>,
	pub(super) registration: mpsc::Sender<RegistrationWork>,
	pub(super) budget: NoticeBudget,
	pub(super) pending: Vec<Pending<P>>,
	pub(super) streams: Vec<Stream<P>>,
}
impl<P: Platform> DirectoryWorker<P> {
	/// The worker must stay owned through shutdown. Cancelling its task retires
	/// all generations and requests cancellation of every connection attempt.
	pub async fn run(mut self) -> Result<(), String> {
		let mut result = self.drive().await;
		self.shared.borrow_mut().rows.clear();
		self.streams.clear();
		for pending in &mut self.pending {
			crate::cleanup::retain(&mut result, pending.connection.close().await);
		}
		self.pending.clear();
		let staged = self.shared.borrow_mut().staged.take();
		if let Some(staged) = staged {
			let client = staged.directory.client().clone();
			drop(staged);
			crate::cleanup::retain(&mut result, client.relinquish().await.map_err(|e| e.to_string()));
		}
		if let Err(error) = &result {
			self.shared.borrow_mut().failure = Some(reason(error));
		}
		self.changed.send_replace(());
		self.finished.send_replace(Some(result.clone()));
		result
	}
	async fn drive(&mut self) -> Result<(), String> {
		self.reconcile().await?;
		loop {
			if *self.stopping.borrow() || self.stopping.has_changed().is_err() {
				return Ok(());
			}
			if self
				.latest
				.has_changed()
				.map_err(|_| "session state owner stopped".to_string())?
			{
				self.reconcile().await?;
				continue;
			}
			self.launch();
			let retry = if self.pending.len() < CONNECTING_LIMIT {
				self.shared
					.borrow()
					.rows
					.iter()
					.filter(|r| r.phase == Phase::Waiting)
					.map(|r| r.retry_at)
					.min()
			} else {
				None
			};
			let platform = self.platform.clone();
			tokio::select! {
				_ = self.stopping.changed()=>{},
				_ = self.latest.changed()=>self.reconcile().await?,
				ready=ready(&mut self.pending)=>self.connected(ready),
				event=next(&mut self.streams)=>self.receive(event).await?,
				_ = wait_retry(&platform, retry)=>{},
			}
		}
	}
	async fn reconcile(&mut self) -> Result<(), String> {
		let checkpoint = self.latest.borrow_and_update().clone();
		{
			let mut state = self.shared.borrow_mut();
			let mut old = core::mem::take(&mut state.rows);
			for intent in checkpoint.directories() {
				let prior = old
					.iter()
					.position(|r| r.wanted.id.as_ref() == intent.id)
					.map(|i| old.remove(i));
				let mut row = match prior {
					Some(row) if row.wanted.matches(intent) && row.phase != Phase::Retiring => row,
					prior => {
						let mut row = DirectoryRow::new(intent, self.platform.now());
						if let Some(mut prior) = prior {
							row.held = prior.held.take();
							row.voucher = prior
								.voucher
								.take()
								.filter(|v| Some(v.nick.as_str()) == intent.nick.text().as_str());
						}
						row
					}
				};
				if row.phase == Phase::Waiting
					&& row.held.is_none()
					&& state.staged.as_ref().is_some_and(|entry| entry.matches(intent))
				{
					let entry = state.staged.take().expect("matched staged directory");
					row.held = Some(entry.directory.clone());
				}
				state.rows.push(row);
			}
		}
		self.streams.retain(|s| s.key.scope.current());
		let mut index = 0;
		while index < self.pending.len() {
			if self.pending[index].key.scope.current() {
				index += 1;
			} else {
				// Do not release this slot until the previous attempt actually ends.
				self.pending[index].connection.close().await?;
				self.pending.remove(index);
			}
		}
		self.changed.send_replace(());
		Ok(())
	}
	fn launch(&mut self) {
		let mut started = false;
		let mut state = self.shared.borrow_mut();
		for row in &mut state.rows {
			if self.pending.len() == CONNECTING_LIMIT {
				break;
			}
			if row.phase != Phase::Waiting || row.retry_at > self.platform.now() {
				continue;
			}
			if row.held.as_ref().is_some_and(connection_ended) {
				row.held = None;
				row.granted_nick.clear();
			}
			let source = match &row.held {
				Some(directory) => Source::Adopt {
					directory: directory.clone(),
					nick: row.granted_nick.clone(),
				},
				None => Source::Dial {
					connections: self.connections.clone(),
				},
			};
			let nick = if row.granted_nick.is_empty() {
				row.wanted.nick.text().as_str().unwrap_or("")
			} else {
				&row.granted_nick
			};
			let voucher = row.voucher.as_ref().filter(|v| v.nick == nick).map(|v| v.bytes.clone());
			row.key.scope.retire();
			row.key = Generation::new(row.wanted.id.clone());
			started = true;
			match DirectoryConnection::start(
				source,
				self.commands.clone(),
				&row.wanted.id,
				Register {
					member_locator: self.member_locator.clone(),
					voucher,
				},
			) {
				Ok(connection) => {
					row.phase = Phase::Connecting;
					self.pending.push(Pending {
						key: row.key.clone(),
						connection,
					});
				}
				Err(error) => row.failed(&error, self.platform.now()),
			}
		}
		if started {
			self.changed.send_replace(());
		}
	}
	fn connected(&mut self, (index, result): (usize, Result<(), String>)) {
		let mut pending = self.pending.remove(index);
		let mut state = self.shared.borrow_mut();
		let Some(row) = state
			.rows
			.iter_mut()
			.find(|r| Rc::ptr_eq(&r.key, &pending.key) && r.key.scope.current())
		else {
			return;
		};
		match result {
			Err(error) => row.failed(&error, self.platform.now()),
			Ok(()) => {
				let (mut live, events) = pending
					.connection
					.take_ready()
					.expect("observed directory readiness")
					.into_parts();
				if let Some(bytes) = live.take_voucher() {
					row.voucher = Some(Voucher {
						nick: live.nick().into(),
						bytes,
					});
				}
				row.held = Some(live.directory().clone());
				row.live = Some(live);
				row.phase = Phase::Connected;
				row.issue = None;
				row.delay = Duration::from_secs(1);
				self.streams.push(Stream {
					key: pending.key,
					events,
				});
			}
		}
		self.changed.send_replace(());
	}
	async fn receive(&mut self, (index, result): (usize, Result<Option<Notice>, String>)) -> Result<(), String> {
		let key = self.streams[index].key.clone();
		let retired = {
			// No shared-state borrow may cross durable fact reconciliation. The
			// discovery event lands first; its derived retirement is then admitted
			// from an owned copy after this mutation boundary closes.
			let mut state = self.shared.borrow_mut();
			let Some(row) = state
				.rows
				.iter_mut()
				.find(|r| Rc::ptr_eq(&r.key, &key) && r.key.scope.current())
			else {
				self.streams.remove(index);
				return Ok(());
			};
			let mut retired = None;
			match result {
				Ok(Some(Notice::Discovery(event))) => {
					if let rooms_application::directory::Event::Member {
						kind: rooms_application::directory::MemberChange::Unregistered,
						peer,
						..
					} = &event
					{
						retired = Some(peer.clone());
					}
					if let Some(live) = &mut row.live {
						live.apply(event);
					}
				}
				Ok(Some(Notice::Registration(event))) => {
					if let Some(permit) = self.budget.reserve(&key, &event) {
						match self.registration.try_send(RegistrationWork {
							key: key.clone(),
							event,
							_permit: permit,
						}) {
							Ok(()) => {}
							Err(mpsc::error::TrySendError::Full(_)) => {
								row.failed("session direct notifications could not keep up", self.platform.now())
							}
							Err(mpsc::error::TrySendError::Closed(_)) => {
								return Err("session direct notification owner stopped".into())
							}
						}
					} else {
						row.failed("session direct notification budget is exhausted", self.platform.now());
					}
				}
				Ok(None) => row.failed("directory connection ended", self.platform.now()),
				Err(error) => row.failed(&error, self.platform.now()),
			}
			if row.phase == Phase::Waiting {
				self.streams.remove(index);
			} else {
				self.streams.rotate_left(index + 1);
			}
			self.changed.send_replace(());
			retired
		};
		if let Some(peer) = retired {
			self.retire_registration(&key, &peer).await?;
		}
		Ok(())
	}
	/// Turn an exact unregister observation into durable closed intent before
	/// consuming a later discovery event. The session worker owns storage retry;
	/// this producer keeps the stream ordered until the committed outcome is
	/// visible or this directory generation retires.
	async fn retire_registration(
		&mut self,
		key: &Rc<Generation>,
		peer: &rooms_application::directory::Member,
	) -> Result<(), String> {
		let fact = self
			.commands
			.view()
			.read(|state| {
				let checkpoint = state.checkpoint().map_err(|error| error.to_string())?;
				Ok::<_, String>(checkpoint.directs().find_map(|direct| {
					(!direct.closed
						&& direct.directory == key.id.as_ref()
						&& direct.peer.text() == peer.name.text()
						&& direct.registration.text() == &peer.registration_id)
						.then(|| Fact::DirectRegistrationRetired {
							conversation: direct.id.clone(),
							directory: direct.directory.clone(),
							peer: direct.peer.clone(),
							registration: direct.registration.clone(),
						})
				}))
			})
			.map_err(|error| error.to_string())??;
		let Some(fact) = fact else { return Ok(()) };
		let reply = loop {
			match self.commands.prepare_scoped_fact(fact.clone(), &key.scope) {
				Ok(admission) => break admission.send().map_err(|error| error.to_string())?,
				Err(crate::session_commands::AdmissionError::Retired) => return Ok(()),
				Err(crate::session_commands::AdmissionError::Full) => {
					let retry = self.platform.now() + Duration::from_millis(10);
					tokio::select! {
						_ = self.platform.sleep_until(retry) => {},
						_ = self.stopping.changed() => return Ok(()),
						_ = key.scope.retired() => return Ok(()),
					}
				}
				Err(error) => return Err(error.to_string()),
			}
		};
		let mut latest = self.latest.clone();
		let wait = reply.wait();
		tokio::pin!(wait);
		let mut waiting = true;
		loop {
			let applied = self
				.commands
				.view()
				.read(|state| {
					state.checkpoint().map(|checkpoint| {
						!checkpoint.directs().any(|direct| {
							!direct.closed
								&& direct.id
									== match &fact {
										Fact::DirectRegistrationRetired { conversation, .. } => conversation,
										_ => unreachable!("retirement fact"),
									}
						})
					})
				})
				.map_err(|error| error.to_string())?
				.map_err(|error| error.to_string())?;
			if applied || !key.scope.current() || *self.stopping.borrow() {
				return Ok(());
			}
			tokio::select! {
				result = &mut wait, if waiting => {
					waiting = false;
					if result.is_ok() { continue; }
				},
				_ = latest.changed() => {},
				_ = self.stopping.changed() => return Ok(()),
				_ = key.scope.retired() => return Ok(()),
			}
		}
	}
}
impl<P: Platform> Drop for DirectoryWorker<P> {
	fn drop(&mut self) {
		let mut state = self.shared.borrow_mut();
		state.rows.clear();
		if self.finished.borrow().is_none() {
			state.failure = Some("directory worker retired before completing shutdown".into());
			self.changed.send_replace(());
		}
	}
}
async fn ready<P: Platform>(pending: &mut [Pending<P>]) -> (usize, Result<(), String>) {
	poll_fn(|cx| {
		for (index, pending) in pending.iter_mut().enumerate() {
			let mut ready = core::pin::pin!(pending.connection.ready());
			if let Poll::Ready(result) = ready.as_mut().poll(cx) {
				return Poll::Ready((index, result.map(|_| ())));
			}
		}
		Poll::Pending
	})
	.await
}
async fn next<P: Platform>(streams: &mut [Stream<P>]) -> (usize, Result<Option<Notice>, String>) {
	poll_fn(|cx| {
		for (index, stream) in streams.iter_mut().enumerate() {
			let mut next = core::pin::pin!(stream.events.next());
			if let Poll::Ready(result) = next.as_mut().poll(cx) {
				return Poll::Ready((index, result));
			}
		}
		Poll::Pending
	})
	.await
}
fn connection_ended<P: Platform>(directory: &Directory<P>) -> bool {
	let mut closed = core::pin::pin!(directory.client().session().closed());
	closed.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_ready()
}
async fn wait_retry<P: Platform>(platform: &P, at: Option<P::Instant>) {
	match at {
		Some(at) => platform.sleep_until(at).await,
		None => core::future::pending().await,
	}
}
