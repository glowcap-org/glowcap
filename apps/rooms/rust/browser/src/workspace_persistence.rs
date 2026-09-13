//! Browser effects for the shared workspace save policy. Timer closures hold
//! weak custody; explicit stop fences writes and releases all page callbacks.
use gloo_timers::callback::Timeout;
use rooms_application::workspace::persistence::{COALESCE_MS, Persistence};
use std::{cell::RefCell, rc::Rc};
use wasm_bindgen::{JsCast, prelude::*};

struct Hooks {
	read: js_sys::Function,
	write: js_sys::Function,
	clear: js_sys::Function,
	report: js_sys::Function,
}
#[derive(Default)]
struct Timers {
	save: Option<Timeout>,
	retry: Option<Timeout>,
}
pub(crate) struct Inner {
	policy: RefCell<Persistence>,
	hooks: RefCell<Option<Hooks>>,
	timers: RefCell<Timers>,
	pub transition: tokio::sync::Mutex<()>,
}

#[wasm_bindgen]
pub struct RoomsWorkspacePersistence(Rc<Inner>);

#[wasm_bindgen]
impl RoomsWorkspacePersistence {
	/// Before a live session opens, preferences compose with the last admitted
	/// checkpoint. Display rows never reconstruct authority during setup.
	pub fn compose(&self, choices: js_sys::JsString) -> Result<String, JsValue> {
		let result = (|| -> Result<String, String> {
			let choices = json_text(choices, rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS)?;
			let policy = self.0.policy.borrow();
			if policy.stopped() {
				return Err("workspace persistence has retired".into());
			}
			let routes = rooms_glowcap::routes::CheckpointRoutes;
			let checkpoint = match policy.last() {
				Some(raw) => rooms_application::workspace::Workspace::decode(raw, &routes)
					.map_err(|e| e.to_string())?
					.into_session(),
				None => Rc::new(rooms_application::session::checkpoint::Checkpoint::empty()),
			};
			rooms_application::workspace::Workspace::compose(&choices, checkpoint, &routes)
				.and_then(|workspace| workspace.encode())
				.map_err(|e| e.to_string())
		})();
		result.map_err(|e| js_sys::Error::new(&e).into())
	}
	#[wasm_bindgen(constructor)]
	pub fn new(
		initial: Option<js_sys::JsString>,
		blocked: bool,
		read: js_sys::Function,
		write: js_sys::Function,
		clear: js_sys::Function,
		report: js_sys::Function,
	) -> Self {
		let present = initial.is_some();
		let last = initial.and_then(|raw| crate::entry::decode_workspace(raw).ok()?.encode().ok());
		let blocked = blocked || (present && last.is_none());
		Self(Rc::new(Inner {
			policy: RefCell::new(Persistence::new(last, blocked)),
			hooks: RefCell::new(Some(Hooks {
				read,
				write,
				clear,
				report,
			})),
			timers: Default::default(),
			transition: Default::default(),
		}))
	}
	/// Explicit replacement may recover an invalid saved document. A refused
	/// write restores its prior block; a cross-peer success fences old writes.
	pub fn select(&self, controller: js_sys::JsString, checkpoint: Option<js_sys::JsString>) -> bool {
		let input = (|| {
			let controller = json_text(controller, 32768)?;
			let checkpoint = checkpoint
				.map(|value| json_text(value, rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS))
				.transpose()?;
			Ok::<_, String>((controller, checkpoint))
		})();
		let (controller, checkpoint) = match input {
			Ok(input) => input,
			Err(reason) => {
				self.0.report(&reason);
				return false;
			}
		};
		let fence = std::cell::Cell::new(false);
		let saved = self.0.replacement(None, false, |workspace| {
			workspace
				.select(
					&controller,
					checkpoint.as_deref(),
					&rooms_glowcap::routes::CheckpointRoutes,
				)
				.map(|(workspace, stop)| {
					fence.set(stop);
					workspace
				})
				.map_err(|e| e.to_string())
		});
		if saved && fence.get() {
			self.0.stop();
		}
		saved
	}
	pub fn replace(&self, document: js_sys::JsString) -> bool {
		self.0.replacement(Some(document), true, Ok)
	}
	/// The adapter removes ancillary keys before the authoritative document.
	/// Refusal preserves this writer; success permanently fences its callbacks.
	pub fn clear(&self) -> bool {
		let prior = self.0.policy.borrow().blocked();
		self.0.policy.borrow_mut().set_blocked(false);
		let Some(attempt) = self.0.policy.borrow_mut().begin(true) else {
			self.0.policy.borrow_mut().set_blocked(prior);
			return false;
		};
		self.0.timers.borrow_mut().save.take();
		let clear = self.0.hooks.borrow().as_ref().map(|hooks| hooks.clear.clone());
		if clear.is_some_and(|clear| {
			clear
				.call0(&JsValue::UNDEFINED)
				.is_ok_and(|v| v.as_bool() == Some(true))
		}) {
			self.0.policy.borrow_mut().set_blocked(true);
			self.0.stop();
			true
		} else {
			let failed = self.0.policy.borrow_mut().failed(attempt);
			self.0.policy.borrow_mut().set_blocked(prior);
			if let Some(delay) = failed.retry_ms {
				self.0.timer(true, delay);
			}
			self.0.report("this browser refused to clear all Rooms workspace data");
			false
		}
	}
	pub fn blocked(&self) -> bool {
		self.0.policy.borrow().blocked()
	}
	pub fn stopped(&self) -> bool {
		self.0.policy.borrow().stopped()
	}
	#[wasm_bindgen(js_name = setBlocked)]
	pub fn set_blocked(&self, blocked: bool) {
		self.0.policy.borrow_mut().set_blocked(blocked);
	}
	pub fn schedule(&self) {
		if self.0.policy.borrow_mut().schedule() {
			self.0.timer(false, COALESCE_MS);
		}
	}
	pub fn flush(&self, prepared: Option<js_sys::JsString>) -> bool {
		self.0.flush(prepared)
	}
	#[wasm_bindgen(js_name = flushIfDirty)]
	pub fn flush_if_dirty(&self) -> bool {
		if self.0.policy.borrow().dirty() {
			self.0.flush(None)
		} else {
			true
		}
	}
	pub fn stop(&self) {
		self.0.stop();
	}
}
impl Drop for RoomsWorkspacePersistence {
	fn drop(&mut self) {
		self.0.stop();
	}
}

