//! Checkpoint operations credentials become live capabilities on connected
//! directories. The reconciliation pass never waits on a peer: each fetch
//! runs as its own bounded task, while a verb that needs a capability right
//! now fetches it on the caller's own future.
use crate::Error;
use crate::directories::runtime::DirectoryRuntime;
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
use tokio::{
	sync::{Mutex, watch},
	task::JoinSet,
};

const OPERATOR: &str = "operator";
const TRACE: &str = "trace";
const PEERING: &str = "peering";
/// How long a failed fetch waits before the reconciliation pass tries again.
const RETRY: Duration = Duration::from_millis(1_000);
/// How many fetches the reconciliation pass may have in flight at once.
const MAX_IN_FLIGHT: usize = 32;

#[derive(Clone)]
pub struct Operations<P: Platform>(Rc<State<P>>);
struct State<P: Platform> {
	platform: P,
	held: RefCell<HashMap<String, Held>>,
	issues: RefCell<HashMap<String, String>>,
	retry_after: RefCell<HashMap<String, Retry<P>>>,
	/// The fetches running right now, by held key, so a pass never starts a
	/// second fetch for the same credential.
	in_flight: RefCell<HashSet<String>>,
	tasks: RefCell<JoinSet<()>>,
	dirty: watch::Sender<()>,
	notify: RefCell<Option<Notify>>,
	/// Serializes the on-demand fetches a verb makes, never the calls through
	/// a capability once held and never the reconciliation pass.
	lock: Mutex<()>,
}
impl<P: Platform> Drop for State<P> {
	fn drop(&mut self) {
		for held in self.held.borrow().values() {
			release(held);
		}
	}
}
/// Told which scope's operations view changed.
type Notify = Rc<dyn Fn(&str)>;

