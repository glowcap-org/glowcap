//! Per-view draft custody and delayed persistence live with the attachment.
//! Supersession wakes accepted timers; dropping a JS promise does not cancel a save.
use super::{js_error, rejected, view, Result, RoomsBrowserSession};
use rooms_application::{session::state::OperationId, text::DocumentText};
use rooms_glowcap::client::session::controller::{self, Observation};
use wasm_bindgen::prelude::*;

fn text(value: js_sys::JsString) -> Result<DocumentText> {
	crate::commands::read_text(value, 65_536).map_err(|error| error.to_string())
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = stageDraft)]
	pub fn stage_draft(
		&self,
		conversation: js_sys::JsString,
		value: js_sys::JsString,
	) -> std::result::Result<(), JsValue> {
		let result = (|| {
			self.scope.open()?;
			self.owner
				.drafts
				.borrow_mut()
				.stage(text(conversation)?, text(value)?)
				.map_err(|e| e.to_string())?;
			self.owner.draft_changed.notify_waiters();
			Ok(())
		})();
		result.map_err(|e: String| js_error(&e))
	}
	#[wasm_bindgen(js_name = pendingDraft)]
	pub fn pending_draft(&self, conversation: js_sys::JsString) -> std::result::Result<JsValue, JsValue> {
		let key = text(conversation).map_err(|e| js_error(&e))?;
		Ok(self
			.owner
			.drafts
			.borrow()
			.pending(&key)
			.map_or(JsValue::UNDEFINED, view::document))
	}
	#[wasm_bindgen(js_name = cancelDraftSave)]
	pub fn cancel_draft_save(&self, conversation: js_sys::JsString) -> std::result::Result<(), JsValue> {
		let key = text(conversation).map_err(|e| js_error(&e))?;
		self.owner
			.drafts
			.borrow_mut()
			.cancel_save(&key)
			.map_err(|e| js_error(&e.to_string()))?;
		self.owner.draft_changed.notify_waiters();
		Ok(())
	}
	#[wasm_bindgen(js_name = retireDraft)]
	pub fn retire_draft(&self, conversation: js_sys::JsString) -> std::result::Result<(), JsValue> {
		let key = text(conversation).map_err(|e| js_error(&e))?;
		self.owner.drafts.borrow_mut().retire(&key);
		self.owner.draft_changed.notify_waiters();
		Ok(())
	}
	#[wasm_bindgen(js_name = clearSentDraft)]
	pub fn clear_sent_draft(&self, conversation: js_sys::JsString) -> js_sys::Promise {
		let key = match text(conversation.clone()) {
			Ok(key) => key,
			Err(error) => return rejected(error),
		};
		let clear = self
			.owner
			.drafts
			.borrow()
			.pending(&key)
			.is_some_and(|value| value.as_str() == Some(""));
		if clear {
			self.save_draft(conversation, "".into(), false)
		} else {
			match self.owner.current().and_then(|snapshot| view::snapshot(&snapshot)) {
				Ok(snapshot) => js_sys::Promise::resolve(&snapshot),
				Err(error) => rejected(error),
			}
		}
	}
	#[wasm_bindgen(js_name = saveDraft)]
	pub fn save_draft(
		&self,
		conversation: js_sys::JsString,
		value: js_sys::JsString,
		delayed: bool,
	) -> js_sys::Promise {
		let input = (|| {
			self.scope.open()?;
			let key = text(conversation)?;
			let value = text(value)?;
			let token = self
				.owner
				.drafts
				.borrow_mut()
				.stage(key.clone(), value.clone())
				.map_err(|e| e.to_string())?;
			self.owner.draft_changed.notify_waiters();
			Ok((key, value, token))
		})();
		let (key, value, token) = match input {
			Ok(input) => input,
			Err(e) => return rejected(e),
		};
		let owner = self.owner.clone();
		let generation = self.scope.generation();
		self.driver
			.submit(key.heap_bytes() + value.heap_bytes(), move |environment| async move {
				let outcome = async {
					let timer = gloo_timers::future::TimeoutFuture::new(if delayed { 150 } else { 0 });
					tokio::pin!(timer);
					loop {
						if owner.drafts.borrow().token(&key) != Some(token) {
							return view::snapshot(owner.current()?.as_ref());
						}
						tokio::select! { biased;
							() = owner.scope.stopped() => return Err("Rooms attachment closed before saving its draft".into()),
							() = owner.draft_changed.notified() => {},
							() = &mut timer => break,
						}
					}
					let _serial = owner.lock().await?;
					owner.scope.current(generation)?;
					if owner.drafts.borrow().token(&key) != Some(token) {
						return view::snapshot(owner.current()?.as_ref());
					}
					let id = rooms_runtime::entropy::random_id(&mut environment.platform.clone(), "")?;
					let id = OperationId::new(id.text().clone()).ok_or("Invalid Rooms operation identity")?;
					let args = [
						key.as_str()
							.ok_or("Rooms conversation identity requires scalar text")?
							.to_owned(),
						value
							.as_str()
							.ok_or("Rooms draft cannot be represented by the session wire text")?
							.to_owned(),
					];
					let result = controller::run(owner.as_ref(), &owner.commands, id, "setDraft", &args).await;
					let announced = owner.announce(None);
					match result {
						Ok(snapshot) => {
							announced?;
							view::snapshot(&snapshot)
						}
						Err(error) => Err(super::retain(Err(error), announced).unwrap_err()),
					}
				}
				.await;
				owner.drafts.borrow_mut().finish(&key, token);
				outcome
			})
	}
}

impl super::owner::Owner {
	/// Called under the mutation lock before changing selection. The old timer
	/// is invalidated before issuing, so it cannot repeat a failed flush later.
	pub async fn flush_draft(&self, conversation: &DocumentText) -> Result<()> {
		let pending = {
			let mut drafts = self.drafts.borrow_mut();
			drafts.cancel_save(conversation).map_err(|error| error.to_string())?;
			drafts.pending(conversation).cloned().zip(drafts.token(conversation))
		};
		self.draft_changed.notify_waiters();
		let Some((text, token)) = pending else { return Ok(()) };
		let id = OperationId::new(self.operation_id()?.into()).ok_or("Invalid Rooms operation identity")?;
		let args = [
			conversation
				.as_str()
				.ok_or("Rooms conversation identity requires scalar text")?
				.to_owned(),
			text.as_str()
				.ok_or("Rooms draft cannot be represented by the session wire text")?
				.to_owned(),
		];
		controller::run(self, &self.commands, id, "setDraft", &args).await?;
		self.drafts.borrow_mut().finish(conversation, token);
		Ok(())
	}
}
