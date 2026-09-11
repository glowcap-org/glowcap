//! Local signaling follows workspace registration; attached views hold their
//! own signaling registrations. Each target selects its directory explicitly.
use super::{driver::Driver, Environment, Result};
use crate::platform::Platform;
use glowcap::{DialOrigin, HintValue, Locator};
use rooms_glowcap::client::directory::Directory;
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::Rc,
};
use tokio::sync::{watch, Mutex};

type Peer = (String, String);
struct Held {
	directory: Directory<Platform>,
	incoming: super::incoming::Incoming,
}
enum Registered {
	Named(Directory<Platform>),
	Listening(Held),
}
#[derive(Default)]
struct Slot {
	held: Mutex<Option<Held>>,
	supervised: Cell<bool>,
}
pub(super) struct Signaling {
	stop: watch::Sender<bool>,
	local: RefCell<Option<rooms_runtime::directory_runtime::DirectoryRuntime<Platform>>>,
	members: RefCell<BTreeMap<String, rooms_runtime::directory_runtime::RegisteredDirectory<Platform>>>,
	directories: RefCell<BTreeMap<Peer, Rc<Slot>>>,
	routes: RefCell<BTreeMap<Peer, Directory<Platform>>>,
	changed: tokio::sync::Notify,
}
impl Default for Signaling {
	fn default() -> Self {
		Self {
			stop: watch::channel(false).0,
			local: Default::default(),
			members: Default::default(),
			directories: Default::default(),
			routes: Default::default(),
			changed: Default::default(),
		}
	}
}
fn peer(locator: &Locator) -> Peer {
	(locator.transport.clone(), locator.designator.clone())
}
impl Signaling {
	pub fn local(&self, directories: rooms_runtime::directory_runtime::DirectoryRuntime<Platform>) {
		*self.local.borrow_mut() = Some(directories);
	}
	pub fn member(&self, member: rooms_runtime::directory_runtime::RegisteredDirectory<Platform>) {
		self.members
			.borrow_mut()
			.insert(member.id().text().as_str().expect("directory authority").into(), member);
		self.changed.notify_waiters();
	}
	pub fn forget_member(&self, member: &rooms_runtime::directory_runtime::RegisteredDirectory<Platform>) {
		self.members
			.borrow_mut()
			.retain(|_, held| !held.same_generation(member));
		self.changed.notify_waiters();
	}
	pub fn select(&self, locator: &Locator, origin: &DialOrigin) -> Result<Directory<Platform>> {
		if let DialOrigin::Pending {
			introducer: Some(source),
		} = origin
		{
			if let Some(directory) = self
				.local
				.borrow()
				.as_ref()
				.and_then(|local| local.registered_from(source))
			{
				return Ok(directory);
			}
		}
		let routes = self.routes.borrow();
		let directory = match origin {
			DialOrigin::Explicit => routes.get(&peer(locator)),
			DialOrigin::Pending {
				introducer: Some(source),
			} => routes
				.values()
				.find(|directory| directory.client().session().same_session(source)),
			_ => None,
		};
		directory
			.cloned()
			.ok_or_else(|| "Rooms has no held directory for this signaling route".into())
	}
	pub async fn prepare(
		&self,
		environment: &Environment,
		driver: &Driver,
		target: &Locator,
		home: Option<&str>,
	) -> Result<()> {
		if target.transport != glowcap::TRANSPORT_WEBRTC {
			return Ok(());
		}
		let address = match target.hints.get("signaling-directory") {
			Some(HintValue::String(value)) if !value.is_empty() => value.as_str(),
			_ => home.ok_or("Rooms WebRTC attachment needs its signaling directory")?,
		};
		let locator = if address.contains("://") {
			glowcap::parse_locator(address)
		} else {
			glowcap::designator_host_port(address).map(|(host, port)| glowcap::tcp::locator(&host, port))
		}
		.map_err(|e| e.to_string())?;
		if locator.transport == glowcap::TRANSPORT_WEBRTC {
			return Err("Rooms signaling directory needs an independently reachable transport".into());
		}
		if environment.local.is_some() {
			let authority = rooms_glowcap::routes::Address::from_locator(locator.clone())
				.map_err(|e| e.to_string())?
				.authority;
			let directory = self
				.members
				.borrow()
				.get(&authority)
				.filter(|member| member.current())
				.map(|member| member.directory().clone());
			if let Some(directory) = directory {
				return self.route(target, directory);
			}

			// Reaching another tab may require a directory outside this local
			// workspace. Its signaling-only registration follows the same
			// bounded supervisor as an attached page, on this page's Host.
		}
		let slot = {
			let mut directories = self.directories.borrow_mut();
			let key = peer(&locator);
			if directories.len() >= 64 && !directories.contains_key(&key) {
				return Err("Rooms signaling directory capacity is exhausted".into());
			}
			directories.entry(key).or_default().clone()
		};
		let mut held = slot.held.lock().await;
		if held
			.as_ref()
			.is_none_or(|held| !held.directory.client().session().is_open() || held.incoming.outcome().is_err())
		{
			let replacement = match register(environment, driver, &locator).await? {
				Registered::Listening(held) => held,
				Registered::Named(directory) => {
					drop(held);
					if target.designator == environment.runtime.host().designator().map_err(|e| e.to_string())? {
						let authority = rooms_glowcap::routes::Address::from_locator(locator)
							.map_err(|e| e.to_string())?
							.authority;
						self.wait_member(&authority).await?;
					}
					return self.route(target, directory);
				}
			};
			self.replace_routes(held.as_ref(), &replacement.directory);
			*held = Some(replacement);
		}
		self.supervise(driver, slot.clone(), locator)?;
		held.as_ref()
			.expect("registered signaling directory")
			.incoming
			.outcome()?;
		self.route(
			target,
			held.as_ref().expect("registered signaling directory").directory.clone(),
		)
	}
	async fn wait_member(&self, authority: &str) -> Result<()> {
		let wait = async {
			loop {
				let changed = self.changed.notified();
				if self
					.members
					.borrow()
					.get(authority)
					.is_some_and(|member| member.current())
				{
					return;
				}
				changed.await;
			}
		};
		let mut stop = self.stop.subscribe();
		if *stop.borrow() {
			return Err("Rooms signaling has stopped".into());
		}
		tokio::select! {
			() = wait => Ok(()),
			_ = stop.changed() => Err("Rooms signaling has stopped".into()),
			() = gloo_timers::future::TimeoutFuture::new(30_000) => Err("The directory's WebRTC listener did not become ready".into()),
		}
	}
	fn supervise(&self, driver: &Driver, slot: Rc<Slot>, locator: Locator) -> Result<()> {
		if slot.supervised.get() {
			return Ok(());
		}
		let observing = slot.clone();
		let driver_owned = driver.clone();
		let mut stop = self.stop.subscribe();
		driver.background(0, move |environment| async move {
			let mut delay = 1_000;
			loop {
				if *stop.borrow() {
					break;
				}
				let mut listening = {
					let held = observing.held.lock().await;
					match held.as_ref() {
						Some(held) => held.incoming.listening(),
						None => break,
					}
				};
				tokio::select! { biased;
				 _ = stop.changed() => break,
				 _ = super::connections::terminal(&mut listening) => {},
				}
				let outcome = {
					let mut held = observing.held.lock().await;
					if *stop.borrow() {
						break;
					}
					if held
						.as_ref()
						.is_some_and(|current| !current.incoming.listening().same_channel(&listening))
					{
						continue;
					}
					match register(&environment, &driver_owned, &locator).await {
						Ok(Registered::Named(directory)) => {
							environment.signaling.replace_routes(held.as_ref(), &directory);
							held.take();
							observing.supervised.set(false);
							return Ok(wasm_bindgen::JsValue::UNDEFINED);
						}
						Ok(Registered::Listening(replacement)) => {
							environment
								.signaling
								.replace_routes(held.as_ref(), &replacement.directory);
							*held = Some(replacement);
							Ok(())
						}
						Err(error) => Err(error),
					}
				};
				match outcome {
					Ok(()) => delay = 1_000,
					Err(error) => {
						web_sys::console::error_1(&format!("Rooms signaling reconnect: {error}").into());
						tokio::select! { biased; _ = stop.changed() => break, () = gloo_timers::future::TimeoutFuture::new(delay) => {} }
						delay = (delay * 2).min(30_000);
					}
				}
			}
			observing.held.lock().await.take();
			observing.supervised.set(false);
			Ok(wasm_bindgen::JsValue::UNDEFINED)
		})?;
		slot.supervised.set(true);
		Ok(())
	}
	pub fn stop(&self) {
		self.stop.send_replace(true);
	}

