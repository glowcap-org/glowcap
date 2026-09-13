//! Typed session actions at the browser boundary. Parsing and effects stay in
//! the shared application and client; JavaScript receives presentation data.
use super::endpoint::Endpoint;
use super::{Result, RoomsBrowserSession, rejected, safe_integer, scalar, view};
use rooms_application::{grants::Rights, session::checkpoint::Checkpoint};
use rooms_glowcap::client::session::controller::Observation;
use rooms_glowcap::{client::session::GrantPatch, routes::CheckpointRoutes};
use std::future::Future;
use wasm_bindgen::prelude::*;

impl RoomsBrowserSession {
	pub(super) fn action<T: 'static, F, W>(&self, input: Result<T>, bytes: usize, work: F) -> js_sys::Promise
	where
		F: FnOnce(Endpoint, T) -> W + 'static,
		W: Future<Output = Result<JsValue>> + 'static,
	{
		self.dispatch(input, bytes, false, work)
	}
	pub(super) fn mutation<T: 'static, F, W>(&self, input: Result<T>, bytes: usize, work: F) -> js_sys::Promise
	where
		F: FnOnce(Endpoint, T) -> W + 'static,
		W: Future<Output = Result<JsValue>> + 'static,
	{
		self.dispatch(input, bytes, true, work)
	}
	pub(super) fn observed_mutation<T: 'static, F, W>(&self, input: Result<T>, bytes: usize, work: F) -> js_sys::Promise
	where
		F: FnOnce(Endpoint, T) -> W + 'static,
		W: Future<Output = Result<JsValue>> + 'static,
	{
		let owner = self.owner.clone();
		self.mutation(input, bytes, move |session, input| async move {
			let result = work(session, input).await?;
			owner.refresh().await?;
			Ok(result)
		})
	}
	fn dispatch<T: 'static, F, W>(&self, input: Result<T>, bytes: usize, serialized: bool, work: F) -> js_sys::Promise
	where
		F: FnOnce(Endpoint, T) -> W + 'static,
		W: Future<Output = Result<JsValue>> + 'static,
	{
		let input = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		if let Err(error) = self.scope.open() {
			return rejected(error);
		}
		let session = match self.owner.session() {
			Ok(session) => session,
			Err(error) => return rejected(error),
		};
		let scope = self.scope.clone();
		let generation = scope.generation();
		let owner = self.owner.clone();
		self.driver.submit(bytes, move |_| async move {
			let _serial = if serialized { Some(owner.lock().await?) } else { None };
			scope.current(generation)?;
			let result = work(session, input).await;
			scope.current(generation)?;
			result
		})
	}
}
pub(super) fn text(value: js_sys::JsString) -> Result<String> {
	scalar(value, 65_536)
}
fn rights(value: &str) -> Result<Rights> {
	match value {
		"observe" => Ok(Rights::Observe),
		"interact" => Ok(Rights::Interact),
		"admin" => Ok(Rights::Admin),
		_ => Err("Unknown Rooms grant rights".into()),
	}
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = replaceCheckpoint)]
	pub fn replace_checkpoint(
		&self,
		operation: Option<js_sys::JsString>,
		base: Option<f64>,
		checkpoint: js_sys::JsString,
		adopt: bool,
	) -> js_sys::Promise {
		let bytes = 3 * (operation.as_ref().map_or(0, |id| id.length() as usize) + checkpoint.length() as usize);
		let input = (|| {
			Ok((
				operation
					.map(text)
					.transpose()?
					.map_or_else(|| self.owner.operation_id(), Ok)?,
				base.map(safe_integer).transpose()?,
				scalar(checkpoint, 512 * 1024)?,
			))
		})();
		let owner = self.owner.clone();
		self.mutation(input, bytes, move |session, (operation, base, json)| async move {
			let checkpoint = Checkpoint::decode(&json, &CheckpointRoutes).map_err(|e| e.to_string())?;
			let revision_base = base.map_or_else(|| owner.current().map(|snapshot| snapshot.revision.get()), Ok)?;
			let revision = if adopt {
				session.adopt_workspace(&operation, revision_base, checkpoint).await
			} else {
				session.replace_checkpoint(&operation, revision_base, checkpoint).await
			}
			.map_err(|e| e.to_string())?;
			if base.is_none() {
				let snapshot = owner.settle(revision).await?;
				view::snapshot(&snapshot)
			} else {
				Ok(JsValue::from(revision as f64))
			}
		})
	}
	#[wasm_bindgen(js_name = resolveEffect)]
	pub fn resolve_effect(&self, operation: js_sys::JsString, committed: bool) -> js_sys::Promise {
		let bytes = operation.length() as usize * 3;
		self.observed_mutation(text(operation), bytes, move |session, operation| async move {
			session
				.resolve_effect(&operation, committed)
				.await
				.map_err(|e| e.to_string())?;
			Ok(JsValue::UNDEFINED)
		})
	}
	#[wasm_bindgen(js_name = resumeEffect)]
	pub fn resume_effect(&self, operation: js_sys::JsString) -> js_sys::Promise {
		let bytes = operation.length() as usize * 3;
		let owner = self.owner.clone();
		self.mutation(text(operation), bytes, move |session, operation| async move {
			let revision = session.resume_effect(&operation).await.map_err(|e| e.to_string())?;
			owner.settle(revision).await?;
			Ok(JsValue::from(revision as f64))
		})
	}

	#[wasm_bindgen(js_name = ignoredNickname)]
	pub fn ignored_nickname(
		&self,
		conversation: js_sys::JsString,
	) -> std::result::Result<Option<js_sys::JsString>, JsValue> {
		self.scope
			.open()
			.and_then(|()| {
				let conversation = text(conversation)?;
				let snapshot = self.owner.current()?;
				Ok(snapshot
					.checkpoint
					.ignored_nickname(&conversation)
					.map(|nick| view::document(nick).unchecked_into()))
			})
			.map_err(|error| super::js_error(&error))
	}
	#[wasm_bindgen(js_name = roomBridgeForm)]
	pub fn room_bridge_form(&self, conversation: js_sys::JsString) -> js_sys::Promise {
		let bytes = conversation.length() as usize * 3;
		self.action(text(conversation), bytes, |session, conversation| async move {
			view::json(&session.bridge_form(&conversation).await.map_err(|e| e.to_string())?)
		})
	}
	#[wasm_bindgen(js_name = issueGrant)]
	pub fn issue_grant(
		&self,
		id: js_sys::JsString,
		access: js_sys::JsString,
		label: js_sys::JsString,
		history: bool,
	) -> js_sys::Promise {
		let bytes = 3 * (id.length() + access.length() + label.length()) as usize;
		let input = (|| Ok((text(id)?, rights(&text(access)?)?, text(label)?)))();
		self.observed_mutation(input, bytes, move |session, (id, rights, label)| async move {
			view::json(
				&session
					.issue_grant(&id, rights, &label, history)
					.await
					.map_err(|e| e.to_string())?,
			)
		})
	}
	#[wasm_bindgen(js_name = revokeGrant)]
	pub fn revoke_grant(&self, id: js_sys::JsString) -> js_sys::Promise {
		let bytes = id.length() as usize * 3;
		self.observed_mutation(text(id), bytes, |session, id| async move {
			session.revoke_grant(&id).await.map_err(|e| e.to_string())?;
			Ok(JsValue::UNDEFINED)
		})
	}
	#[wasm_bindgen(js_name = changeGrant)]
	pub fn change_grant(
		&self,
		id: js_sys::JsString,
		access: Option<js_sys::JsString>,
		history: Option<bool>,
		suspended: Option<bool>,
		note: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let bytes = 3
			* (id.length() as usize
				+ access.as_ref().map_or(0, |s| s.length() as usize)
				+ note.as_ref().map_or(0, |s| s.length() as usize));
		let input = (|| {
			Ok((
				text(id)?,
				access.map(|s| rights(&text(s)?)).transpose()?,
				note.map(text).transpose()?,
			))
		})();
		self.observed_mutation(input, bytes, move |session, (id, rights, note)| async move {
			view::json(
				&session
					.set_grant_policy(
						&id,
						GrantPatch {
							rights,
							history,
							suspended,
							note: note.as_deref(),
						},
					)
					.await
					.map_err(|e| e.to_string())?,
			)
		})
	}
}