impl RoomsWorkspacePersistence {
	pub(crate) fn handle(&self) -> Rc<Inner> {
		self.0.clone()
	}
}

impl Inner {
	pub(crate) fn read(&self) -> Result<rooms_application::workspace::Workspace, String> {
		let read = self
			.hooks
			.borrow()
			.as_ref()
			.map(|hooks| hooks.read.clone())
			.ok_or("workspace reader has retired")?;
		let raw = read
			.call0(&JsValue::UNDEFINED)
			.map_err(callback_reason)?
			.dyn_into::<js_sys::JsString>()
			.map_err(|_| "workspace reader did not return a document")?;
		if self.hooks.borrow().is_none() {
			return Err("workspace reader has retired".into());
		}
		crate::entry::decode_workspace(raw)
	}
	pub(crate) fn commit_attachment(
		self: &Rc<Self>,
		plan: rooms_application::workspace::transition::Attachment,
		checkpoint: Option<Rc<rooms_application::session::checkpoint::Checkpoint>>,
	) -> Result<String, String> {
		let encoded = plan
			.commit(self.read()?, checkpoint)
			.map_err(str::to_owned)?
			.encode()
			.map_err(|e| e.to_string())?;
		if self.replacement(Some(encoded.as_str().into()), true, Ok) {
			Ok(encoded)
		} else {
			Err("This browser refused to save the shared session capability.".into())
		}
	}
	fn stop(&self) {
		self.policy.borrow_mut().stop();
		*self.timers.borrow_mut() = Timers::default();
		self.hooks.borrow_mut().take();
	}
	fn timer(self: &Rc<Self>, retry: bool, delay: u32) {
		let weak = Rc::downgrade(self);
		let timer = Timeout::new(delay, move || {
			let Some(inner) = weak.upgrade() else {
				return;
			};
			if retry {
				inner.timers.borrow_mut().retry.take();
				inner.policy.borrow_mut().retry_fired();
			} else {
				inner.timers.borrow_mut().save.take();
				inner.policy.borrow_mut().save_fired();
			}
			inner.flush(None);
		});
		if retry {
			self.timers.borrow_mut().retry = Some(timer);
		} else {
			self.timers.borrow_mut().save = Some(timer);
		}
	}
	pub(crate) fn report(&self, reason: &str) {
		let report = self.hooks.borrow().as_ref().map(|hooks| hooks.report.clone());
		if let Some(report) = report {
			if report.call1(&JsValue::UNDEFINED, &reason.into()).is_err() {
				web_sys::console::error_1(&"Rooms workspace failure reporter failed".into());
			}
		}
	}
	fn replacement(
		self: &Rc<Self>,
		document: Option<js_sys::JsString>,
		fence: bool,
		transform: impl FnOnce(
			rooms_application::workspace::Workspace,
		) -> Result<rooms_application::workspace::Workspace, String>,
	) -> bool {
		let prior = self.policy.borrow().blocked();
		self.policy.borrow_mut().set_blocked(false);
		let saved = self.flush_with(document, true, transform);
		if !saved {
			self.policy.borrow_mut().set_blocked(prior);
		} else if fence {
			self.stop();
		}
		saved
	}
	fn flush(self: &Rc<Self>, prepared: Option<js_sys::JsString>) -> bool {
		let explicit = prepared.is_some();
		self.flush_with(prepared, explicit, Ok)
	}
	fn flush_with(
		self: &Rc<Self>,
		prepared: Option<js_sys::JsString>,
		explicit: bool,
		transform: impl FnOnce(
			rooms_application::workspace::Workspace,
		) -> Result<rooms_application::workspace::Workspace, String>,
	) -> bool {
		let Some(attempt) = self.policy.borrow_mut().begin(explicit) else {
			return false;
		};
		self.timers.borrow_mut().save.take();
		let read = self.hooks.borrow().as_ref().map(|hooks| hooks.read.clone());
		let encoded = (|| {
			let raw = match prepared {
				Some(raw) => raw,
				None => read
					.ok_or("workspace reader has retired")?
					.call0(&JsValue::UNDEFINED)
					.map_err(callback_reason)?
					.dyn_into::<js_sys::JsString>()
					.map_err(|_| "workspace reader did not return a document".to_owned())?,
			};
			transform(crate::entry::decode_workspace(raw)?)?
				.encode()
				.map_err(|e| e.to_string())
		})();
		let encoded = match encoded {
			Ok(encoded) => encoded,
			Err(reason) => {
				let report = self.policy.borrow_mut().refused(reason.clone());
				if report {
					self.report(&format!("this browser cannot save the Rooms workspace: {reason}"));
				}
				return false;
			}
		};
		if !self.policy.borrow().current() {
			self.policy.borrow_mut().cancel();
			return false;
		}
		if self.policy.borrow().unchanged(&encoded) {
			self.policy.borrow_mut().saved(None);
			self.timers.borrow_mut().retry.take();
			return true;
		}
		let write = self.hooks.borrow().as_ref().map(|hooks| hooks.write.clone());
		let saved = write.is_some_and(|write| {
			write
				.call1(&JsValue::UNDEFINED, &encoded.as_str().into())
				.is_ok_and(|answer| answer.as_bool() == Some(true))
		});
		if saved {
			self.policy.borrow_mut().saved(Some(encoded));
			self.timers.borrow_mut().retry.take();
			true
		} else {
			let failed = self.policy.borrow_mut().failed(attempt);
			if let Some(delay) = failed.retry_ms {
				self.timer(true, delay);
			}
			if failed.report {
				self.report("this browser refused to save the Rooms workspace");
			}
			false
		}
	}
}

fn callback_reason(error: JsValue) -> String {
	if let Some(error) = error.dyn_ref::<js_sys::Error>() {
		error.message().into()
	} else {
		error.as_string().unwrap_or_else(|| "workspace callback failed".into())
	}
}

fn json_text(value: js_sys::JsString, bound: usize) -> Result<String, String> {
	if value.length() as usize > bound {
		return Err("workspace transition exceeds its document bound".into());
	}
	let text = value.as_string().ok_or("workspace transition is not text")?;
	// Compare two JS strings; comparison with str would lose unpaired units.
	let round_trip = js_sys::JsString::from(text.as_str());
	if round_trip != value {
		return Err("workspace transition must encode non-scalar text as JSON escapes".into());
	}
	Ok(text)
}
