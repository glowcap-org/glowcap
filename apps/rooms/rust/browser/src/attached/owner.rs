//! Attachment lifetime and reconnect. Only observations restart; an external
//! command is never replayed by transport recovery.
use super::{
	connections::{self, Connection},
	driver::Driver,
	observation::{Callbacks, LocalCallbacks, RemoteCallbacks, Scope},
	view, Environment, Result,
};
use crate::platform::Platform;
use glowcap::CaptpVersion;
use rooms_application::session::snapshot::Snapshot;
use rooms_glowcap::client::{session::Session, Deadline};
use std::{cell::RefCell, rc::Rc};
use tokio::sync::watch;
use wasm_bindgen::JsValue;

#[derive(Clone)]
pub(super) struct Observers {
	pub changed: js_sys::Function,
	pub event: Option<js_sys::Function>,
	pub operations: js_sys::Function,
	pub history: js_sys::Function,
}
struct Active {
	session: Session<Platform>,
	connection: Connection,
}
pub(super) struct Owner {
	pub(super) driver: Driver,
	entropy: RefCell<Platform>,
	pub commands: rooms_application::session::controller::Commands,
	pub events: super::events::Feed,
	pub history: super::observed_history::Feed,
	pub operations: super::observed_operations::Feed,
	pub drafts: RefCell<rooms_application::session::controller::drafts::Drafts>,
	pub draft_changed: tokio::sync::Notify,
	serial: tokio::sync::Mutex<()>,
	pub changed: Rc<tokio::sync::Notify>,
	active: RefCell<Option<Active>>,
	local: Option<rooms_runtime::session_service::Local<Platform>>,
	local_control: Option<super::local::Control>,
	disconnected: RefCell<Option<String>>,
	observers: RefCell<Option<Observers>>,
	pub latest: Rc<RefCell<Option<Rc<Snapshot>>>>,
	pub scope: Rc<Scope>,
	pub ended: watch::Receiver<Option<Result<()>>>,
}
impl Owner {
	pub async fn open(
		environment: Rc<Environment>,
		driver: Driver,
		scope: Rc<Scope>,
		link: String,
		home: Option<String>,
	) -> Result<Rc<Self>> {
		let active = open(&environment, &driver, &link, home.as_deref()).await?;
		let (finished, ended) = watch::channel(None);
		let owner = Self::create(&environment, &driver, scope, Some(active), None, ended);
		let running = owner.clone();
		let worker = driver.clone();
		driver.background(link.len() + home.as_ref().map_or(0, String::len), move |_| async move {
			let result = running.run(environment, worker, link, home).await;
			finished.send_replace(Some(result));
			Ok(JsValue::UNDEFINED)
		})?;
		Ok(owner)
	}
	fn create(
		environment: &Environment,
		driver: &Driver,
		scope: Rc<Scope>,
		active: Option<Active>,
		local: Option<rooms_runtime::session_service::Local<Platform>>,
		ended: watch::Receiver<Option<Result<()>>>,
	) -> Rc<Self> {
		Rc::new_cyclic(|weak| Self {
			history: super::observed_history::Feed::new(weak.clone()),
			operations: super::observed_operations::Feed::new(weak.clone()),
			driver: driver.clone(),
			entropy: RefCell::new(environment.platform.clone()),
			commands: Default::default(),
			events: Default::default(),
			drafts: RefCell::default(),
			draft_changed: Default::default(),
			serial: Default::default(),
			changed: Rc::default(),
			active: RefCell::new(active),
			local_control: local
				.as_ref()
				.and_then(|_| environment.local.as_ref().map(|owner| owner.control.clone())),
			local,
			disconnected: RefCell::default(),
			observers: RefCell::new(None),
			latest: Rc::default(),
			scope,
			ended,
		})
	}
	pub fn open_local(environment: Rc<Environment>, driver: Driver, scope: Rc<Scope>) -> Result<Rc<Self>> {
		let local = environment
			.local
			.as_ref()
			.ok_or("This application has no local Rooms session")?;
		let mut terminal = local.ended.clone();
		let (finished, ended) = watch::channel(None);
		let owner = Self::create(&environment, &driver, scope, None, Some(local.access.clone()), ended);
		let running = owner.clone();
		driver.background(0, move |_| async move {
			let result = tokio::select! { biased;
				() = running.scope.stopped() => Ok(()),
				result = connections::terminal(&mut terminal) => result,
			};
			let outcome = super::retain(result, running.retire().await);
			finished.send_replace(Some(outcome));
			Ok(JsValue::UNDEFINED)
		})?;
		Ok(owner)
	}
	pub fn recovery_key(&self) -> Result<rooms_application::directory::creation::RecoveryKey> {
		use rooms_runtime::entropy::Entropy;
		self.scope.open()?;
		let mut bytes = [0; 16];
		self.entropy.borrow_mut().fill(&mut bytes).map_err(|e| e.to_string())?;
		Ok(rooms_application::directory::creation::RecoveryKey::from_entropy(bytes))
	}
	pub fn operation_id(&self) -> Result<String> {
		self.scope.open()?;
		let id = rooms_runtime::entropy::random_id(&mut *self.entropy.borrow_mut(), "")?;
		Ok(id.text().as_str().expect("generated identifier is scalar").to_owned())
	}
	pub fn session(&self) -> Result<super::endpoint::Endpoint> {
		if let Some(local) = &self.local {
			return Ok((local.clone(), self.scope.local_observation()?).into());
		}
		self.remote_session().map(Into::into)
	}
	pub async fn verify_sibling(&self, text: String) -> Result<()> {
		self.scope.open()?;
		if let Some(control) = &self.local_control {
			return control.verify(text).await;
		}
		let session = self.remote_session()?;
		let sibling = Session::enliven(session.client().clone(), &text)
			.await
			.map_err(|e| e.to_string())?;
		sibling.snapshot().await.map_err(|e| e.to_string())?;
		self.scope.open()
	}
	pub fn remote_session(&self) -> Result<Session<Platform>> {
		self.scope.open()?;
		self.active
			.borrow()
			.as_ref()
			.map(|active| active.session.clone())
			.ok_or_else(|| "the shared Rooms session is disconnected and reconnecting".into())
	}
	pub async fn lock(&self) -> Result<tokio::sync::MutexGuard<'_, ()>> {
		tokio::select! { biased;
			() = self.scope.stopped() => Err("Rooms attachment closed while the mutation was queued".into()),
			serial = self.serial.lock() => {
				self.scope.open()?;
				Ok(serial)
			},
		}
	}
	pub fn stop(&self) {
		self.events.close();
		self.history.close();
		self.operations.close();
		self.scope.close();
	}
	pub async fn watch(self: &Rc<Self>, driver: Driver, observers: Observers) -> Result<JsValue> {
		self.scope.open()?;
		*self.observers.borrow_mut() = Some(observers.clone());
		if let Some(local) = &self.local {
			self.install_local(driver, local.clone(), observers)?;
			return self.project(None);
		}
		let (session, ended) = {
			let active = self.active.borrow();
			let active = active
				.as_ref()
				.ok_or("the shared Rooms session is disconnected and reconnecting")?;
			(active.session.clone(), active.connection.ended.clone())
		};
		self.install(driver, session, ended, observers).await?;
		self.project(None)
	}
	async fn install(
		self: &Rc<Self>,
		driver: Driver,
		session: Session<Platform>,
		mut ended: watch::Receiver<Option<Result<()>>>,
		observers: Observers,
	) -> Result<()> {
		let generation = self.scope.begin()?;
		if let Some(event) = observers.event.clone() {
			self.events.listen(Some(event))?;
		}
		let callbacks = Callbacks {
			owner: Rc::downgrade(self),
			scope: Rc::downgrade(&self.scope),
			generation,
			driver,
			latest: self.latest.clone(),
			notified: self.changed.clone(),
			operations: observers.operations,
			history: observers.history,
		};
		let (snapshot, guard) = tokio::select! {
			biased;
			() = self.scope.stopped() => return Err("Rooms attachment closed while watching".into()),
			result = connections::terminal(&mut ended) => return Err(result.err().unwrap_or_else(|| "the shared Rooms session connection closed".into())),
			result = session.watch(RemoteCallbacks { callbacks, session: session.clone() }) => result.map_err(|e| e.to_string())?,
		};
		self.scope.install(generation, guard)?;
		let mut latest = self.latest.borrow_mut();
		if latest
			.as_ref()
			.is_none_or(|old| old.revision.get() <= snapshot.revision.get())
		{
			*latest = Some(Rc::new(snapshot));
		}
		Ok(())
	}
	fn install_local(
		self: &Rc<Self>,
		driver: Driver,
		session: rooms_runtime::session_service::Local<Platform>,
		observers: Observers,
	) -> Result<()> {
		let generation = self.scope.begin()?;
		if let Some(event) = observers.event {
			self.events.listen(Some(event))?;
		}
		let callbacks = LocalCallbacks {
			callbacks: Callbacks {
				owner: Rc::downgrade(self),
				scope: Rc::downgrade(&self.scope),
				generation,
				driver,
				latest: self.latest.clone(),
				notified: self.changed.clone(),
				operations: observers.operations,
				history: observers.history,
			},
			session: session.clone(),
			source: self.operation_id()?,
			sequence: Default::default(),
		};
		let guard = Rc::new(session.observe(Rc::new(callbacks)).map_err(|e| e.to_string())?);
		let snapshot = session.snapshot().map_err(|e| e.to_string())?;
		self.scope.install_local(generation, guard)?;
		*self.latest.borrow_mut() = Some(Rc::new(snapshot));
		Ok(())
	}
	fn project(&self, disconnected: Option<&str>) -> Result<JsValue> {
		let lost = self.disconnected.borrow();
		let disconnected = disconnected.or(lost.as_deref());
		let latest = self.latest.borrow();
		let snapshot = latest
			.as_ref()
			.ok_or("the shared Rooms session has not produced a snapshot")?;
		let output = view::snapshot(snapshot)?;
		if let Some(reason) = disconnected {
			view::set(&output, "connectedDirectories", js_sys::Array::new().into())?;
			let issues = js_sys::Array::new();
			for (subject, reason) in snapshot.issues.as_slice() {
				if subject.text().as_str() == Some("session") {
					continue;
				}
				let row = js_sys::Object::new().into();
				view::set(&row, "subject", view::json(subject)?)?;
				view::set(&row, "reason", view::json(reason)?)?;
				issues.push(&row);
			}
			let row = js_sys::Object::new().into();
			view::set(&row, "subject", "session".into())?;
			view::set(&row, "reason", reason.into())?;
			issues.push(&row);
			view::set(&output, "issues", issues.into())?;
		}
		self.events.decorate(&output)?;
		Ok(output)
	}
	pub(super) fn announce(&self, disconnected: Option<&str>) -> Result<()> {
		if let Some(reason) = disconnected {
			*self.disconnected.borrow_mut() = Some(reason.to_owned());
		}
		let observer = self
			.observers
			.borrow()
			.as_ref()
			.map(|observers| observers.changed.clone());
		if let Some(changed) = observer {
			super::observation::call(&changed, self.project(disconnected)?)?;
		}
		let snapshot = self.latest.borrow().clone();
		if let Some(snapshot) = snapshot {
			self.history.observe(&snapshot)?;
			self.operations.observe(&snapshot)?;
		}
		Ok(())
	}
	async fn run(
		self: &Rc<Self>,
		environment: Rc<Environment>,
		driver: Driver,
		link: String,
		home: Option<String>,
	) -> Result<()> {
		let result = self.supervise(environment, driver, link, home).await;
		super::retain(result, self.retire().await)
	}
	async fn supervise(
		self: &Rc<Self>,
		environment: Rc<Environment>,
		driver: Driver,
		link: String,
		home: Option<String>,
	) -> Result<()> {
		let mut delay = 500;
		while self.scope.open().is_ok() {
			let ended = self
				.active
				.borrow()
				.as_ref()
				.map(|active| active.connection.ended.clone());
			if let Some(mut ended) = ended {
				let outcome = tokio::select! {
					biased;
					() = self.scope.stopped() => break,
					outcome = connections::terminal(&mut ended) => outcome,
				};
				self.active.borrow_mut().take();
				self.scope.disconnect()?;
				self.events.discard();
				self.announce(Some(
					&outcome
						.err()
						.unwrap_or_else(|| "the shared Rooms session connection closed".into()),
				))?;
			}
			tokio::select! { biased;
				() = self.scope.stopped() => break,
				() = gloo_timers::future::TimeoutFuture::new(delay) => {},
			}
			delay = (delay * 2).min(5_000);
			let attempt = async {
				let active = open(&environment, &driver, &link, home.as_deref()).await?;
				let observers = self.observers.borrow().clone();
				if let Some(observers) = observers {
					self.install(
						driver.clone(),
						active.session.clone(),
						active.connection.ended.clone(),
						observers,
					)
					.await?;
				}
				*self.active.borrow_mut() = Some(active);
				self.disconnected.borrow_mut().take();
				self.announce(None)?;
				Ok::<_, String>(())
			};
			let outcome = tokio::select! { biased;
				() = self.scope.stopped() => break,
				outcome = attempt => outcome,
			};
			match outcome {
				Ok(()) => delay = 500,
				Err(error) => {
					self.scope.disconnect()?;
					self.events.discard();
					self.announce(Some(&error))?;
				}
			}
		}
		Ok(())
	}
	async fn retire(&self) -> Result<()> {
		self.scope.close();
		self.events.close();
		self.history.close();
		self.operations.close();
		self.drafts.borrow_mut().close();
		self.draft_changed.notify_waiters();
		self.commands.close();
		// Refuse queued work, then observe the running mutation before retirement.
		let _serial = self.serial.lock().await;
		let active = self.active.borrow_mut().take();
		if let Some(active) = active {
			let Active { session, connection } = active;
			drop(session);
			return connection.client.relinquish().await.map_err(|e| e.to_string());
		}
		Ok(())
	}
}
impl Drop for Owner {
	fn drop(&mut self) {
		let driver = self.driver.clone();
		driver.with_local(|| {
			self.events.close();
			self.history.close();
			self.operations.close();
			self.scope.close();
			self.active.get_mut().take();
			self.observers.get_mut().take();
		});
	}
}

async fn open(environment: &Environment, driver: &Driver, text: &str, home: Option<&str>) -> Result<Active> {
	let work = async {
		let parsed = glowcap::parse_sturdyref(text, CaptpVersion::V1_0).map_err(|e| e.to_string())?;
		if parsed.swissnum.is_empty() {
			return Err("Rooms attachment needs a capability".into());
		}
		environment
			.signaling
			.prepare(environment, driver, &parsed.locator, home)
			.await?;
		let connection = environment.connections.connect(&parsed.locator).await?;
		let session = Session::enliven(connection.client.clone(), text)
			.await
			.map_err(|e| e.to_string())?;
		Ok(Active { session, connection })
	};
	let budget = u64::from(rooms_application::web_relay::IROH_DIAL_TIMEOUT_MS)
		+ rooms_application::signaling::TIMEOUT_MS
		+ 4 * rooms_application::room::authority::REQUEST_TIMEOUT_MS
		+ 2 * glowcap::HANDSHAKE_TIMEOUT.as_millis() as u64
		+ 15_000;
	environment
		.platform
		.within(budget, work)
		.await
		.ok_or("The shared Rooms session exceeded its staged attachment deadline.")?
}
