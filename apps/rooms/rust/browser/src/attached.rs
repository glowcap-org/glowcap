//! Browser attachment composition used by the production attached page.
//! The Host, typed session clients and file sources share one local executor.
mod actions;
mod browser_data;
mod connections;
mod direct_gestures;
mod directory_reach;
mod drafts;
mod driver;
mod endpoint;
mod events;
mod execution;
mod files;
mod history;
mod incoming;
mod local;
mod local_signaling;
mod observation;
mod observed_history;
mod observed_operations;
mod operation_commands;
mod operations;
mod owner;
mod peers;
mod relay;
mod room_gestures;
mod sharing;
mod signaling;
mod transition;
mod uploads;
mod view;

use crate::{ice, platform::Platform, transport};
use driver::Driver;
use glowcap::{Host, PendingWork, Runtime};
use rooms_runtime::cleanup::combine as retain;
use std::rc::Rc;
use wasm_bindgen::prelude::*;

type Result<T> = std::result::Result<T, String>;

#[derive(Clone)]
struct TroubleReporter {
	callback: js_sys::Function,
	stopped: Rc<std::cell::Cell<bool>>,
}
impl TroubleReporter {
	fn report(&self, source: &str, reason: &str) {
		if self.stopped.get() {
			return;
		}
		if self
			.callback
			.call2(&JsValue::UNDEFINED, &source.into(), &reason.into())
			.is_err()
		{
			web_sys::console::error_1(&"Rooms trouble reporter failed".into());
		}
	}
}

struct Environment {
	runtime: Rc<Runtime>,
	local: Option<local::Owner>,
	browser_archive: crate::storage::Eraser,
	incoming: peers::Peers,
	relay: Option<relay::Relay>,
	connections: connections::Connections,
	platform: Platform,
	sources: rooms_glowcap::client::sources::Sources<Platform>,
	displays: rooms_application::files::receiving::Budget,
	ice: ice::Source,
	signaling: Rc<signaling::Signaling>,
	trouble: TroubleReporter,
}
impl Environment {
	async fn open(
		checkpoint: Option<rooms_application::session::checkpoint::Checkpoint>,
		trouble: TroubleReporter,
	) -> Result<Self> {
		let platform = Platform::new().map_err(|e| e.to_string())?;
		let prepared = if checkpoint.is_some() {
			Some(local::Prepared::open(platform.clone()).await?)
		} else {
			None
		};
		let host = match &prepared {
			Some(local) => Host::from_seed_with_options(local.seed()?, rooms_glowcap::host_options()),
			None => Host::with_options(rooms_glowcap::host_options()),
		}
		.map_err(|e| e.to_string())?;
		let signaling = Rc::new(signaling::Signaling::default());
		let selected = signaling.clone();
		let select = move |locator: &glowcap::Locator, origin: &glowcap::DialOrigin| selected.select(locator, origin);
		let front = transport::WebFront::deployment().map_err(|e| e.to_string())?;
		let relay_route = if let Some(checkpoint) = &checkpoint {
			let page = transport::page_url().map_err(|e| e.to_string())?;
			let use_relay = match page.search_params().get("dm").as_deref() {
				Some("relay") => true,
				Some("webrtc") => false,
				_ => checkpoint.uses_relay(),
			};
			use_relay
				.then(|| front.relay_route(&host))
				.transpose()
				.map_err(|e| e.to_string())?
		} else {
			None
		};
		let ice = ice::Source::deployment();
		let runtime = match transport::open(&host, front, select, ice.clone()).await {
			Ok(runtime) => runtime,
			Err(error) => {
				return Err(retain(
					Err(error.to_string()),
					host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
				)
				.unwrap_err());
			}
		};
		let runtime = Rc::new(runtime);
		let connections = connections::Connections::new(runtime.clone(), platform.clone());
		let mut environment = Self {
			runtime,
			local: None,
			browser_archive: crate::storage::Eraser::detached(),
			incoming: peers::Peers::start(),
			relay: None,
			connections,
			displays: Default::default(),
			sources: rooms_glowcap::client::sources::Sources::new(platform.clone()),
			platform,
			ice,
			signaling,
			trouble,
		};
		if let Some((locator, register)) = relay_route {
			match relay::Relay::start(
				&host,
				environment.platform.clone(),
				locator,
				register,
				environment.incoming.admission(),
			) {
				Ok(relay) => environment.relay = Some(relay),
				Err(error) => return Err(retain(Err(error), environment.close().await).unwrap_err()),
			}
		}
		if let (Some(prepared), Some(checkpoint)) = (prepared, checkpoint) {
			match local::Owner::open(&environment, prepared, checkpoint).await {
				Ok(local) => environment.local = Some(local),
				Err(error) => return Err(retain(Err(error), environment.close().await).unwrap_err()),
			}
		}
		Ok(environment)
	}
	async fn close(&self) -> Result<()> {
		self.signaling.stop();
		let local = match &self.local {
			Some(local) => local.close().await,
			None => Ok(()),
		};
		let relay = match &self.relay {
			Some(relay) => relay.close().await,
			None => Ok(()),
		};
		let incoming = self.incoming.close().await;
		let (ice, runtime) = tokio::join!(self.ice.close(), self.runtime.close(PendingWork::Cancel));
		self.signaling.clear();
		retain(
			retain(retain(local, relay), incoming),
			retain(ice.map_err(|e| e.to_string()), runtime.map_err(|e| e.to_string())),
		)
	}
}