struct Held {
	directory_id: String,
	swiss: String,
	session: Session,
	capability: Ref,
	watch: Option<Ref>,
}
struct Live {
	session: Session,
	capability: Ref,
}
/// A failed fetch and when it may be tried again. Keyed by the credential's
/// slot but remembering its swiss, so replacing a refused credential is tried
/// at once rather than waiting out the refusal it replaced.
struct Retry<P: Platform> {
	swiss: String,
	until: Option<P::Instant>,
}
/// Releases a fetch's key when the fetch ends, however it ends, and wakes
/// the owning loop so it can act on the outcome.
struct InFlight<P: Platform> {
	owner: Operations<P>,
	key: String,
}
impl<P: Platform> Drop for InFlight<P> {
	fn drop(&mut self) {
		self.owner.0.in_flight.borrow_mut().remove(&self.key);
		self.owner.kick();
	}
}
/// Exact checkpoint authority captured before a delayed operation is admitted.
pub struct Target {
	capability: String,
	scope: String,
	swiss: String,
}
impl Target {
	pub fn capture(commands: &SessionCommands, capability: &str, scope: &str) -> Result<Self, Error> {
		commands.view().read(|state| {
			let checkpoint = state.checkpoint()?;
			let credential = checkpoint
				.operations()
				.find(|row| row.capability == capability && row.scope == scope)
				.ok_or_else(|| Error::refused(missing(capability, scope)))?;
			Ok(Self {
				capability: capability.into(),
				scope: scope.into(),
				swiss: credential.swiss.into(),
			})
		})?
	}
	fn check(&self, commands: &SessionCommands) -> Result<(), Error> {
		if intended(commands, &self.capability, &self.scope, &self.swiss) {
			Ok(())
		} else {
			Err(Error::stale("operations authority changed before dispatch"))
		}
	}
}
impl<P: Platform> Operations<P> {
	pub fn new(platform: P) -> Self {
		Self(Rc::new(State {
			platform,
			held: RefCell::new(HashMap::new()),
			issues: RefCell::new(HashMap::new()),
			retry_after: RefCell::new(HashMap::new()),
			in_flight: RefCell::new(HashSet::new()),
			tasks: RefCell::new(JoinSet::new()),
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
	pub fn issues(&self) -> Vec<(String, String)> {
		self.0
			.issues
			.borrow()
			.iter()
			.map(|(key, reason)| (format!("capability:{key}"), reason.clone()))
			.collect()
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.0.dirty.subscribe()
	}
	/// Bring the held capabilities to what the checkpoint names. Runs on every
	/// change and waits on no peer: each missing credential starts its fetch
	/// as a task, and `changes` fires when one ends.
	pub fn reconcile(&self, commands: &SessionCommands, directories: &DirectoryRuntime<P>) {
		self.reap();
		let now = self.0.platform.now();
		// Consume elapsed wakeups even when work must wait for a connection or
		// an in-flight fetch. Those owners will signal the next useful change.
		self.0
			.retry_after
			.borrow_mut()
			.retain(|_, retry| retry.until.is_none_or(|until| until > now));
		let Ok(wanted) = credentials(commands) else {
			return;
		};
		let named = |held: &String| {
			wanted
				.iter()
				.any(|(capability, scope, _)| key(capability, scope) == *held)
		};
		self.0.issues.borrow_mut().retain(|held, _| named(held));
		self.0.retry_after.borrow_mut().retain(|held, _| named(held));
		let mut scopes = Vec::new();
		self.drop_stale(&wanted, directories, &mut scopes);
		for scope in scopes {
			self.invalidated(&scope);
		}
		for (capability, scope, swiss) in wanted {
			if capability == TRACE || capability == PEERING || self.live(&capability, &scope).is_some() {
				continue;
			}
			// A directory that is not connected is this loop's own condition to
			// wait on: its change wakes the pass, so no fetch starts before it.
			let connected = Id::new(scope.clone().into()).is_some_and(|id| directories.connected(&id).is_some());
			let key = key(&capability, &scope);
			if !connected
				|| self.0.in_flight.borrow().contains(&key)
				|| self
					.0
					.retry_after
					.borrow()
					.get(&key)
					.is_some_and(|retry| retry.swiss == swiss && retry.until.is_none_or(|until| until > now))
			{
				continue;
			}
			let (this, commands, directories) = (self.clone(), commands.clone(), directories.clone());
			self.spawn(key, async move {
				// tolerant: the outcome is already recorded as the scope's
				// issue and its retry time; nothing here could act on it twice.
				let _ = this.take(&commands, &capability, &scope, &swiss, &directories).await;
			});
		}
	}
	/// The earliest moment a failed fetch may be tried again, for the loop
	/// that owns this to sleep toward.
	pub fn next_retry(&self) -> Option<P::Instant> {
		self.0
			.retry_after
			.borrow()
			.values()
			.filter_map(|retry| retry.until)
			.min()
	}
	/// One pass, then wait for the fetches it started to end, so a verb that
	/// replaced credentials answers only once each outcome is visible in the
	/// scope's issues. Bounded by each fetch's own deadline; a stop ends every
	/// fetch and so ends this wait.
	pub async fn settle(&self, commands: &SessionCommands, directories: &DirectoryRuntime<P>) {
		let mut ended = self.changes();
		self.reconcile(commands, directories);
		while !self.0.in_flight.borrow().is_empty() {
			if ended.changed().await.is_err() {
				break;
			}
		}
	}
	/// End every fetch in flight.
	pub fn stop(&self) {
		self.0.tasks.borrow_mut().abort_all();
	}
	fn spawn(&self, key: String, fetch: impl Future<Output = ()> + 'static) {
		let mut tasks = self.0.tasks.borrow_mut();
		if tasks.len() >= MAX_IN_FLIGHT || !self.0.in_flight.borrow_mut().insert(key.clone()) {
			return;
		}
		let guard = InFlight {
			owner: self.clone(),
			key,
		};
		tasks.spawn_local(async move {
			fetch.await;
			drop(guard);
		});
	}
	/// Drop the handles of finished fetches. Each installed its own outcome
	/// and released its own key before it ended.
	fn reap(&self) {
		let mut tasks = self.0.tasks.borrow_mut();
		// tolerant: a finished fetch has nothing left to report, and a
		// cancelled one was this owner's own stop.
		while tasks.try_join_next().is_some() {}
	}
	pub async fn call(
		&self,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		capability: &str,
		scope: &str,
		verb: &str,
		args: &[Argument],
	) -> Result<Argument, Error> {
		let target = Target::capture(commands, capability, scope)?;
		self.call_target(commands, directories, &target, verb, args).await
	}
	pub async fn call_target(
		&self,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		target: &Target,
		verb: &str,
		args: &[Argument],
	) -> Result<Argument, Error> {
		let capability = target.capability.as_str();
		// The lock covers taking the capability, never the call through it, so
		// one slow gateway does not hold every other scope's operator behind it.
		let live = {
			let _lock = self.0.lock.lock().await;
			target.check(commands)?;
			let live = self.ensure(commands, directories, capability, &target.scope).await?;
			target.check(commands)?;
			live
		};
		Ok(self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				live.session.send(&live.capability, verb, args).await
			})
			.await
			.ok_or_else(|| Error::closed(format!("the {capability} capability did not answer")))??)
	}
	pub fn missing(capability: &str, scope: &str) -> String {
		missing(capability, scope)
	}
	pub fn notify_scope(&self, scope: &str) {
		self.invalidated(scope);
	}
	pub async fn irc_connection(
		&self,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		target: &Target,
		connection: &str,
		verb: &str,
		args: &[Argument],
	) -> Result<Argument, Error> {
		let live = {
			let _lock = self.0.lock.lock().await;
			target.check(commands)?;
			let live = self.ensure(commands, directories, "irc", &target.scope).await?;
			target.check(commands)?;
			live
		};
		let held = self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				live.session
					.send(&live.capability, "connection", &[connection.into()])
					.await
			})
			.await
			.ok_or_else(|| Error::closed("the irc capability did not answer"))??;
		let Argument::Reference(connection) = held else {
			return Err(Error::invalid("the gateway did not return a connection capability"));
		};
		if let Err(error) = target.check(commands) {
			let _ = live.session.release(connection);
			return Err(error);
		}
		let reply = self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				live.session.send(&connection, verb, args).await
			})
			.await
			.ok_or_else(|| Error::closed(format!("the irc connection did not answer {verb}")))
			.and_then(|result| result.map_err(Error::from));
		let _ = live.session.release(connection);
		reply
	}
	fn drop_stale(
		&self,
		wanted: &[(String, String, String)],
		directories: &DirectoryRuntime<P>,
		scopes: &mut Vec<String>,
	) {
		self.0.held.borrow_mut().retain(|held_key, held| {
			let keep = !held.capability.released()
				&& wanted.iter().any(|(capability, scope, swiss)| {
					&key(capability, scope) == held_key
						&& swiss == &held.swiss
						&& directories.has_connection(&held.directory_id, &held.session)
				});
			if !keep {
				release(held);
				if !scopes.iter().any(|scope| scope == &held.directory_id) {
					scopes.push(held.directory_id.clone());
				}
			}
			keep
		});
	}
	/// Fetch one credential's capability and hold it. Both the reconciliation
	/// task and a verb's on-demand path land here; whichever installs first
	/// wins and the other keeps what is held.
	async fn take(
		&self,
		commands: &SessionCommands,
		capability: &str,
		scope: &str,
		swiss: &str,
		directories: &DirectoryRuntime<P>,
	) -> Result<(), Error> {
		let connection = Id::new(scope.to_owned().into())
			.ok_or_else(|| Error::invalid("invalid capability scope"))
			.and_then(|id| {
				directories
					.connected(&id)
					.ok_or_else(|| Error::closed("capability directory is not connected"))
			});
		let directory = match connection {
			Ok((directory, _)) => directory,
			// Nothing was asked of a peer, so nothing earns a backoff: the
			// reconciliation pass waits on the directory itself.
			Err(reason) => {
				let result = Err(reason);
				self.record(commands, capability, scope, swiss, &result);
				return result;
			}
		};
		let session = directory.client().session().borrowed();
		let fetched = self
			.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async { session.fetch(swiss).await })
			.await;
		// A late outcome has no authority over a replacement credential or
		// connection, whether it succeeded or failed.
		if !intended(commands, capability, scope, swiss) || !directories.has_connection(scope, &session) {
			return Err(Error::stale("capability intent changed during acquisition"));
		}
		let result = match (self.live(capability, scope), fetched) {
			(Some(_), _) => Ok(()),
			(None, None) => Err(Error::closed("the capability publication did not answer")),
			(None, Some(Err(error))) => Err(Error::from(error)),
			(None, Some(Ok(fetched))) => {
				let watch = if capability == OPERATOR {
					self.subscribe(&session, &fetched, scope)
				} else {
					None
				};
				self.0.held.borrow_mut().insert(
					key(capability, scope),
					Held {
						directory_id: scope.to_owned(),
						swiss: swiss.to_owned(),
						session,
						capability: fetched,
						watch,
					},
				);
				Ok(())
			}
		};
		if self.record(commands, capability, scope, swiss, &result) {
			let key = key(capability, scope);
			let mut retry_after = self.0.retry_after.borrow_mut();
			match &result {
				Ok(()) => {
					retry_after.remove(&key);
				}
				// Only failures that can clear in peer state earn another automatic fetch.
				Err(error) => {
					retry_after.insert(
						key,
						Retry {
							swiss: swiss.to_owned(),
							until: retry_delay(error).map(|delay| self.0.platform.now() + delay),
						},
					);
				}
			}
		}
		result
	}
	/// Keep the scope's issue row in step with one fetch's outcome, telling
	/// the views when it changed. Answers whether the credential is still
	/// intended, because an outcome for a retired credential records nothing.
	fn record(
		&self,
		commands: &SessionCommands,
		capability: &str,
		scope: &str,
		swiss: &str,
		result: &Result<(), Error>,
	) -> bool {
		if !intended(commands, capability, scope, swiss) {
			return false;
		}
		let key = key(capability, scope);
		let changed = {
			let mut issues = self.0.issues.borrow_mut();
			match result {
				Ok(()) => issues.remove(&key).is_some(),
				Err(reason) => {
					let retrying = retry_delay(reason).is_some();
					let reason = reason.to_string();
					let reason = rooms_application::session::diagnosis::operations(capability, &reason)
						.unwrap_or_else(|| rooms_application::failure::reason_prefix(&reason).to_owned());
					let reason = format!(
						"{reason} {}",
						if retrying {
							"Rooms will retry automatically."
						} else {
							"Automatic retries stopped. Replace this capability to try again."
						}
					);
					if issues.get(&key) == Some(&reason) {
						false
					} else {
						issues.insert(key, reason);
						true
					}
				}
			}
		};
		if changed {
			self.invalidated(scope);
		}
		true
	}
	async fn ensure(
		&self,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		capability: &str,
		scope: &str,
	) -> Result<Live, Error> {
		let wanted = credentials(commands)?;
		let mut retired = Vec::new();
		self.drop_stale(&wanted, directories, &mut retired);
		for scope in retired {
			self.invalidated(&scope);
		}
		if let Some(live) = self.live(capability, scope) {
			return Ok(live);
		}
		let swiss = wanted
			.into_iter()
			.find(|(name, held, _)| name == capability && held == scope)
			.map(|(_, _, swiss)| swiss)
			.ok_or_else(|| Error::refused(Self::missing(capability, scope)))?;
		self.take(commands, capability, scope, &swiss, directories).await?;
		self.live(capability, scope)
			.ok_or_else(|| Error::refused(Self::missing(capability, scope)))
	}
	fn live(&self, capability: &str, scope: &str) -> Option<Live> {
		self.0
			.held
			.borrow()
			.get(&key(capability, scope))
			.filter(|held| !held.capability.released())
			.map(|held| Live {
				session: held.session.borrowed(),
				capability: held.capability.clone(),
			})
	}
	fn subscribe(&self, session: &Session, capability: &Ref, scope: &str) -> Option<Ref> {
		let operations = Rc::downgrade(&self.0);
		let scope = scope.to_owned();
		let observer = session
			.spawn_owned(move |verb, _| {
				if verb != "changed" {
					return Err(Error::invalid("Rooms operator observer takes changed").into_refusal());
				}
				if let Some(operations) = operations.upgrade() {
					Operations(operations).invalidated(&scope);
				}
				Ok(Argument::Void)
			})
			.ok()?;
		let _ = session.tell(capability, "watch", &[observer.clone().into()]);
		Some(observer)
	}
	fn invalidated(&self, scope: &str) {
		if let Some(notify) = self.0.notify.borrow().clone() {
			notify(scope);
		}
	}
}
fn credentials(commands: &SessionCommands) -> Result<Vec<(String, String, String)>, Error> {
	commands.view().read(|state| {
		Ok(state
			.checkpoint()?
			.operations()
			.map(|credential| {
				(
					credential.capability.to_owned(),
					credential.scope.to_owned(),
					credential.swiss.to_owned(),
				)
			})
			.collect())
	})?
}
fn intended(commands: &SessionCommands, capability: &str, scope: &str, swiss: &str) -> bool {
	commands
		.view()
		.read(|state| {
			state.checkpoint().is_ok_and(|checkpoint| {
				checkpoint
					.operations()
					.any(|row| row.capability == capability && row.scope == scope && row.swiss == swiss)
			})
		})
		.unwrap_or(false)
}
/// The sentence a verb gets when the checkpoint holds no such credential.
fn missing(capability: &str, scope: &str) -> String {
	format!("this Rooms session has no {capability} capability for scope {scope}")
}
fn key(capability: &str, scope: &str) -> String {
	format!("{capability}\0{scope}")
}
fn release(held: &Held) {
	if let Some(watch) = &held.watch {
		let _ = held.session.tell(&held.capability, "unwatch", &[watch.clone().into()]);
	}
}

/// Peer state has no operations subscription until acquisition succeeds, so
/// state-dependent failures are polled with backoff. A request defect waits
/// for a new credential; unrelated session changes cannot restart it.
fn retry_delay(error: &Error) -> Option<Duration> {
	use rooms_application::failure::Retry;
	match error.retry() {
		Retry::Never | Retry::AfterRequestChange => None,
		Retry::Soon | Retry::AfterStateChange | Retry::AfterRequestOrStateChange => Some(RETRY),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn automatic_fetches_wait_for_peer_state_but_never_repeat_a_bad_request() {
		assert_eq!(retry_delay(&Error::refused("policy")), None);
		assert_eq!(retry_delay(&Error::invalid("credential")), None);
		assert_eq!(retry_delay(&Error::busy("pending")), Some(Duration::from_secs(1)));
		assert_eq!(
			retry_delay(&Error::storage_message("unavailable")),
			Some(Duration::from_secs(1))
		);
		assert_eq!(
			retry_delay(&Error::closed("connection lost")),
			Some(Duration::from_secs(1))
		);
	}
}
