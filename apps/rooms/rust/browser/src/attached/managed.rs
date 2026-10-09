//! Production Loam workspace on the existing continuously driven browser Host.
//! IndexedDB owns authority; JavaScript receives separate use/control handles.
mod acquisition;
mod activity;
mod bridge;
mod control;
mod directories;
mod discovery;
mod inspection;
mod observation;
mod operations;
mod outcome;
mod presence;
mod projection;
mod publication;
mod readers;
mod recovery;
mod saved;
pub(super) mod signaling;
mod uploads;
use super::{
	Environment, Result,
	driver::{Driver, Held},
	js_error, rejected, scalar,
};
use crate::{
	platform::Platform,
	storage::{Database, session},
};
pub use control::RoomsManagedControl;
use glowcap::{Argument, Ref};
use publication::PublicationHome;
use rooms_application::content::session::{custody, workspace};
use rooms_glowcap::client::{
	access::Control,
	workspace::{Acquisition, Command, Import, Workspace},
};
use rooms_runtime::session::managed::{Opened, production_limits};
use std::num::NonZeroU64;
use wasm_bindgen::prelude::*;

pub(super) struct Prepared {
	startup: session::Prepared,
	database: Database,
}
impl Prepared {
	pub async fn open(tab: &str, platform: Platform) -> Result<Self> {
		let database = Database::open().await.map_err(|e| e.to_string())?;
		let startup = session::Prepared::open(database.clone(), tab, platform)
			.await
			.map_err(|e| e.to_string())?;
		Ok(Self { startup, database })
	}
	pub fn seed(&self) -> [u8; 32] {
		self.startup.seed()
	}
}
pub(super) struct Owner {
	opened: tokio::sync::Mutex<Opened<Platform>>,
	opened_closed: std::cell::Cell<bool>,
	relay: tokio::sync::Mutex<Option<super::relay::Relay>>,
	_database: Database,
	pub(super) archive: std::rc::Rc<rooms_runtime::archive::session::SessionArchive<Platform>>,
	archive_worker: tokio::sync::Mutex<Option<tokio::task::JoinHandle<rooms_runtime::archive::session::Report>>>,
	signaling: tokio::sync::Mutex<Option<signaling::Owner>>,
	trace: std::rc::Rc<rooms_runtime::trace::Trace<Platform>>,
}
impl Owner {
	pub async fn open(environment: &Environment, prepared: Prepared) -> Result<Self> {
		let limits = production_limits().map_err(|e| e.to_string())?;
		let backend = crate::storage::PageArchive::open(environment.platform.clone())
			.await
			.map_err(|e| e.to_string())?;
		let source = backend.source().clone();
		let (archive, worker) = rooms_runtime::archive::session::SessionArchive::new(
			environment.platform.clone(),
			environment.runtime.clone(),
			backend,
		);
		let archive = std::rc::Rc::new(archive);
		let trouble = environment.trouble.clone();
		let mut opened = prepared
			.startup
			.start(
				environment.runtime.host().clone(),
				environment.platform.clone(),
				limits,
				custody::MAX_CUSTODY_FIELDS as u32,
				move |operation, error| {
					trouble.report("Session activity", &format!("{operation}: {error}"));
				},
			)
			.await
			.map_err(|e| e.to_string())?;
		let configured = opened.record_to(archive.clone(), source);
		if let Err(error) = configured {
			let closed = opened.close().await;
			return Err(match closed {
				Ok(()) => error.to_string(),
				Err(cleanup) => format!("{error}; startup cleanup: {cleanup}"),
			});
		}
		let trouble = environment.trouble.clone();
		let inputs = opened
			.workspace()
			.and_then(|workspace| opened.session().changes().map(|changes| (workspace, changes)));
		let (workspace, changes) = match inputs {
			Ok(inputs) => inputs,
			Err(error) => {
				return Err(super::retain(
					Err(error.to_string()),
					opened.close().await.map_err(|error| error.to_string()),
				)
				.unwrap_err());
			}
		};
		let trace = std::rc::Rc::new(rooms_runtime::trace::Trace::start(
			environment.platform.clone(),
			workspace,
			changes,
			std::rc::Rc::new(move |reason| trouble.report("Trace publisher", reason)),
		));
		if let Err(error) = opened.session().configure_trace(trace.clone()) {
			let cleanup = super::retain(
				trace.close().await.map_err(|error| error.to_string()),
				opened.close().await.map_err(|error| error.to_string()),
			);
			return Err(super::retain(Err(error.to_string()), cleanup).unwrap_err());
		}
		let archive_worker = tokio::task::spawn_local(worker.run());
		Ok(Self {
			opened: tokio::sync::Mutex::new(opened),
			opened_closed: std::cell::Cell::new(false),
			relay: tokio::sync::Mutex::new(None),
			_database: prepared.database,
			archive,
			archive_worker: tokio::sync::Mutex::new(Some(archive_worker)),
			signaling: tokio::sync::Mutex::new(None),
			trace,
		})
	}
	pub async fn close(&self) -> Result<()> {
		self.trace.close().await.map_err(|error| error.to_string())?;
		self.stop_signaling().await?;
		if !self.opened_closed.get() {
			let mut opened = self.opened.lock().await;
			opened.session().resume_pending().map_err(|e| e.to_string())?;
			opened.close().await.map_err(|e| e.to_string())?;
			self.opened_closed.set(true);
		}
		self.archive.close().await.map_err(|e| e.to_string())?;
		let mut worker = self.archive_worker.lock().await;
		if let Some(worker) = worker.as_mut() {
			worker.await.map_err(|e| e.to_string())?;
		}
		worker.take();
		match self.relay.lock().await.as_mut() {
			Some(relay) => relay.close().await,
			None => Ok(()),
		}
	}
	async fn stop_signaling(&self) -> Result<()> {
		let mut held = self.signaling.lock().await;
		if let Some(signaling) = held.as_ref() {
			signaling.close().await?;
		}
		held.take();
		Ok(())
	}
	async fn publish(&self, environment: &Environment, reference: &Ref) -> Result<String> {
		use rooms_glowcap::client::Deadline;
		use std::future::IntoFuture;
		let name = environment
			.platform
			.within(
				rooms_application::room::authority::REQUEST_TIMEOUT_MS,
				environment
					.runtime
					.host()
					.send(reference, "durable-name", &[])
					.into_future(),
			)
			.await
			.ok_or("Access publication did not answer")?
			.map_err(|e| e.to_string())?;
		let name = name
			.as_str()
			.filter(|name| !name.is_empty() && name.len() <= 64)
			.ok_or("Access returned no durable publication name")?;
		let locator = self.reachable(environment).await?;
		glowcap::format_sturdyref(&locator, name.as_bytes(), glowcap::CaptpVersion::V1_0).map_err(|e| e.to_string())
	}
	async fn reachable(&self, environment: &Environment) -> Result<glowcap::Locator> {
		let mut relay = self.relay.lock().await;
		if relay.is_none() {
			let front = crate::transport::WebFront::deployment().map_err(|e| e.to_string())?;
			let (locator, register) = front
				.relay_route(environment.runtime.host())
				.map_err(|e| e.to_string())?;
			*relay = Some(super::relay::Relay::start(
				environment.runtime.host(),
				environment.platform.clone(),
				locator,
				register,
				environment.incoming.admission(),
			)?);
		}
		let relay = relay.as_ref().expect("prepared publication route");
		relay.ready().await?;
		Ok(relay.locator().clone())
	}
}
fn owner(environment: &Environment) -> Result<&Owner> {
	environment
		.managed
		.as_ref()
		.ok_or_else(|| "This application has no managed workspace".into())
}
fn json(text: &str) -> Result<JsValue> {
	js_sys::JSON::parse(text).map_err(|_| "Invalid Rooms projection".into())
}
fn revision(text: &str) -> Result<u64> {
	text.parse().map_err(|_| "Invalid access revision".into())
}
fn key<K>(platform: &mut Platform) -> Result<custody::FieldKey<K>> {
	use rooms_runtime::entropy::Entropy;
	let mut bytes = [0; 16];
	platform.fill(&mut bytes).map_err(|e| e.to_string())?;
	let slot = NonZeroU64::new(u64::from_be_bytes(bytes[..8].try_into().unwrap())).ok_or("Empty custody identity")?;
	let generation =
		NonZeroU64::new(u64::from_be_bytes(bytes[8..].try_into().unwrap())).ok_or("Empty custody generation")?;
	Ok(custody::FieldKey::new(slot, generation))
}
fn coordinate<K>(role: custody::Role, key: custody::FieldKey<K>) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}

