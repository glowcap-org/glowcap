//! The attachment supervises history reads; the page receives loading/results.
//! Invalidation and topology are read from the canonical Rust session view.
use super::{Result, RoomsBrowserSession, observation::call, owner::Owner, view};
use rooms_application::{
	archive::change::Change,
	grants::Access,
	session::{
		controller::history::{CONCURRENCY, History, Read, Target},
		snapshot::Snapshot,
	},
};
use rooms_glowcap::client::session::HistoryView;
use std::{cell::RefCell, rc::Weak};
use wasm_bindgen::prelude::*;

pub(super) struct Feed {
	owner: Weak<Owner>,
	state: RefCell<History>,
	listener: RefCell<Option<js_sys::Function>>,
}
struct Reading {
	owner: Weak<Owner>,
	read: Option<Read>,
}
impl Reading {
	fn finish(&mut self, success: bool) -> bool {
		let Some(read) = self.read.take() else { return false };
		self.owner
			.upgrade()
			.is_some_and(|owner| owner.history.state.borrow_mut().finish(read, success))
	}
}
impl Drop for Reading {
	fn drop(&mut self) {
		self.finish(false);
	}
}
impl Feed {
	pub fn new(owner: Weak<Owner>) -> Self {
		Self {
			owner,
			state: RefCell::default(),
			listener: RefCell::default(),
		}
	}
	pub fn observe(&self, snapshot: &Snapshot) -> Result<()> {
		if snapshot.access == Access::None || self.listener.borrow().is_none() {
			self.state.borrow_mut().clear();
			return Ok(());
		}
		self.state.borrow_mut().observe(&snapshot.checkpoint)?;
		self.pump()
	}
	pub fn invalidate(&self, change: &Change) -> Result<()> {
		self.state.borrow_mut().invalidate(change)?;
		self.pump()
	}
	pub fn listen(&self, listener: Option<js_sys::Function>) -> Result<()> {
		if self.listener.borrow().is_some() && listener.is_some() {
			return Err("Rooms history already has a view owner".into());
		}
		*self.listener.borrow_mut() = listener;
		self.state.borrow_mut().clear();
		let owner = self.owner.upgrade().ok_or("Rooms attachment retired")?;
		let snapshot = owner.latest.borrow().clone();
		if let Some(snapshot) = snapshot {
			self.observe(&snapshot)?;
		}
		Ok(())
	}
	pub fn close(&self) {
		self.listener.borrow_mut().take();
		self.state.borrow_mut().clear();
	}
	fn notify(&self, target: &Target, phase: &str, outcome: Option<&Result<HistoryView>>) -> Result<()> {
		let listener = self.listener.borrow().clone();
		let Some(listener) = listener else { return Ok(()) };
		let output = js_sys::Object::new().into();
		view::set(&output, "conversationId", view::document(&target.conversation))?;
		view::set(&output, "phase", phase.into())?;
		if let Some(outcome) = outcome {
			match outcome {
				Ok(history) => {
					view::set(&output, "records", view::json(&history.records)?)?;
					view::set(&output, "local", history.local.into())?;
					view::set(&output, "peer", history.peer.into())?;
				}
				Err(error) => view::set(&output, "error", error.into())?,
			}
		}
		call(&listener, output)
	}
	fn pump(&self) -> Result<()> {
		let owner = self.owner.upgrade().ok_or("Rooms attachment retired")?;
		if owner.scope.open().is_err() || self.listener.borrow().is_none() {
			return Ok(());
		}
		let Ok(session) = owner.session() else {
			return Ok(());
		};
		for _ in 0..CONCURRENCY {
			let read = self.state.borrow_mut().next_read();
			let Some(read) = read else { break };
			let target = read.target.clone();
			let mut custody = Reading {
				owner: self.owner.clone(),
				read: Some(read),
			};
			self.notify(&target, "loading", None)?;
			let running = owner.clone();
			let session = session.clone();
			let generation = owner.scope.generation();
			let bytes = target.directory.heap_bytes() + target.conversation.heap_bytes();
			owner.driver.background(bytes, move |_| async move {
				let work = async {
					running.scope.current(generation)?;
					let records = session
						.history(
							target.kind,
							target
								.directory
								.as_str()
								.ok_or("Rooms history directory requires scalar text")?,
							target
								.conversation
								.as_str()
								.ok_or("Rooms history conversation requires scalar text")?,
						)
						.await
						.map_err(|error| error.to_string())?;
					running.scope.current(generation)?;
					Ok(records)
				};
				let result = tokio::select! { biased;
					() = running.scope.stopped() => Err("Rooms attachment closed during its history read".into()),
					result = work => result,
				};
				let current = custody.finish(result.is_ok());
				let delivered = if current && running.scope.current(generation).is_ok() {
					running
						.history
						.notify(&target, if result.is_ok() { "ready" } else { "failed" }, Some(&result))
				} else {
					Ok(())
				};
				let continued = running.history.pump();
				super::retain(delivered, continued)?;
				Ok(JsValue::UNDEFINED)
			})?;
		}
		Ok(())
	}
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = listenHistory)]
	pub fn listen_history(&self, listener: Option<js_sys::Function>) -> std::result::Result<(), JsValue> {
		self.driver.with_local(|| {
			(if listener.is_some() { self.scope.open() } else { Ok(()) })
				.and_then(|()| self.owner.history.listen(listener))
				.map_err(|error| super::js_error(&error))
		})
	}
}