	fn replace_routes(&self, prior: Option<&Held>, replacement: &Directory<Platform>) {
		if let Some(prior) = prior {
			for route in self.routes.borrow_mut().values_mut() {
				if route
					.client()
					.session()
					.same_session(prior.directory.client().session())
				{
					*route = replacement.clone();
				}
			}
		}
	}

	fn route(&self, target: &Locator, directory: Directory<Platform>) -> Result<()> {
		let mut routes = self.routes.borrow_mut();
		let key = peer(target);
		if routes.len() >= 64 && !routes.contains_key(&key) {
			return Err("Rooms signaling route capacity is exhausted".into());
		}
		routes.insert(key, directory);
		Ok(())
	}
	pub fn clear(&self) {
		self.stop();
		self.local.borrow_mut().take();
		self.members.borrow_mut().clear();
		self.routes.borrow_mut().clear();
		self.directories.borrow_mut().clear();
	}
}

fn nick_taken(error: &rooms_glowcap::client::Error) -> bool {
	use rooms_application::failure::{Failure, FailureCode};
	let rooms_glowcap::client::Error::Binding(error) = error else {
		return false;
	};
	error.kind() == glowcap::ErrorKind::Broken
		&& error.secondary_error_count() == 0
		&& error
			.message()
			.and_then(Failure::parse)
			.is_some_and(|failure| failure.code == FailureCode::NickTaken)
}

