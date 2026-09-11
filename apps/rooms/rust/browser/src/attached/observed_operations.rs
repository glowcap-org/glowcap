//! One operations read per capability. Invalidations coalesce in shared policy;
//! browser tasks retain effects and bounded driver admission owns caller waits.
use super::{observation::call, owner::Owner, view, Result, RoomsBrowserSession};
use rooms_application::{
	server::operations::operator::ReferenceKind,
	session::{
		controller::operations::{Filter, Kind, Operations, Read, VIEWS},
		operations::Capability,
		snapshot::Snapshot,
	},
};
use std::{
	cell::{Cell, RefCell},
	rc::{Rc, Weak},
};
use tokio::sync::watch;
use wasm_bindgen::prelude::*;

mod pages;
// At most six readers move these small headers; retain rows without a per-read box.
#[allow(clippy::large_enum_variant)]
enum Answer {
	View(JsValue),
	Operator(rooms_application::server::operations::operator::view::Snapshot),
	Page(rooms_application::server::operations::operator::view::Page),
}
type Outcome = (u64, Result<()>);
pub(super) struct Feed {
	owner: Weak<Owner>,
	state: RefCell<Operations>,
	listener: RefCell<Option<js_sys::Function>>,
	generation: Cell<u64>,
	completed: [watch::Sender<Outcome>; VIEWS],
	replaced: watch::Sender<()>,
	pages: tokio::sync::Mutex<()>,
}
impl Feed {
	pub fn new(owner: Weak<Owner>) -> Self {
		Self {
			owner,
			state: RefCell::default(),
			listener: RefCell::default(),
			generation: Cell::new(0),
			completed: std::array::from_fn(|_| watch::channel((0, Ok(()))).0),
			replaced: watch::channel(()).0,
			pages: tokio::sync::Mutex::new(()),
		}
	}
	pub fn observe(&self, snapshot: &Snapshot) -> Result<()> {
		if self.listener.borrow().is_none() {
			return Ok(());
		}
		let owner = self.owner.upgrade().ok_or("Rooms operations owner retired")?;
		let generation = owner.scope.generation();
		let replaced = self.generation.replace(generation) != generation;
		if replaced {
			self.state.borrow_mut().retire()?;
		}
		let cleared = self.state.borrow_mut().observe(snapshot)?;
		for kind in Kind::all() {
			if replaced || cleared[kind.index()] {
				let filter = self.state.borrow().filter(kind).clone();
				self.notify(kind, &filter, &Ok(JsValue::NULL))?;
			}
		}
		self.pump()
	}
	pub fn invalidate(&self, scope: &str) -> Result<()> {
		self.state.borrow_mut().invalidate(scope)?;
		self.pump()
	}
	pub fn listen(&self, listener: Option<js_sys::Function>) -> Result<()> {
		if self.listener.borrow().is_some() && listener.is_some() {
			return Err("Rooms operations already has a view owner".into());
		}
		*self.listener.borrow_mut() = listener;
		self.replaced.send_replace(());
		self.state.borrow_mut().retire()?;
		let owner = self.owner.upgrade().ok_or("Rooms operations owner retired")?;
		let snapshot = owner.latest.borrow().clone();
		if let Some(snapshot) = snapshot {
			self.observe(&snapshot)?;
		}
		Ok(())
	}
	pub fn close(&self) {
		self.listener.borrow_mut().take();
		self.state.borrow_mut().operator = None;
	}
	pub async fn refresh(&self, kind: Kind, filter: Option<Filter>) -> Result<()> {
		if self.listener.borrow().is_none() {
			return Err("Rooms operations view has not started".into());
		}
		self.owner
			.upgrade()
			.ok_or("Rooms operations owner retired")?
			.session()?;
		let mut replaced = self.replaced.subscribe();
		let version = self.state.borrow_mut().request(kind, filter)?;
		self.pump()?;
		self.wait(kind, version, &mut replaced).await
	}
	async fn wait(&self, kind: Kind, version: u64, replaced: &mut watch::Receiver<()>) -> Result<()> {
		let mut completed = self.completed[kind.index()].subscribe();
		loop {
			if replaced
				.has_changed()
				.map_err(|_| "Rooms operations listener retired")?
			{
				return Err("Rooms operations listener retired".into());
			}
			let result = {
				let completed = completed.borrow();
				(completed.0 >= version).then(|| completed.1.clone())
			};
			if let Some(result) = result {
				return result;
			}
			tokio::select! { biased;
				_ = replaced.changed() => return Err("Rooms operations listener retired".into()),
				result = completed.changed() => result.map_err(|_| "Rooms operations read owner retired")?,
			}
		}
	}
	fn notify(&self, kind: Kind, filter: &Filter, result: &Result<JsValue>) -> Result<()> {
		let listener = self.listener.borrow().clone();
		let Some(listener) = listener else {
			return Ok(());
		};
		let output = js_sys::Object::new().into();
		view::set(&output, "capability", kind.name().into())?;
		view::set(&output, "search", filter.search.as_str().into())?;
		view::set(&output, "referenceKind", view::json(&filter.reference)?)?;
		match result {
			Ok(snapshot) => {
				view::set(&output, "snapshot", snapshot.clone())?;
				view::set(&output, "error", JsValue::NULL)?;
			}
			Err(error) => {
				let fallback = if kind.name() == "peering" {
					let owner = self.owner.upgrade().ok_or("Rooms operations owner retired")?;
					let latest = owner.latest.borrow();
					let state = self.state.borrow();
					let rows = latest
						.as_ref()
						.map(|snapshot| {
							snapshot
								.checkpoint
								.peering()
								.filter(|intent| Some(intent.destination) == state.scope(kind))
								.map(
									|intent| serde_json::json!({"id":intent.id,"name":intent.name,"source":intent.source,"phase":"failed"}),
								)
								.collect::<Vec<_>>()
						})
						.unwrap_or_default();
					view::json(&serde_json::json!({"capability":"peering","rows":rows}))?
				} else if kind.name() == "operator" {
					self.state
						.borrow()
						.operator
						.as_ref()
						.map(view::json)
						.transpose()?
						.unwrap_or(JsValue::NULL)
				} else {
					JsValue::NULL
				};
				view::set(&output, "snapshot", fallback)?;
				view::set(&output, "error", error.into())?;
			}
		}
		call(&listener, output)
	}
	fn finish(&self, read: &Read, result: Result<Answer>, generation: u64) -> Result<()> {
		let current = self.state.borrow_mut().finish(read);
		if current {
			let live = self
				.owner
				.upgrade()
				.is_some_and(|owner| owner.scope.current(generation).is_ok());
			let result = if live {
				result.and_then(|answer| self.apply(read, answer))
			} else {
				Err("Rooms operations observation retired".into())
			};
			let result = match result {
				Ok(Some(value)) => Ok(value),
				Ok(None) => return self.pump(),
				Err(error) => {
					if read.kind.name() == "operator" && read.page.is_none() {
						self.state.borrow_mut().operator = None;
					}
					Err(error)
				}
			};
			let delivered = if live {
				self.notify(read.kind, &read.filter, &result)
			} else {
				Ok(())
			};
			let outcome = super::retain(result.map(|_| ()), delivered);
			drop(self.completed[read.kind.index()].send_replace((read.version, outcome)));
		}
		self.pump()
	}
	fn pump(&self) -> Result<()> {
		let owner = self.owner.upgrade().ok_or("Rooms operations owner retired")?;
		if owner.scope.open().is_err() || self.listener.borrow().is_none() {
			return Ok(());
		}
		let Ok(session) = owner.session() else {
			return Ok(());
		};
		for kind in Kind::all() {
			let Some(read) = self.state.borrow_mut().begin(kind) else {
				continue;
			};
			let read = Rc::new(read);
			let generation = owner.scope.generation();
			if read.scope.is_none() {
				self.finish(&read, Ok(Answer::View(JsValue::NULL)), generation)?;
				continue;
			}
			let running = owner.clone();
			let ticket = read.clone();
			let session = session.clone();
			let bytes = read.scope.as_ref().map_or(0, String::len) + read.filter.search.len();
			let submitted = owner.driver.background(bytes, move |_| async move {
				let work = async {
					running.scope.current(generation)?;
					let scope = ticket.scope.as_deref().expect("a scheduled read has a scope");
					let output = if kind.name() == "operator" {
						pages::read(&session, &ticket).await?
					} else {
						let capability = match kind.name() {
							"listeners" => Capability::Listeners,
							"diagnostics" => Capability::Diagnostics,
							"irc" => Capability::Irc,
							"viz" => Capability::Viz,
							"peering" => Capability::Peering,
							_ => unreachable!("the shared operations inventory has six views"),
						};
						Answer::View(super::operations::snapshot_view(
							session
								.operations_snapshot(scope, capability)
								.await
								.map_err(|e| e.to_string())?,
							capability,
						)?)
					};
					running.scope.current(generation)?;
					Ok(output)
				};
				let result = tokio::select! { biased;
					() = running.scope.stopped() => Err("Rooms attachment closed during its operations read".into()),
					result = work => result,
				};
				running.operations.finish(&ticket, result, generation)?;
				Ok(JsValue::UNDEFINED)
			});
			if let Err(error) = submitted {
				self.finish(&read, Err(error), generation)?;
			}
		}
		Ok(())
	}
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = listenOperations)]
	pub fn listen_operations(&self, listener: Option<js_sys::Function>) -> std::result::Result<(), JsValue> {
		self.driver.with_local(|| {
			(if listener.is_some() { self.scope.open() } else { Ok(()) })
				.and_then(|()| self.owner.operations.listen(listener))
				.map_err(|error| super::js_error(&error))
		})
	}
	#[wasm_bindgen(js_name = refreshOperations)]
	pub fn refresh_operations(
		&self,
		capability: js_sys::JsString,
		search: Option<js_sys::JsString>,
		reference: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let bytes = 3
			* (capability.length() as usize
				+ search.as_ref().map_or(0, |s| s.length() as usize)
				+ reference.as_ref().map_or(0, |s| s.length() as usize));
		let input = (|| {
			let kind = Kind::parse(&super::actions::text(capability)?).ok_or("Unknown operations view")?;
			let reference = reference
				.map(|value| {
					ReferenceKind::parse(&super::actions::text(value)?)
						.ok_or_else(|| "Invalid operator reference kind".to_owned())
				})
				.transpose()?;
			let filter = search
				.map(|value| super::actions::text(value).map(|search| Filter { search, reference }))
				.transpose()?;
			Ok::<_, String>((kind, filter))
		})();
		let (kind, filter) = match input {
			Ok(value) => value,
			Err(error) => return super::rejected(error),
		};
		let owner = self.owner.clone();
		self.driver.submit(bytes, move |_| async move {
			let generation = owner.scope.generation();
			tokio::select! { biased;
				() = owner.scope.stopped() => return Err("Rooms attachment closed during operations refresh".into()),
				result = owner.operations.refresh(kind, filter) => result?,
			}
			owner.scope.current(generation)?;
			Ok(JsValue::UNDEFINED)
		})
	}
}
