//! Checkpoint peering credentials become live capabilities on connected
//! directories, and each peering intent becomes a room published there under
//! a lease. Every exchange with a directory runs as its own bounded task, so
//! one slow peer holds back only its own intent, never the loop that owns
//! them all.
use crate::{Error, directories::runtime::DirectoryRuntime, rooms::RoomRuntime};
use crate::{platform::Platform, session::commands::SessionCommands};
use glowcap::{Argument, Ref, Session};
use rooms_application::{room::authority::REQUEST_TIMEOUT_MS, session::checkpoint::reconciliation::Id};
use std::{
	cell::RefCell,
	collections::{HashMap, HashSet},
	future::Future,
	rc::Rc,
	time::Duration,
};
use tokio::{sync::watch, task::JoinSet};

/// How long a failed exchange waits before it is tried again.
const RETRY: Duration = Duration::from_millis(1_000);
/// How many exchanges may run at once. The rest start as these finish.
const MAX_IN_FLIGHT: usize = 32;

#[derive(Clone)]
pub struct Peering<P: Platform>(Rc<State<P>>);
struct State<P: Platform> {
	platform: P,
	held: RefCell<HashMap<String, Held>>,
	publications: RefCell<HashMap<String, Publication>>,
	failed: RefCell<HashSet<String>>,
	retry_after: RefCell<HashMap<Work, P::Instant>>,
	/// The exchanges running right now, named by their effect, so a pass never
	/// starts a second one for the same thing.
	in_flight: RefCell<HashSet<Work>>,
	tasks: RefCell<JoinSet<()>>,
	dirty: watch::Sender<()>,
	notify: RefCell<Option<Notify>>,
}
/// Told which scope's operations view changed.
type Notify = Rc<dyn Fn(&str)>;

/// One exchange with a directory, named by what it installs or removes.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Work {
	/// Fetch the peering capability a credential names, by its scope.
	Credential(String),
	/// Publish one intent, by its id.
	Publication(String),
	/// Give back one published intent's lease, by its id.
	Revocation(String),
}

