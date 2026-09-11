//! Checkpoint peering credentials fetch DirectoryPeering and realize publication leases.
use crate::{directory_runtime::DirectoryRuntime, rooms::RoomRuntime};
use crate::{platform::Platform, session_commands::SessionCommands};
use glowcap::{Argument, Ref, Session};
use rooms_application::{room::authority::REQUEST_TIMEOUT_MS, session::checkpoint::reconciliation::Id};
use std::{
	cell::RefCell,
	collections::{HashMap, HashSet},
	rc::Rc,
	time::Duration,
};
use tokio::sync::{watch, Mutex};

const RETRY: Duration = Duration::from_millis(1_000);

#[derive(Clone)]
pub struct Peering<P: Platform>(Rc<State<P>>);
struct State<P: Platform> {
	platform: P,
	held: RefCell<HashMap<String, Held>>,
	publications: RefCell<HashMap<String, Publication>>,
	failed: RefCell<HashSet<String>>,
	retry_after: RefCell<HashMap<String, P::Instant>>,
	dirty: watch::Sender<()>,
	notify: RefCell<Option<Notify>>,
	lock: Mutex<()>,
}
/// Told which scope's operations view changed.
type Notify = Rc<dyn Fn(&str)>;

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
	lease: Option<Ref>,
	session: Session,
}
impl<P: Platform> Peering<P> {
	pub fn new(platform: P) -> Self {
		Self(Rc::new(State {
			platform,
			held: RefCell::new(HashMap::new()),
			publications: RefCell::new(HashMap::new()),
			failed: RefCell::new(HashSet::new()),
			retry_after: RefCell::new(HashMap::new()),
			dirty: watch::channel(()).0,
			notify: RefCell::new(None),
			lock: Mutex::new(()),
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
	pub fn snapshot(&self, scope: &str, commands: &SessionCommands) -> Result<Argument, String> {
		commands
			.view()
			.read(|state| {
				let checkpoint = state.checkpoint().map_err(|e| e.to_string())?;
				if !checkpoint
					.operations()
					.any(|credential| credential.capability == "peering" && credential.scope == scope)
				{
					return Err(crate::operations::Operations::<P>::missing("peering", scope));
				}
				let held = self.0.publications.borrow();
				let failed = self.0.failed.borrow();
				let rows: Vec<_> = checkpoint
					.peering()
					.filter(|peering| peering.destination == scope)
					.map(|peering| {
						let phase =
							held.get(peering.id)
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
					.map_err(|e| e.to_string())
			})
			.map_err(|e| e.to_string())?
	}
	pub async fn reconcile(
		&self,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		rooms: &RoomRuntime<P>,
	) {
		let _lock = self.0.lock.lock().await;
		let Ok(wanted) = credentials(commands) else {
			return;
		};
		self.drop_stale_caps(&wanted, directories);
		for (scope, swiss) in &wanted {
			if self.0.held.borrow().contains_key(scope) {
				continue;
			}
			if self.take(scope, swiss, directories).await.is_some() {
				self.invalidated(scope);
			}
		}
		let Ok(intents) = peering_intents(commands) else {
			return;
		};
		self.drop_stale_publications(&intents, rooms).await;
		let now = self.0.platform.now();
		for intent in intents {
			if self.0.publications.borrow().contains_key(&intent.id) {
				continue;
			}
			if self
				.0
				.retry_after
				.borrow()
				.get(&intent.id)
				.is_some_and(|until| *until > now)
			{
				continue;
			}
			self.publish(intent, commands, directories, rooms).await;
		}
	}
	async fn take(&self, scope: &str, swiss: &str, directories: &DirectoryRuntime<P>) -> Option<()> {
		let id = Id::new(scope.to_owned().into())?;
		let (directory, _) = directories.connected(&id)?;
		let session = directory.client().session().borrowed();
		let fetched = self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async { session.fetch(swiss).await })
			.await
			.and_then(Result::ok)?;
		if !directories.has_connection(scope, &session) {
			return None;
		}
		self.0.held.borrow_mut().insert(
			scope.to_owned(),
			Held {
				swiss: swiss.to_owned(),
				session,
				capability: fetched,
			},
		);
		Some(())
	}
	async fn publish(
		&self,
		intent: Intent,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		rooms: &RoomRuntime<P>,
	) {
		let Some(held) = self.live(&intent.destination) else {
			self.fail(&intent.id, Duration::ZERO);
			return;
		};
		let Ok((source_directory, room)) = rooms.source(&intent.source) else {
			self.fail(&intent.id, RETRY);
			return;
		};
		let dest_id = match Id::new(intent.destination.clone().into()) {
			Some(id) => id,
			None => {
				self.fail(&intent.id, RETRY);
				return;
			}
		};
		if directories.connected(&dest_id).is_none() {
			self.fail(&intent.id, RETRY);
			return;
		}
		let link = match room.stewardship().link().await {
			Ok(link) => link,
			Err(_) => {
				self.fail(&intent.id, RETRY);
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
				self.fail(&intent.id, RETRY);
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
						"publishDurableRoom",
						&[intent.name.clone().into(), durable.into()],
					)
					.await
			})
			.await
		{
			Some(Ok(Argument::Reference(lease))) => lease,
			_ => {
				self.fail(&intent.id, RETRY);
				return;
			}
		};
		if self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				held.session.send(&lease, "ready", &[]).await
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
					held.session.send(&lease, "revoke", &[]).await
				})
				.await;
			self.fail(&intent.id, RETRY);
			return;
		}
		if !rooms
			.source(&intent.source)
			.is_ok_and(|(id, current)| id == source_directory && Rc::ptr_eq(&current, &room))
			|| !directories.has_connection(&intent.destination, &held.session)
			|| !self.intended(commands, &intent)
		{
			// tolerant: the lease is given back on a best-effort basis; a peer
			// that does not answer keeps it until its own timeout.
			let _ = self
				.0
				.platform
				.within(REQUEST_TIMEOUT_MS, async {
					held.session.send(&lease, "revoke", &[]).await
				})
				.await;
			self.fail(&intent.id, RETRY);
			return;
		}
		self.0.failed.borrow_mut().remove(&intent.id);
		self.0.retry_after.borrow_mut().remove(&intent.id);
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
	async fn drop_stale_publications(&self, wanted: &[Intent], rooms: &RoomRuntime<P>) {
		let ids: Vec<String> = self.0.publications.borrow().keys().cloned().collect();
		for id in ids {
			let Some((matches, destination)) = self.0.publications.borrow().get(&id).map(|row| {
				let same = wanted.iter().any(|intent| {
					intent.id == id
						&& intent.destination == row.destination
						&& intent.source == row.source
						&& intent.name == row.name
						&& rooms.source(&intent.source).is_ok()
				});
				(same, row.destination.clone())
			}) else {
				continue;
			};
			if matches {
				continue;
			}
			self.revoke(&id).await;
			self.invalidated(&destination);
		}
		self.0
			.retry_after
			.borrow_mut()
			.retain(|id, _| wanted.iter().any(|intent| &intent.id == id));
		self.0
			.failed
			.borrow_mut()
			.retain(|id| wanted.iter().any(|intent| &intent.id == id));
	}
	async fn revoke(&self, id: &str) {
		let Some(mut row) = self.0.publications.borrow_mut().remove(id) else {
			return;
		};
		row.phase = "revoking";
		let Some(lease) = row.lease.take() else {
			return;
		};
		if self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				row.session.send(&lease, "revoke", &[]).await
			})
			.await
			.and_then(Result::ok)
			.is_none()
		{
			row.phase = "failed";
			row.lease = Some(lease);
			self.0.failed.borrow_mut().insert(id.to_owned());
			self.0.publications.borrow_mut().insert(id.to_owned(), row);
		}
	}
	fn release_publications(&self, scope: &str) {
		let mut retries = self.0.retry_after.borrow_mut();
		let mut failed = self.0.failed.borrow_mut();
		self.0.publications.borrow_mut().retain(|id, row| {
			if row.destination != scope {
				return true;
			}
			retries.remove(id);
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
	fn fail(&self, id: &str, after: Duration) {
		self.0.failed.borrow_mut().insert(id.to_owned());
		if !after.is_zero() {
			self.0
				.retry_after
				.borrow_mut()
				.insert(id.to_owned(), self.0.platform.now() + after);
		}
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
fn credentials(commands: &SessionCommands) -> Result<Vec<(String, String)>, String> {
	commands
		.view()
		.read(|state| {
			Ok(state
				.checkpoint()
				.map_err(|e| e.to_string())?
				.operations()
				.filter(|credential| credential.capability == "peering")
				.map(|credential| (credential.scope.to_owned(), credential.swiss.to_owned()))
				.collect())
		})
		.map_err(|e| e.to_string())?
}
fn peering_intents(commands: &SessionCommands) -> Result<Vec<Intent>, String> {
	commands
		.view()
		.read(|state| {
			Ok(state
				.checkpoint()
				.map_err(|e| e.to_string())?
				.peering()
				.map(|peering| Intent {
					id: peering.id.to_owned(),
					destination: peering.destination.to_owned(),
					source: peering.source.to_owned(),
					name: peering.name.to_owned(),
				})
				.collect())
		})
		.map_err(|e| e.to_string())?
}
impl<P: Platform> Drop for Peering<P> {
	fn drop(&mut self) {
		if Rc::strong_count(&self.0) != 1 {
			return;
		}
		self.0.held.borrow_mut().clear();
		self.0.publications.borrow_mut().clear();
	}
}