async fn register(environment: &Environment, driver: &Driver, locator: &Locator) -> Result<Registered> {
	let connection = environment.connections.connect(locator).await?;
	let directory = Directory::fetch(connection.client.clone())
		.await
		.map_err(|e| e.to_string())?;
	if directory.has_named_registration() {
		return Ok(Registered::Named(directory));
	}
	let host = environment.runtime.host();
	let key = host.designator().map_err(|e| e.to_string())?;
	let advertised = Locator::bare(glowcap::TRANSPORT_WEBRTC, &key);
	if environment.relay.is_none() {
		host.set_advertised_locator(&advertised).map_err(|e| e.to_string())?;
	}
	let advertised = glowcap::format_locator_uri(&advertised).map_err(|e| e.to_string())?;
	let mut registration = directory.signaling_registration();
	for attempt in 0..rooms_application::directory::registration::SIGNALING_NAME_ATTEMPTS {
		let nick =
			rooms_application::directory::registration::signaling_name(&key, attempt).expect("bounded name attempt");
		match registration.register(&nick, &advertised, None).await {
			Ok(_) => break,
			Err(rooms_glowcap::client::Error::Registration(
				rooms_application::directory::registration::Error::Claimed,
			)) => return Ok(Registered::Named(directory)),
			Err(error)
				if attempt + 1 < rooms_application::directory::registration::SIGNALING_NAME_ATTEMPTS
					&& nick_taken(&error) => {}
			Err(error) => return Err(error.to_string()),
		}
	}
	let incoming =
		super::incoming::Incoming::open(driver, directory.clone(), registration, environment.ice.clone()).await?;
	Ok(Registered::Listening(Held { directory, incoming }))
}
