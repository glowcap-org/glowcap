//! One native event queue owns incoming file occurrences until one page listener
//! accepts them. Sequence admission precedes JS projection and file delivery.
use super::{
	driver::Driver,
	files::{self, RoomsBrowserFile},
	observation::{call, Scope},
	view, Result, RoomsBrowserSession,
};
use rooms_application::session::{
	controller::events::{Admission, Events},
	event::Event,
};
use rooms_glowcap::client::session::controller::Observation;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use wasm_bindgen::prelude::*;

struct Notice {
	event: Event<()>,
	files: Vec<RoomsBrowserFile>,
}
#[derive(Default)]
pub(super) struct Feed {
	queue: RefCell<Events<Notice>>,
	editable: RefCell<rooms_application::session::controller::editable::Editable>,
	listener: RefCell<Option<js_sys::Function>>,
	gap: RefCell<Option<(String, String)>>,
	gap_version: Cell<u64>,
	refreshing: Cell<bool>,
}
impl Feed {
	pub fn receive<C>(
		&self,
		driver: &Driver,
		scope: &Rc<Scope>,
		event: Event<C>,
		file: impl Fn(rooms_application::room::attachment::Attachment<C>) -> files::Access,
	) -> Result<Option<(String, &'static str)>> {
		match self.queue.borrow_mut().admit(&event.source, event.sequence) {
			Admission::Duplicate => return Ok(None),
			Admission::Gap => {
				self.editable.borrow_mut().clear();
				return Ok(Some((
					event.conversation_id,
					"The shared event stream skipped a sequence.",
				)));
			}
			Admission::Accept => {}
		}
		let (event, attachments) = event.into_parts();
		self.editable.borrow_mut().receive(&event);
		let files = attachments
			.into_iter()
			.map(|attachment| files::hold(driver, scope, file(attachment)))
			.collect::<Result<Vec<_>>>()?;
		let bytes = event.retained_bytes() + files.capacity() * std::mem::size_of::<RoomsBrowserFile>();
		let notice = Notice { event, files };
		let listener = self.listener.borrow().clone();
		if let Some(listener) = listener {
			deliver(&listener, notice)?;
			Ok(None)
		} else {
			let conversation = notice.event.conversation_id.clone();
			let lost = self.queue.borrow_mut().push(notice, bytes);
			Ok(lost.then_some((conversation, "The shared event stream exceeded its initial buffer.")))
		}
	}
	pub fn listen(&self, listener: Option<js_sys::Function>) -> Result<()> {
		if self
			.listener
			.borrow()
			.as_ref()
			.zip(listener.as_ref())
			.is_some_and(|(old, next)| old != next)
		{
			return Err("the attached Rooms feed already has a line owner".into());
		}
		*self.listener.borrow_mut() = listener.clone();
		if let Some(listener) = listener {
			loop {
				let notice = self.queue.borrow_mut().pop();
				let Some(notice) = notice else { break };
				if let Err(error) = deliver(&listener, notice) {
					self.listener.borrow_mut().take();
					return Err(error);
				}
				if self.listener.borrow().is_none() {
					break;
				}
			}
		}
		Ok(())
	}
	pub fn decorate(&self, output: &JsValue) -> Result<()> {
		if let Some((subject, reason)) = self.gap.borrow().as_ref() {
			let issues = js_sys::Reflect::get(output, &"issues".into()).map_err(|_| "Rooms gap projection failed")?;
			let issues = js_sys::Array::from(&issues);
			let issue = js_sys::Object::new().into();
			view::set(&issue, "subject", subject.into())?;
			view::set(&issue, "reason", reason.into())?;
			issues.push(&issue);
			view::set(output, "issues", issues.into())?;
		}
		Ok(())
	}
	pub fn discard(&self) {
		self.queue.borrow_mut().clear();
		self.editable.borrow_mut().clear();
	}
	pub fn close(&self) {
		self.listener.borrow_mut().take();
		self.discard();
	}
}
fn deliver(listener: &js_sys::Function, notice: Notice) -> Result<()> {
	let output = view::event(&notice.event)?;
	let held: Vec<_> = notice.files.iter().map(RoomsBrowserFile::held).collect();
	let attachments: js_sys::Array = notice.files.into_iter().map(JsValue::from).collect();
	let result = view::set(&output, "attachments", attachments.into()).and_then(|()| call(listener, output));
	if result.is_err() {
		for file in held {
			file.release();
		}
	}
	result
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = lastEditableLine)]
	pub fn last_editable_line(&self, conversation: js_sys::JsString) -> std::result::Result<Option<f64>, JsValue> {
		self.driver.with_local(|| {
			self.scope
				.open()
				.and_then(|()| {
					let conversation = super::actions::text(conversation)?;
					Ok(self
						.owner
						.events
						.editable
						.borrow()
						.last(&conversation)
						.map(|id| id as f64))
				})
				.map_err(|error| super::js_error(&error))
		})
	}
	#[wasm_bindgen(js_name = listenLines)]
	pub fn listen_lines(&self, listener: Option<js_sys::Function>) -> std::result::Result<(), JsValue> {
		self.driver.with_local(|| {
			(if listener.is_some() { self.scope.open() } else { Ok(()) })
				.and_then(|()| self.owner.events.listen(listener))
				.map_err(|error| super::js_error(&error))
		})
	}
}

impl super::owner::Owner {
	pub fn event_gap(self: &Rc<Self>, conversation: String, reason: &str) -> Result<()> {
		let detail = match self
			.latest
			.borrow()
			.as_ref()
			.map(|snapshot| snapshot.checkpoint.keeps_history())
		{
			Some(true) => format!("{reason} Retained history is reconciling for this conversation."),
			Some(false) => format!("{reason} Retained history is disabled, so the missed lines are unavailable."),
			None => reason.to_owned(),
		};
		*self.events.gap.borrow_mut() = Some((format!("event-gap:{conversation}"), detail));
		self.events.gap_version.set(
			self.events
				.gap_version
				.get()
				.checked_add(1)
				.ok_or("Rooms event recovery generation exhausted")?,
		);
		if self.latest.borrow().is_some() {
			self.announce(None)?;
		}
		if self.events.refreshing.replace(true) {
			return Ok(());
		}
		let owner = self.clone();
		let started = self.driver.background(0, move |_| async move {
			loop {
				let version = owner.events.gap_version.get();
				let result = tokio::select! { biased;
					() = owner.scope.stopped() => break,
					result = owner.refresh() => result,
				};
				if version != owner.events.gap_version.get() {
					continue;
				}
				if let Err(error) = result {
					if let Some((_, reason)) = owner.events.gap.borrow_mut().as_mut() {
						reason.push_str(&format!(" Snapshot refresh failed: {error}"));
					}
				} else {
					owner.events.gap.borrow_mut().take();
				}
				owner.events.refreshing.set(false);
				owner.announce(None)?;
				return Ok(JsValue::UNDEFINED);
			}
			owner.events.refreshing.set(false);
			Ok(JsValue::UNDEFINED)
		});
		if let Err(error) = started {
			self.events.refreshing.set(false);
			if let Some((_, reason)) = self.events.gap.borrow_mut().as_mut() {
				reason.push_str(&format!(" Snapshot refresh could not start: {error}"));
			}
			self.announce(None)?;
		}
		Ok(())
	}
}
