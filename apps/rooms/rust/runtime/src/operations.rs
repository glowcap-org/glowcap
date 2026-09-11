//! Checkpoint operations credentials become live refs on connected directories.
use crate::directory_runtime::DirectoryRuntime;
use crate::{platform::Platform, session_commands::SessionCommands};
use glowcap::{Argument, Ref, Session};
use rooms_application::{room::authority::REQUEST_TIMEOUT_MS, session::checkpoint::reconciliation::Id};
use std::{cell::RefCell, collections::HashMap, rc::Rc};
use tokio::sync::{watch, Mutex};

const OPERATOR: &str = "operator";
const VIZ: &str = "viz";
const PEERING: &str = "peering";

#[derive(Clone)]
pub struct Operations<P: Platform>(Rc<State<P>>);
struct State<P: Platform> {
	platform: P,
	held: RefCell<HashMap<String, Held>>,
	issues: RefCell<HashMap<String, String>>,
	dirty: watch::Sender<()>,
	notify: RefCell<Option<Notify>>,
	lock: Mutex<()>,
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
/// Exact checkpoint authority captured before a delayed operation is admitted.
pub struct Target {
	capability: String,
	scope: String,
	swiss: String,
}
impl Target {
	pub fn capture(commands: &SessionCommands, capability: &str, scope: &str) -> Result<Self, String> {
		commands
			.view()
			.read(|state| {
				let checkpoint = state.checkpoint().map_err(|error| error.to_string())?;
				let credential = checkpoint
					.operations()
					.find(|row| row.capability == capability && row.scope == scope)
					.ok_or_else(|| format!("this Rooms session has no {capability} capability for scope {scope}"))?;
				Ok(Self {
					capability: capability.into(),
					scope: scope.into(),
					swiss: credential.swiss.into(),
				})
			})
			.map_err(|error| error.to_string())?
	}
	fn check(&self, commands: &SessionCommands) -> Result<(), String> {
		if intended(commands, &self.capability, &self.scope, &self.swiss) {
			Ok(())
		} else {
			Err("operations authority changed before dispatch".into())
		}
	}
}
impl<P: Platform> Operations<P> {
	pub fn new(platform: P) -> Self {
		Self(Rc::new(State {
			platform,
			held: RefCell::new(HashMap::new()),
			issues: RefCell::new(HashMap::new()),
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
	pub async fn reconcile(&self, commands: &SessionCommands, directories: &DirectoryRuntime<P>) {
		let _lock = self.0.lock.lock().await;
		let Ok(wanted) = credentials(commands) else {
			return;
		};
		self.0.issues.borrow_mut().retain(|held, _| {
			wanted
				.iter()
				.any(|(capability, scope, _)| key(capability, scope) == *held)
		});
		let mut scopes = Vec::new();
		self.drop_stale(&wanted, directories, &mut scopes);
		for (capability, scope, swiss) in wanted {
			if capability == VIZ || capability == PEERING {
				continue;
			}
			if self.live(&capability, &scope).is_some() {
				continue;
			}
			if self
				.take(commands, &capability, &scope, &swiss, directories)
				.await
				.is_ok()
			{
				scopes.push(scope);
			}
		}
		for scope in scopes {
			self.invalidated(&scope);
		}
	}
	pub async fn call(
		&self,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		capability: &str,
		scope: &str,
		verb: &str,
		args: &[Argument],
	) -> Result<Argument, String> {
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
	) -> Result<Argument, String> {
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
		self.0
			.platform
			.within(REQUEST_TIMEOUT_MS, async {
				live.session.send(&live.capability, verb, args).await
			})
			.await
			.ok_or_else(|| format!("the {capability} capability did not answer"))?
			.map_err(|e| e.to_string())
	}
	pub fn missing(capability: &str, scope: &str) -> String {
		format!("this Rooms session has no {capability} capability for scope {scope}")
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
	) -> Result<Argument, String> {
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
			.ok_or("the irc capability did not answer")?
			.map_err(|e| e.to_string())?;
		let Argument::Reference(connection) = held else {
			return Err("the gateway did not return a connection capability".into());
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
			.ok_or_else(|| format!("the irc connection did not answer {verb}"))
			.and_then(|result| result.map_err(|e| e.to_string()));
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
	async fn take(
		&self,
		commands: &SessionCommands,
		capability: &str,
		scope: &str,
		swiss: &str,
		directories: &DirectoryRuntime<P>,
	) -> Result<(), String> {
		let result: Result<(), String> = async {
			let id = Id::new(scope.to_owned().into()).ok_or("invalid capability scope")?;
			let (directory, _) = directories
				.connected(&id)
				.ok_or("capability directory is not connected")?;
			let session = directory.client().session().borrowed();
			let fetched = self
				.0
				.platform
				.within(REQUEST_TIMEOUT_MS, async { session.fetch(swiss).await })
				.await
				.ok_or("the capability publication did not answer")?
				.map_err(|error| error.to_string())?;
			// Acquisition cannot install authority for credentials or a directory
			// connection replaced while the publication was being fetched.
			if !intended(commands, capability, scope, swiss) || !directories.has_connection(scope, &session) {
				return Err("capability intent changed during acquisition".into());
			}
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
		.await;
		if intended(commands, capability, scope, swiss) {
			let changed = {
				let mut issues = self.0.issues.borrow_mut();
				let key = key(capability, scope);
				match &result {
					Ok(()) => issues.remove(&key).is_some(),
					Err(reason) => {
						let reason = rooms_application::session::diagnosis::operations(capability, reason)
							.unwrap_or_else(|| rooms_application::failure::reason_prefix(reason).to_owned());
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
		}
		result
	}
	async fn ensure(
		&self,
		commands: &SessionCommands,
		directories: &DirectoryRuntime<P>,
		capability: &str,
		scope: &str,
	) -> Result<Live, String> {
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
			.ok_or_else(|| Self::missing(capability, scope))?;
		self.take(commands, capability, scope, &swiss, directories).await?;
		self.live(capability, scope)
			.ok_or_else(|| Self::missing(capability, scope))
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
					return Err("Rooms operator observer takes changed".into());
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
fn credentials(commands: &SessionCommands) -> Result<Vec<(String, String, String)>, String> {
	commands
		.view()
		.read(|state| {
			Ok(state
				.checkpoint()
				.map_err(|e| e.to_string())?
				.operations()
				.map(|credential| {
					(
						credential.capability.to_owned(),
						credential.scope.to_owned(),
						credential.swiss.to_owned(),
					)
				})
				.collect())
		})
		.map_err(|e| e.to_string())?
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
fn key(capability: &str, scope: &str) -> String {
	format!("{capability}\0{scope}")
}
fn release(held: &Held) {
	if let Some(watch) = &held.watch {
		let _ = held.session.tell(&held.capability, "unwatch", &[watch.clone().into()]);
	}
}
impl<P: Platform> Drop for Operations<P> {
	fn drop(&mut self) {
		if Rc::strong_count(&self.0) != 1 {
			return;
		}
		for held in self.0.held.borrow().values() {
			release(held);
		}
	}
}
