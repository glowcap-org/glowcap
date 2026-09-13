//! Local signaling follows workspace registration; attached views hold their
//! own signaling registrations. Each target selects its directory explicitly.
use super::{Environment, Result, driver::Driver};
use crate::platform::Platform;
use glowcap::{DialOrigin, HintValue, Locator};
use rooms_glowcap::client::directory::Directory;
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::{Rc, Weak},
};
use tokio::sync::{Mutex, watch};

type Peer = (String, String);
struct Held {
	directory: Directory<Platform>,
	incoming: super::incoming::Incoming,
}
enum Registered {
	Named(Directory<Platform>),
	Listening(Held),
}
struct Slot {
	held: Mutex<Option<Held>>,
	supervised: Cell<bool>,
	users: Cell<usize>,
	retire: watch::Sender<bool>,
}
impl Default for Slot {
	fn default() -> Self {
		Self {
			held: Default::default(),
			supervised: Cell::new(false),
			users: Cell::new(0),
			retire: watch::channel(false).0,
		}
	}
}
struct RouteEntry {
	directory: Directory<Platform>,
	users: usize,
	generation: u64,
}
struct DirectoryLease {
	owner: Weak<Signaling>,
	key: Peer,
	slot: Rc<Slot>,
}
impl Drop for DirectoryLease {
	fn drop(&mut self) {
		self.slot.users.set(self.slot.users.get() - 1);
		if self.slot.users.get() == 0 {
			if let Some(owner) = self.owner.upgrade() {
				owner.retire_directory(&self.key, &self.slot);
			}
		}
	}
}
pub(super) struct RouteLease {
	owner: Weak<Signaling>,
	target: Peer,
	generation: u64,
	_directory: Option<DirectoryLease>,
}
impl Drop for RouteLease {
	fn drop(&mut self) {
		if let Some(owner) = self.owner.upgrade() {
			owner.release(&self.target, self.generation);
		}
	}
}
pub(super) struct Signaling {
	stop: watch::Sender<bool>,
	local: RefCell<Option<rooms_runtime::directories::runtime::DirectoryRuntime<Platform>>>,
	members: RefCell<BTreeMap<String, rooms_runtime::directories::runtime::RegisteredDirectory<Platform>>>,
	directories: RefCell<BTreeMap<Peer, Rc<Slot>>>,
	routes: RefCell<BTreeMap<Peer, RouteEntry>>,
	next_generation: Cell<u64>,
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
			next_generation: Cell::new(0),
			changed: Default::default(),
		}
	}
}
fn peer(locator: &Locator) -> Peer {
	(locator.transport.clone(), locator.designator.clone())
}
impl Signaling {
	pub fn local(&self, directories: rooms_runtime::directories::runtime::DirectoryRuntime<Platform>) {
		*self.local.borrow_mut() = Some(directories);
	}
	pub fn member(&self, member: rooms_runtime::directories::runtime::RegisteredDirectory<Platform>) {
		self.members
			.borrow_mut()
			.insert(member.id().text().as_str().expect("directory authority").into(), member);
		self.changed.notify_waiters();
	}
	pub fn forget_member(&self, member: &rooms_runtime::directories::runtime::RegisteredDirectory<Platform>) {
		self.members
			.borrow_mut()
			.retain(|_, held| !held.same_generation(member));
		let session = member.directory().client().session();
		self.routes
			.borrow_mut()
			.retain(|_, route| !route.directory.client().session().same_session(session));
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
			DialOrigin::Explicit => routes.get(&peer(locator)).map(|route| &route.directory),
			DialOrigin::Pending {
				introducer: Some(source),
			} => routes
				.values()
				.map(|route| &route.directory)
				.find(|directory| directory.client().session().same_session(source)),
			_ => None,
		};
		directory
			.cloned()
			.ok_or_else(|| "Rooms has no held directory for this signaling route".into())
	}
	pub async fn prepare(
		self: &Rc<Self>,
		environment: &Environment,
		driver: &Driver,
		target: &Locator,
		home: Option<&str>,
	) -> Result<Option<RouteLease>> {
		if target.transport != glowcap::TRANSPORT_WEBRTC {
			return Ok(None);
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
				return self.route(target, directory, None).map(Some);
			}

			// Reaching another tab may require a directory outside this local
			// workspace. Its signaling-only registration follows the same
			// bounded supervisor as an attached page, on this page's Host.
		}
		let directory_key = peer(&locator);
		let (slot, directory_lease) = {
			let mut directories = self.directories.borrow_mut();
			if directories.len() >= 64 && !directories.contains_key(&directory_key) {
				return Err("Rooms signaling directory capacity is exhausted".into());
			}
			let slot = directories.entry(directory_key.clone()).or_default().clone();
			slot.users.set(slot.users.get() + 1);
			let lease = DirectoryLease {
				owner: Rc::downgrade(self),
				key: directory_key,
				slot: slot.clone(),
			};
			(slot, lease)
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
					return self.route(target, directory, None).map(Some);
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
			Some(directory_lease),
		)
		.map(Some)
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
		let mut retiring = slot.retire.subscribe();
		driver.background(0, move |environment| async move {
			let mut delay = 1_000;
			loop {
				if *stop.borrow() || *retiring.borrow() {
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
				 _ = retiring.changed() => break,
				 _ = super::connections::settled(&mut listening) => {},
				}
				let outcome = {
					let mut held = observing.held.lock().await;
					if *stop.borrow() || *retiring.borrow() {
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
						environment.trouble.report("WebRTC signaling directory", &error);
						tokio::select! { biased; _ = stop.changed() => break, _ = retiring.changed() => break, () = gloo_timers::future::TimeoutFuture::new(delay) => {} }
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
					.directory
					.client()
					.session()
					.same_session(prior.directory.client().session())
				{
					route.directory = replacement.clone();
				}
			}
		}
	}

	fn route(
		self: &Rc<Self>,
		target: &Locator,
		directory: Directory<Platform>,
		directory_lease: Option<DirectoryLease>,
	) -> Result<RouteLease> {
		let mut routes = self.routes.borrow_mut();
		let key = peer(target);
		if routes.len() >= 64 && !routes.contains_key(&key) {
			return Err("Rooms signaling route capacity is exhausted".into());
		}
		let generation = match routes.get_mut(&key) {
			Some(route) => {
				route.directory = directory;
				route.users += 1;
				route.generation
			}
			None => {
				let generation = self.next_generation.get();
				self.next_generation.set(generation.wrapping_add(1));
				routes.insert(
					key.clone(),
					RouteEntry {
						directory,
						users: 1,
						generation,
					},
				);
				generation
			}
		};
		Ok(RouteLease {
			owner: Rc::downgrade(self),
			target: key,
			generation,
			_directory: directory_lease,
		})
	}
	fn release(&self, target: &Peer, generation: u64) {
		let mut routes = self.routes.borrow_mut();
		let remove = match routes.get_mut(target) {
			Some(route) if route.generation == generation && route.users > 1 => {
				route.users -= 1;
				false
			}
			Some(route) if route.generation == generation => true,
			_ => false,
		};
		if remove {
			routes.remove(target);
		}
	}
	fn retire_directory(&self, key: &Peer, slot: &Rc<Slot>) {
		let mut directories = self.directories.borrow_mut();
		if directories.get(key).is_some_and(|current| Rc::ptr_eq(current, slot)) {
			directories.remove(key);
			slot.retire.send_replace(true);
		}
	}
	pub fn clear(&self) {
		self.stop();
		self.local.borrow_mut().take();
		self.members.borrow_mut().clear();
		self.routes.borrow_mut().clear();
		for (_, slot) in std::mem::take(&mut *self.directories.borrow_mut()) {
			slot.retire.send_replace(true);
		}
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
	let connection = environment
		.connections
		.connect(locator)
		.await
		.map_err(|e| e.to_string())?;
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