struct Held {
	swiss: String,
	session: Session,
	capability: Ref,
}
struct Publication {
	destination: String,
	source: String,
	name: String,
	phase: &'static str,
	/// Absent while a revocation is in flight with the lease.
	lease: Option<Ref>,
	session: Session,
}
/// Releases an exchange's name when the exchange ends, however it ends, and
/// wakes the owning loop so it can start what that name was holding back.
struct InFlight<P: Platform> {
	owner: Peering<P>,
	work: Work,
}
impl<P: Platform> Drop for InFlight<P> {
	fn drop(&mut self) {
		self.owner.0.in_flight.borrow_mut().remove(&self.work);
		self.owner.kick();
	}
}
impl<P: Platform> Peering<P> {
	pub fn new(platform: P) -> Self {
		Self(Rc::new(State {
			platform,
			held: RefCell::new(HashMap::new()),
			publications: RefCell::new(HashMap::new()),
			failed: RefCell::new(HashSet::new()),
			retry_after: RefCell::new(HashMap::new()),
			in_flight: RefCell::new(HashSet::new()),
			tasks: RefCell::new(JoinSet::new()),
			dirty: watch::channel(()).0,
			notify: RefCell::new(None),
		}))
	}
	pub fn on_invalidated(&self, notify: Notify) {
		*self.0.notify.borrow_mut() = Some(notify);
	}
	pub fn kick(&self) {
		self.0.dirty.send_replace(());
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.0.dirty.subscribe()
	}
	pub fn snapshot(&self, scope: &str, commands: &SessionCommands) -> Result<Argument, Error> {
		commands.view().read(|state| {
			let checkpoint = state.checkpoint()?;
			if !checkpoint
				.operations()
				.any(|credential| credential.capability == "peering" && credential.scope == scope)
			{
				return Err(Error::refused(crate::rooms::operations::Operations::<P>::missing(
					"peering", scope,
				)));
			}
			let held = self.0.publications.borrow();
			let failed = self.0.failed.borrow();
			let rows: Vec<_> = checkpoint
				.peering()
				.filter(|peering| peering.destination == scope)
				.map(|peering| {
					let phase = held
						.get(peering.id)
						.map(|row| row.phase)
						.unwrap_or(if failed.contains(peering.id) {
							"failed"
						} else {
							"publishing"
						});
					serde_json::json!({
						"id": peering.id,
						"name": peering.name,
						"source": peering.source,
						"phase": phase,
					})
				})
				.collect();
			serde_json::to_string(&rows)
				.map(Argument::String)
				.map_err(Error::invalid_by)
		})?
	}
	/// Bring the held capabilities and published leases to what the checkpoint
	/// wants. Runs on every change and waits on no peer: each missing piece
	/// starts as a task, and `changes` fires when one ends.
	pub fn reconcile(&self, commands: &SessionCommands, directories: &DirectoryRuntime<P>, rooms: &RoomRuntime<P>) {
		self.reap();
		let now = self.0.platform.now();
		// A due exchange now waits on its task or dependency, not an elapsed timer.
		self.0.retry_after.borrow_mut().retain(|_, until| *until > now);
		let Ok(wanted) = credentials(commands) else {
			return;
		};
		self.drop_stale_caps(&wanted, directories);
		for (scope, swiss) in &wanted {
			if self.0.held.borrow().contains_key(scope) {
				continue;
			}
			let work = Work::Credential(scope.clone());
			if self.waiting(&work, now) {
				continue;
			}
			let (this, scope, swiss, directories) = (self.clone(), scope.clone(), swiss.clone(), directories.clone());
			self.spawn(work, async move { this.take(&scope, &swiss, &directories).await });
		}
		let Ok(intents) = peering_intents(commands) else {
			return;
		};
		self.drop_stale_publications(&intents, rooms);
		self.0.retry_after.borrow_mut().retain(|work, _| match work {
			Work::Credential(scope) => wanted.iter().any(|(wanted, _)| wanted == scope),
			Work::Publication(id) => intents.iter().any(|intent| &intent.id == id),
			Work::Revocation(id) => self.0.publications.borrow().contains_key(id),
		});
		for intent in intents {
			if self.0.publications.borrow().contains_key(&intent.id) {
				continue;
			}
			let work = Work::Publication(intent.id.clone());
			if self.waiting(&work, now) {
				continue;
			}
			// Without the destination's capability there is nothing to publish
			// through; the credential's own exchange wakes this pass when it lands.
			if !self.0.held.borrow().contains_key(&intent.destination) {
				self.0.failed.borrow_mut().insert(intent.id.clone());
				continue;
			}
			let (this, commands, directories, rooms) =
				(self.clone(), commands.clone(), directories.clone(), rooms.clone());
			self.spawn(work, async move {
				this.publish(intent, &commands, &directories, &rooms).await;
			});
		}
	}
	/// The earliest moment a failed exchange may be tried again, for the loop
	/// that owns this to sleep toward.
	pub fn next_retry(&self) -> Option<P::Instant> {
		self.0.retry_after.borrow().values().copied().min()
	}
	/// End every exchange in flight. A lease already granted but not yet
	/// installed stays with its directory until that peer's own timeout.
	pub fn stop(&self) {
		self.0.tasks.borrow_mut().abort_all();
	}
	fn waiting(&self, work: &Work, now: P::Instant) -> bool {
		self.0.in_flight.borrow().contains(work)
			|| self.0.retry_after.borrow().get(work).is_some_and(|until| *until > now)
	}
	fn spawn(&self, work: Work, exchange: impl Future<Output = ()> + 'static) {
		let mut tasks = self.0.tasks.borrow_mut();
		if tasks.len() >= MAX_IN_FLIGHT || !self.0.in_flight.borrow_mut().insert(work.clone()) {
			return;
		}
		let guard = InFlight {
			owner: self.clone(),
			work,
		};
		tasks.spawn_local(async move {
			exchange.await;
			drop(guard);
		});
	}
	/// Drop the handles of finished exchanges. Each installed its own outcome
	/// and released its own name before it ended.
	fn reap(&self) {
		let mut tasks = self.0.tasks.borrow_mut();
		// tolerant: a finished exchange has nothing left to report, and a
		// cancelled one was this owner's own stop.
		while tasks.try_join_next().is_some() {}
	}
	async fn take(&self, scope: &str, swiss: &str, directories: &DirectoryRuntime<P>) {
		let fetched = async {
			let id = Id::new(scope.to_owned().into())?;
			let (directory, _) = directories.connected(&id)?;
			let session = directory.client().session().borrowed();
			let capability = self
				.0
				.platform
				.within(REQUEST_TIMEOUT_MS, async { session.fetch(swiss).await })
				.await
				.and_then(Result::ok)?;
			directories
				.has_connection(scope, &session)
				.then_some((session, capability))
		}
		.await;
		let Some((session, capability)) = fetched else {
			self.fail(Work::Credential(scope.to_owned()));
			return;
		};
		// The on-demand path may have installed the same credential meanwhile.
		if self.0.held.borrow().contains_key(scope) {
			return;
		}
		self.0.held.borrow_mut().insert(
			scope.to_owned(),
			Held {
				swiss: swiss.to_owned(),
				session,
				capability,
			},
		);
		self.invalidated(scope);
	}
	async fn publish(
		&self,
		intent: Intent,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		rooms: &RoomRuntime<P>,
	) {
		let work = Work::Publication(intent.id.clone());
		let Some(held) = self.live(&intent.destination) else {
			self.fail(work);
			return;
		};
		let Ok((source_directory, room)) = rooms.source(&intent.source) else {
			self.fail(work);
			return;
		};
		let dest_id = match Id::new(intent.destination.clone().into()) {
			Some(id) => id,
			None => {
				self.fail(work);
				return;
			}
		};
		if directories.connected(&dest_id).is_none() {
			self.fail(work);
			return;
		}
		let link = match room.stewardship().link().await {
			Ok(link) => link,
			Err(_) => {
				self.fail(work);
				return;
			}
		};
		let source_session = room.client().session().borrowed();
		let durable = match self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async { source_session.enliven(&link).await })
			.await
		{
			Some(Ok(durable)) => durable,
			_ => {
				self.fail(work);
				return;
			}
		};
		let lease = match self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				held.session
					.send(
						&held.capability,
						rooms_application::protocol_data::PUBLISH_DURABLE_ROOM,
						&[intent.name.clone().into(), durable.into()],
					)
					.await
			})
			.await
		{
			Some(Ok(Argument::Reference(lease))) => lease,
			_ => {
				self.fail(work);
				return;
			}
		};
		if self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				held.session
					.send(&lease, rooms_application::protocol_data::PUBLICATION_READY, &[])
					.await
			})
			.await
			.and_then(Result::ok)
			.is_none()
		{
			// tolerant: the lease is given back on a best-effort basis; a peer
			// that does not answer keeps it until its own timeout.
			let _ = self
				.0
				.platform
				.within(REQUEST_TIMEOUT_MS, async {
					held.session
						.send(&lease, rooms_application::protocol_data::REVOKE, &[])
						.await
				})
				.await;
			self.fail(work);
			return;
		}
		if !rooms
			.source(&intent.source)
			.is_ok_and(|(id, current)| id == source_directory && Rc::ptr_eq(&current, &room))
			|| !directories.has_connection(&intent.destination, &held.session)
			|| !self.intended(commands, &intent)
			|| self.0.publications.borrow().contains_key(&intent.id)
		{
			// tolerant: the lease is given back on a best-effort basis; a peer
			// that does not answer keeps it until its own timeout.
			let _ = self
				.0
				.platform
				.within(REQUEST_TIMEOUT_MS, async {
					held.session
						.send(&lease, rooms_application::protocol_data::REVOKE, &[])
						.await
				})
				.await;
			self.fail(work);
			return;
		}
		self.0.failed.borrow_mut().remove(&intent.id);
		self.0.retry_after.borrow_mut().remove(&work);
		self.0.publications.borrow_mut().insert(
			intent.id.clone(),
			Publication {
				destination: intent.destination.clone(),
				source: intent.source,
				name: intent.name,
				phase: "live",
				lease: Some(lease),
				session: held.session,
			},
		);
		self.invalidated(&intent.destination);
	}
	fn live(&self, scope: &str) -> Option<HeldLive> {
		self.0.held.borrow().get(scope).map(|held| HeldLive {
			session: held.session.borrowed(),
			capability: held.capability.clone(),
		})
	}
	fn drop_stale_caps(&self, wanted: &[(String, String)], directories: &DirectoryRuntime<P>) {
		let mut scopes = Vec::new();
		self.0.held.borrow_mut().retain(|scope, held| {
			let keep = wanted.iter().any(|(wanted_scope, swiss)| {
				wanted_scope == scope && swiss == &held.swiss && directories.has_connection(scope, &held.session)
			});
			if !keep {
				scopes.push(scope.clone());
			}
			keep
		});
		for scope in scopes {
			self.release_publications(&scope);
			self.invalidated(&scope);
		}
	}
	/// Start giving back every lease the checkpoint no longer intends. The row
	/// stays, marked revoking, until the peer answers, so the same id is not
	/// published again underneath it.
	fn drop_stale_publications(&self, wanted: &[Intent], rooms: &RoomRuntime<P>) {
		let stale: Vec<(String, String, Option<Ref>, Session)> = {
			let mut publications = self.0.publications.borrow_mut();
			publications
				.iter_mut()
				.filter(|(id, row)| {
					row.lease.is_some()
						&& !wanted.iter().any(|intent| {
							&intent.id == *id
								&& intent.destination == row.destination
								&& intent.source == row.source
								&& intent.name == row.name
								&& rooms.source(&intent.source).is_ok()
						})
				})
				.map(|(id, row)| {
					row.phase = "revoking";
					(
						id.clone(),
						row.destination.clone(),
						row.lease.take(),
						row.session.borrowed(),
					)
				})
				.collect()
		};
		for (id, destination, lease, session) in stale {
			let Some(lease) = lease else { continue };
			let work = Work::Revocation(id.clone());
			if self.waiting(&work, self.0.platform.now()) {
				continue;
			}
			let this = self.clone();
			self.spawn(work, async move { this.revoke(id, lease, session).await });
			self.invalidated(&destination);
		}
		self.0
			.failed
			.borrow_mut()
			.retain(|id| wanted.iter().any(|intent| &intent.id == id));
	}
	async fn revoke(&self, id: String, lease: Ref, session: Session) {
		let revoked = self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				session
					.send(&lease, rooms_application::protocol_data::REVOKE, &[])
					.await
			})
			.await
			.and_then(Result::ok)
			.is_some();
		let destination = {
			let mut publications = self.0.publications.borrow_mut();
			if revoked {
				publications.remove(&id).map(|row| row.destination)
			} else if let Some(row) = publications.get_mut(&id) {
				row.phase = "failed";
				row.lease = Some(lease);
				self.0.failed.borrow_mut().insert(id.clone());
				self.fail(Work::Revocation(id.clone()));
				Some(row.destination.clone())
			} else {
				None
			}
		};
		if let Some(destination) = destination {
			self.invalidated(&destination);
		}
	}
	fn release_publications(&self, scope: &str) {
		let mut retries = self.0.retry_after.borrow_mut();
		let mut failed = self.0.failed.borrow_mut();
		self.0.publications.borrow_mut().retain(|id, row| {
			if row.destination != scope {
				return true;
			}
			retries.remove(&Work::Publication(id.clone()));
			retries.remove(&Work::Revocation(id.clone()));
			failed.remove(id);
			false
		});
	}
	fn intended(&self, commands: &SessionCommands, intent: &Intent) -> bool {
		let held = self.0.held.borrow();
		let Some(held) = held.get(&intent.destination) else {
			return false;
		};
		commands
			.view()
			.read(|state| {
				let Ok(checkpoint) = state.checkpoint() else {
					return false;
				};
				checkpoint.operations().any(|credential| {
					credential.capability == "peering"
						&& credential.scope == intent.destination
						&& credential.swiss == held.swiss
				}) && checkpoint.peering().any(|current| {
					current.id == intent.id
						&& current.source == intent.source
						&& current.destination == intent.destination
						&& current.name == intent.name
				})
			})
			.unwrap_or(false)
	}
	/// Record a failed exchange and the moment it may be tried again.
	fn fail(&self, work: Work) {
		if let Work::Publication(id) = &work {
			self.0.failed.borrow_mut().insert(id.clone());
		}
		self.0
			.retry_after
			.borrow_mut()
			.insert(work, self.0.platform.now() + RETRY);
	}
	fn invalidated(&self, scope: &str) {
		if let Some(notify) = self.0.notify.borrow().clone() {
			notify(scope);
		}
	}
}
struct HeldLive {
	session: Session,
	capability: Ref,
}
#[derive(Clone)]
struct Intent {
	id: String,
	destination: String,
	source: String,
	name: String,
}
fn credentials(commands: &SessionCommands) -> Result<Vec<(String, String)>, Error> {
	commands.view().read(|state| {
		Ok(state
			.checkpoint()?
			.operations()
			.filter(|credential| credential.capability == "peering")
			.map(|credential| (credential.scope.to_owned(), credential.swiss.to_owned()))
			.collect())
	})?
}
fn peering_intents(commands: &SessionCommands) -> Result<Vec<Intent>, Error> {
	commands.view().read(|state| {
		Ok(state
			.checkpoint()?
			.peering()
			.map(|peering| Intent {
				id: peering.id.to_owned(),
				destination: peering.destination.to_owned(),
				source: peering.source.to_owned(),
				name: peering.name.to_owned(),
			})
			.collect())
	})?
}