/// Opens one tab's actual Store before exposing workspace or management. This
/// front reuses Driver's input budget, stop signal, Host and local executor.
#[wasm_bindgen]
pub struct RoomsManagedApplication {
	driver: Driver,
}
#[wasm_bindgen]
impl RoomsManagedApplication {
	#[wasm_bindgen(constructor)]
	pub fn new(tab: js_sys::JsString, trouble: js_sys::Function) -> std::result::Result<Self, JsValue> {
		let tab = scalar(tab, 64).map_err(|e| js_error(&e))?;
		if tab.is_empty() || !tab.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-') {
			return Err(js_error("Invalid Rooms tab identity"));
		}
		Ok(Self {
			driver: Driver::start_managed(tab, trouble),
		})
	}
	pub fn workspace(&self) -> js_sys::Promise {
		let driver = self.driver.clone();
		self.driver.submit(0, move |environment| async move {
			let workspace = owner(&environment)?
				.opened
				.lock()
				.await
				.workspace()
				.map_err(|e| e.to_string())?;
			let workspace = driver.hold(workspace, size_of::<Workspace<Platform>>())?;
			Ok(RoomsManagedWorkspace {
				driver,
				workspace,
				home: PublicationHome::LocalOwner,
			}
			.into())
		})
	}
	pub fn management(&self) -> js_sys::Promise {
		let driver = self.driver.clone();
		self.driver.submit(0, move |environment| async move {
			let control = owner(&environment)?
				.opened
				.lock()
				.await
				.management()
				.map_err(|e| e.to_string())?;
			Ok(RoomsManagedControl::new(driver, control, PublicationHome::LocalOwner)?.into())
		})
	}
	/// Fetch an ordinary use endpoint through this Host's configured transport.
	/// A remote workspace confers no control over its managed owner.
	#[wasm_bindgen(js_name = attachWorkspace)]
	pub fn attach_workspace(&self, uri: js_sys::JsString) -> js_sys::Promise {
		let uri = match scalar(uri, 16384) {
			Ok(uri) => uri,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		self.driver.submit(uri.len(), move |environment| async move {
			use rooms_glowcap::client::Deadline;
			let host = environment.runtime.host();
			let reference = environment
				.platform
				.within(
					rooms_application::room::authority::REQUEST_TIMEOUT_MS,
					host.enliven(&uri),
				)
				.await
				.ok_or("Workspace connection timed out")?
				.map_err(|e| e.to_string())?;
			let home = PublicationHome::remote(&driver, uri)?;
			let workspace = Workspace::local(host.clone(), environment.platform.clone(), reference);
			let workspace = driver.hold(workspace, size_of::<Workspace<Platform>>())?;
			Ok(RoomsManagedWorkspace {
				driver,
				workspace,
				home,
			}
			.into())
		})
	}
	#[wasm_bindgen(js_name = attachControl)]
	pub fn attach_control(&self, uri: js_sys::JsString) -> js_sys::Promise {
		let uri = match scalar(uri, 16384) {
			Ok(uri) => uri,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		self.driver.submit(uri.len(), move |environment| async move {
			use rooms_glowcap::client::Deadline;
			let host = environment.runtime.host();
			let reference = environment
				.platform
				.within(
					rooms_application::room::authority::REQUEST_TIMEOUT_MS,
					host.enliven(&uri),
				)
				.await
				.ok_or("Control connection timed out")?
				.map_err(|e| e.to_string())?;
			let home = PublicationHome::remote(&driver, uri)?;
			RoomsManagedControl::new(
				driver,
				Control::local(host.clone(), environment.platform.clone(), reference),
				home,
			)
			.map(Into::into)
		})
	}
	#[wasm_bindgen(js_name = savedWorkspace)]
	pub fn saved_workspace(&self, id: js_sys::JsString) -> js_sys::Promise {
		let id = match scalar(id, 1024) {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		self.driver.submit(id.len(), move |environment| async move {
			let opened = owner(&environment)?.opened.lock().await;
			let snapshot = opened
				.workspace()
				.map_err(|e| e.to_string())?
				.snapshot()
				.await
				.map_err(|e| e.to_string())?;
			let selected = snapshot
				.intent
				.accesses
				.as_slice()
				.iter()
				.find(|row| row.id.text().as_str() == Some(&id))
				.and_then(|row| row.access)
				.ok_or("No held workspace access for this row")?;
			let mut held = opened
				.session()
				.restore_publication_custody(&[coordinate(custody::Role::SessionAccess, selected)])
				.await
				.map_err(|e| e.to_string())?;
			let (reference, uri) = held.remove(0);
			let home = PublicationHome::restored(&driver, uri)?;
			let workspace = Workspace::local(
				environment.runtime.host().clone(),
				environment.platform.clone(),
				reference,
			);
			let workspace = driver.hold(workspace, size_of::<Workspace<Platform>>())?;
			Ok(RoomsManagedWorkspace {
				driver,
				workspace,
				home,
			}
			.into())
		})
	}
	/// Restore exact independently saved controls through the private owner.
	/// Descriptive inventory IDs are never accepted as restoration credentials.
	#[wasm_bindgen(js_name = savedControl)]
	pub fn saved_control(&self, id: js_sys::JsString) -> js_sys::Promise {
		let id = match scalar(id, 1024) {
			Ok(id) => id,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		self.driver.submit(id.len(), move |environment| async move {
			let opened = owner(&environment)?.opened.lock().await;
			let snapshot = opened
				.workspace()
				.map_err(|e| e.to_string())?
				.snapshot()
				.await
				.map_err(|e| e.to_string())?;
			let selected = snapshot
				.intent
				.accesses
				.as_slice()
				.iter()
				.find(|row| row.id.text().as_str() == Some(&id))
				.and_then(|row| row.control)
				.ok_or("No held management control for this row")?;
			let mut held = opened
				.session()
				.restore_publication_custody(&[coordinate(custody::Role::SessionControl, selected)])
				.await
				.map_err(|e| e.to_string())?;
			let (reference, uri) = held.remove(0);
			let home = PublicationHome::restored(&driver, uri)?;
			let control = Control::local(
				environment.runtime.host().clone(),
				environment.platform.clone(),
				reference,
			);
			Ok(RoomsManagedControl::new(driver, control, home)?.into())
		})
	}
	pub fn publish(&self) -> js_sys::Promise {
		self.driver.submit(0, move |environment| async move {
			let owner = owner(&environment)?;
			let reference = owner.opened.lock().await.access().map_err(|e| e.to_string())?.clone();
			let link = owner.publish(&environment, &reference).await?;
			Ok(link.into())
		})
	}
	/// Publish this application's independently held management branch at its
	/// own relay. Foreign controls are never formatted against this local route.
	#[wasm_bindgen(js_name = publishManagement)]
	pub fn publish_management(&self) -> js_sys::Promise {
		self.driver.submit(0, move |environment| async move {
			let owner = owner(&environment)?;
			let reference = owner.opened.lock().await.control().map_err(|e| e.to_string())?.clone();
			let link = owner.publish(&environment, &reference).await?;
			Ok(link.into())
		})
	}
	pub fn close(&self) -> js_sys::Promise {
		self.driver.close()
	}
}
impl Drop for RoomsManagedApplication {
	fn drop(&mut self) {
		self.driver.stop();
	}
}

#[wasm_bindgen]
pub struct RoomsManagedWorkspace {
	driver: Driver,
	workspace: Held<Workspace<Platform>>,
	home: PublicationHome,
}
#[wasm_bindgen]
impl RoomsManagedWorkspace {
	pub fn snapshot(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		self.driver.submit(0, move |_| async move {
			let snapshot = workspace.snapshot().await.map_err(|e| e.to_string())?;
			json(
				&serde_json::json!({ "revision": snapshot.revision.to_string(), "intent": snapshot.intent })
					.to_string(),
			)
		})
	}
	#[wasm_bindgen(js_name = prepareCommand)]
	pub fn prepare_command(
		&self,
		operation: js_sys::JsString,
		base: js_sys::JsString,
		name: js_sys::JsString,
		arguments: js_sys::Array,
	) -> js_sys::Promise {
		let base = match scalar(base, 20).and_then(|text| revision(&text)) {
			Ok(base) => base,
			Err(error) => return rejected(error),
		};
		let (operation, name, arguments, bytes) = match super::command_input(operation, name, arguments) {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(bytes, move |_| async move {
			let command = workspace
				.prepare_command(&operation, base, &name, &arguments)
				.await
				.map_err(|e| e.to_string())?;
			let bytes = command.retained_bytes();
			let command = driver.hold(command, bytes)?;
			Ok(RoomsManagedCommand { driver, command }.into())
		})
	}
}

#[wasm_bindgen]
pub struct RoomsManagedCommand {
	driver: Driver,
	command: Held<Command<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedCommand {
	pub fn submit(&self) -> js_sys::Promise {
		let command = self.command.clone();
		self.driver.submit(0, move |_| async move {
			command
				.submit()
				.await
				.map(|value| format!("{value:?}").to_lowercase().into())
				.map_err(|e| e.to_string())
		})
	}
	pub fn status(&self) -> js_sys::Promise {
		let command = self.command.clone();
		self.driver.submit(0, move |_| async move {
			command
				.status()
				.await
				.map(|value| format!("{value:?}").to_lowercase().into())
				.map_err(|e| e.to_string())
		})
	}
	pub fn result(&self) -> js_sys::Promise {
		let command = self.command.clone();
		self.driver
			.submit(0, move |_| async move { outcome::result(command.result().await) })
	}
}
fn committed_data(result: &Argument) -> Result<JsValue> {
	match result {
		Argument::String(status) if matches!(status.as_str(), "unknown" | "pending" | "unsent") => {
			Err(format!("The original operation is {status}. Its receipt remains held."))
		}
		Argument::String(data) => json(data),
		Argument::List(values) if matches!(values.as_slice(), [Argument::String(_), Argument::List(_)]) => {
			json(values[0].as_str().unwrap())
		}
		_ => Err("The operation has no committed data yet".into()),
	}
}
#[wasm_bindgen]
impl RoomsManagedCommand {
	pub fn receive(&self) -> js_sys::Promise {
		let command = self.command.clone();
		self.driver.submit(0, move |_| async move {
			command
				.receive()
				.await
				.map(|status| format!("{status:?}").to_lowercase().into())
				.map_err(|e| e.to_string())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsManagedAcquisition {
	driver: Driver,
	acquisition: Held<Acquisition<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedAcquisition {
	/// Returns committed or conflict. A conflict installed no custody or content;
	/// an unknown outcome rejects and requires replay of this exact candidate.
	pub fn submit(&self) -> js_sys::Promise {
		let acquisition = self.acquisition.clone();
		self.driver.submit(
			0,
			move |_| async move { outcome::acquisition(acquisition.submit().await) },
		)
	}
}