/// Owns one continuously driven local executor and Host. Construct only after
/// selecting attached mode; pure setup uses the locator exports in entry.rs.
#[wasm_bindgen]
pub struct RoomsBrowserApplication {
	driver: Driver,
}
#[wasm_bindgen]
impl RoomsBrowserApplication {
	#[wasm_bindgen(constructor)]
	pub fn new(report_trouble: js_sys::Function) -> Self {
		Self {
			driver: Driver::start(report_trouble),
		}
	}

	#[wasm_bindgen(js_name = local)]
	pub fn local(
		checkpoint: js_sys::JsString,
		report_trouble: js_sys::Function,
	) -> std::result::Result<RoomsBrowserApplication, JsValue> {
		let raw = scalar(checkpoint, rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS)
			.map_err(|e| js_error(&e))?;
		let checkpoint =
			rooms_application::session::checkpoint::Checkpoint::decode(&raw, &rooms_glowcap::routes::CheckpointRoutes)
				.map_err(|e| js_error(&e.to_string()))?;
		Ok(Self {
			driver: Driver::start_local(checkpoint, report_trouble),
		})
	}
	#[wasm_bindgen(js_name = localWorkspace)]
	pub fn local_workspace(
		workspace: Option<js_sys::JsString>,
		page_directory: js_sys::JsString,
		report_trouble: js_sys::Function,
	) -> std::result::Result<RoomsBrowserApplication, JsValue> {
		let checkpoint = (|| -> Result<_> {
			let locator = scalar(page_directory, 65_536)?;
			let routes = rooms_glowcap::routes::CheckpointRoutes;
			if let Some(raw) = workspace {
				let workspace = crate::entry::decode_workspace(raw)?;
				workspace
					.session()
					.for_page_directory(&locator, workspace.left_page_directory().map(|id| id.text()), &routes)
					.map_err(|e| e.to_string())
			} else {
				rooms_application::session::checkpoint::Checkpoint::empty()
					.for_page_directory(&locator, None, &routes)
					.map_err(|e| e.to_string())
			}
		})();
		Ok(Self {
			driver: Driver::start_local(checkpoint.map_err(|e| js_error(&e))?, report_trouble),
		})
	}
	#[wasm_bindgen(js_name = localSession)]
	pub fn local_session(&self) -> js_sys::Promise {
		let scope = match self.driver.scope() {
			Ok(scope) => scope,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		self.driver.submit(0, move |environment| async move {
			let owner = owner::Owner::open_local(environment, driver.clone(), scope.clone())?;
			Ok(RoomsBrowserSession { driver, owner, scope }.into())
		})
	}
	/// The page prepares reachability before requesting publication.
	#[wasm_bindgen(js_name = publishLocal)]
	pub fn publish_local(&self) -> js_sys::Promise {
		let driver = self.driver.clone();
		self.driver.submit(0, move |environment| async move {
			let local = environment
				.local
				.as_ref()
				.ok_or("this application has no local Rooms session")?;
			let _publication = local.publication.lock().await;
			if let Some(relay) = &environment.relay {
				relay.ready().await?;
				return Ok(local.publish(relay.locator().clone()).await?.into());
			}
			if let Some(link) = local.published().await? {
				let parsed = glowcap::parse_sturdyref(&link, glowcap::CaptpVersion::V1_0).map_err(|e| e.to_string())?;
				let route = environment
					.signaling
					.prepare(&environment, &driver, &parsed.locator, None)
					.await?;
				local.hold_publication_route(route);
				return Ok(link.into());
			}
			let snapshot = local.access.snapshot().map_err(|e| e.to_string())?;
			let home = snapshot
				.checkpoint
				.directories()
				.find(|directory| directory.home)
				.and_then(|directory| directory.locator.text().as_str())
				.ok_or("sharing this local Rooms session needs a home directory")?;
			let designator = environment.runtime.host().designator().map_err(|e| e.to_string())?;
			let locator = glowcap::Locator::bare(glowcap::TRANSPORT_WEBRTC, &designator)
				.with_hint("signaling-directory", glowcap::HintValue::String(home.into()));
			let route = environment
				.signaling
				.prepare(&environment, &driver, &locator, Some(home))
				.await?;
			let link = local.publish(locator).await?;
			local.hold_publication_route(route);
			Ok(link.into())
		})
	}

	/// Return a typed session capability. Publication and watch integration
	/// retain their own guards; no integer identifies a live capability.
	pub fn attach(&self, sturdyref: js_sys::JsString, home: Option<js_sys::JsString>) -> js_sys::Promise {
		let text = match scalar(sturdyref, 16_384) {
			Ok(text) => text,
			Err(error) => return rejected(error),
		};
		let home = match home.map(|home| scalar(home, 16_384)).transpose() {
			Ok(home) => home,
			Err(error) => return rejected(error),
		};
		let scope = match self.driver.scope() {
			Ok(scope) => scope,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		self.driver.submit(
			text.len() + home.as_ref().map_or(0, String::len),
			move |environment| async move {
				let owner = owner::Owner::open(environment, driver.clone(), scope.clone(), text, home).await?;
				Ok(RoomsBrowserSession { driver, owner, scope }.into())
			},
		)
	}
	pub fn close(&self) -> js_sys::Promise {
		self.driver.close()
	}
}
impl Drop for RoomsBrowserApplication {
	fn drop(&mut self) {
		self.driver.stop();
	}
}

#[wasm_bindgen]
pub struct RoomsBrowserSession {
	driver: Driver,
	owner: Rc<owner::Owner>,
	scope: Rc<observation::Scope>,
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	pub fn watch(
		&self,
		changed: js_sys::Function,
		operations: js_sys::Function,
		history: js_sys::Function,
	) -> js_sys::Promise {
		let owner = self.owner.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |_| async move {
			owner
				.watch(
					driver,
					owner::Observers {
						changed,
						operations,
						history,
					},
				)
				.await
		})
	}

	pub fn snapshot(&self) -> js_sys::Promise {
		use rooms_glowcap::client::session::controller::Observation;
		let owner = self.owner.clone();
		self.driver.submit(0, move |_| async move {
			let snapshot = owner.refresh().await?;
			view::snapshot(&snapshot)
		})
	}

	pub fn command(
		&self,
		operation: js_sys::JsString,
		base: f64,
		name: js_sys::JsString,
		arguments: js_sys::Array,
	) -> js_sys::Promise {
		let base = match safe_integer(base) {
			Ok(base) => base,
			Err(error) => return rejected(error),
		};
		let (operation, name, arguments, bytes) = match command_input(operation, name, arguments) {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		self.mutation(
			Ok((operation, base, name, arguments)),
			bytes,
			|session, (operation, base, name, arguments)| async move {
				session
					.command(&operation, base, &name, &arguments)
					.await
					.map(|revision| JsValue::from(revision as f64))
					.map_err(|e| e.to_string())
			},
		)
	}
	pub fn typing(&self, conversation: js_sys::JsString, on: bool) -> js_sys::Promise {
		let bytes = conversation.length() as usize * 3;
		self.action(
			scalar(conversation, 65_536),
			bytes,
			move |session, conversation| async move {
				session
					.typing(&conversation, on)
					.await
					.map(|()| JsValue::UNDEFINED)
					.map_err(|e| e.to_string())
			},
		)
	}
	#[wasm_bindgen(js_name = verifySibling)]
	pub fn verify_sibling(&self, sturdyref: js_sys::JsString) -> js_sys::Promise {
		let bytes = sturdyref.length() as usize * 3;
		let owner = self.owner.clone();
		self.action(scalar(sturdyref, 16_384), bytes, move |_, text| async move {
			owner.verify_sibling(text).await?;
			Ok(JsValue::UNDEFINED)
		})
	}
	pub fn close(&self) -> js_sys::Promise {
		self.driver.with_local(|| self.owner.stop());
		self.ended()
	}
	pub fn ended(&self) -> js_sys::Promise {
		let mut ended = self.owner.ended.clone();
		wasm_bindgen_futures::future_to_promise(async move {
			connections::settled(&mut ended)
				.await
				.map(|()| JsValue::UNDEFINED)
				.map_err(|error| js_error(&error))
		})
	}
}
impl Drop for RoomsBrowserSession {
	fn drop(&mut self) {
		self.driver.with_local(|| self.owner.stop());
	}
}

fn scalar(value: js_sys::JsString, maximum: usize) -> Result<String> {
	crate::js_text::scalar(&value, maximum).map_err(|error| error.to_string())
}
fn safe_integer(value: f64) -> Result<u64> {
	if !value.is_finite() || !(0.0..=9_007_199_254_740_991.0).contains(&value) || value.fract() != 0.0 {
		Err("Rooms revision is outside the safe integer range".into())
	} else {
		Ok(value as u64)
	}
}
fn js_error(error: &str) -> JsValue {
	js_sys::Error::new(error).into()
}
fn rejected(error: String) -> js_sys::Promise {
	js_sys::Promise::reject(&js_error(&error))
}

fn command_input(
	operation: js_sys::JsString,
	name: js_sys::JsString,
	arguments: js_sys::Array,
) -> Result<(String, String, Vec<String>, usize)> {
	let operation = scalar(operation, 65_536)?;
	let name = scalar(name, 128)?;
	if arguments.length() as usize > rooms_application::session::command::MAX_ARGUMENTS {
		return Err("Too many Rooms command arguments".into());
	}
	let mut bytes = operation.len() + name.len();
	let mut values = Vec::with_capacity(arguments.length() as usize);
	for value in arguments.iter() {
		let value = value
			.dyn_into::<js_sys::JsString>()
			.map_err(|_| "Rooms command arguments must be strings")?;
		let value = scalar(value, 65_536)?;
		bytes += value.len();
		if bytes > driver::MAX_BYTES {
			return Err("Rooms command exceeds the retained input budget".into());
		}
		values.push(value);
	}
	Ok((operation, name, values, bytes))
}
