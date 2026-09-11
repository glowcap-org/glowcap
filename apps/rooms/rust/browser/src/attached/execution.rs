use super::{owner::Owner, view, Result, RoomsBrowserSession};
use rooms_application::session::{snapshot::Snapshot, state::OperationId};
use rooms_glowcap::client::session::controller::{self, Observation};
use std::rc::Rc;
use wasm_bindgen::prelude::*;

impl Observation for Owner {
	async fn issue(&self, id: &str, base: u64, name: &str, args: &[String]) -> Result<u64> {
		self.session()?
			.command(id, base, name, args)
			.await
			.map_err(|e| e.to_string())
	}
	async fn resume(&self, id: &str) -> Result<u64> {
		self.session()?.resume_effect(id).await.map_err(|e| e.to_string())
	}
	fn current(&self) -> Result<Rc<Snapshot>> {
		self.scope.open()?;
		self.latest
			.borrow()
			.clone()
			.ok_or_else(|| "the shared Rooms session has not produced a snapshot".into())
	}
	async fn refresh(&self) -> Result<Rc<Snapshot>> {
		let generation = self.scope.generation();
		let snapshot = self.session()?.snapshot().await.map_err(|e| e.to_string())?;
		self.scope.current(generation)?;
		{
			let mut latest = self.latest.borrow_mut();
			if latest
				.as_ref()
				.is_none_or(|old| old.revision.get() <= snapshot.revision.get())
			{
				*latest = Some(Rc::new(snapshot));
			}
		}
		self.changed.notify_waiters();
		self.announce(None)?;
		self.current()
	}
	async fn settle(&self, revision: u64) -> Result<Rc<Snapshot>> {
		let watch = async {
			while self.current()?.revision.get() < revision {
				self.changed.notified().await;
			}
			Ok::<_, String>(())
		};
		tokio::select! { biased;
			() = self.scope.stopped() => return Err("Rooms attachment closed while observing its command".into()),
			result = watch => result?,
			() = gloo_timers::future::TimeoutFuture::new(1_000) => {},
		}
		let mut snapshot = self.current()?;
		if snapshot.revision.get() < revision {
			snapshot = self.refresh().await?;
		}
		if snapshot.revision.get() < revision {
			return Err(format!(
				"the attached Rooms session snapshot stayed at revision {} after revision {revision}",
				snapshot.revision.get()
			));
		}
		Ok(snapshot)
	}
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = encodeWorkspace)]
	pub fn encode_workspace(&self, choices: js_sys::JsString) -> std::result::Result<String, JsValue> {
		let result = (|| {
			let choices = super::scalar(choices, rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS)?;
			let snapshot = self.owner.current()?;
			rooms_application::workspace::Workspace::compose(
				&choices,
				snapshot.checkpoint.clone(),
				&rooms_glowcap::routes::CheckpointRoutes,
			)
			.and_then(|workspace| workspace.encode())
			.map_err(|e| e.to_string())
		})();
		result.map_err(|e| super::js_error(&e))
	}

	#[wasm_bindgen(js_name = settleRevision)]
	pub fn settle_revision(&self, revision: f64) -> js_sys::Promise {
		let revision = match super::safe_integer(revision) {
			Ok(revision) => revision,
			Err(error) => return super::rejected(error),
		};
		let owner = self.owner.clone();
		self.driver.submit(0, move |_| async move {
			let snapshot = owner.settle(revision).await?;
			view::snapshot(&snapshot)
		})
	}

	#[wasm_bindgen(js_name = acceptInvitation)]
	pub fn accept_invitation(&self, invitation: js_sys::JsString) -> js_sys::Promise {
		let invitation = match super::scalar(invitation, 65_536) {
			Ok(invitation) => invitation,
			Err(error) => return super::rejected(error),
		};
		let conversation = match self.owner.operation_id() {
			Ok(id) => id,
			Err(error) => return super::rejected(error),
		};
		let arguments = js_sys::Array::new();
		arguments.push(&JsValue::from_str(&invitation));
		arguments.push(&JsValue::from_str(&conversation));
		self.run_command(None, "acceptInvitation".into(), arguments)
	}

	#[wasm_bindgen(js_name = runCommand)]
	pub fn run_command(
		&self,
		operation: Option<js_sys::JsString>,
		name: js_sys::JsString,
		arguments: js_sys::Array,
	) -> js_sys::Promise {
		let operation = match operation {
			Some(id) => id,
			None => match self.owner.operation_id() {
				Ok(id) => id.into(),
				Err(error) => return super::rejected(error),
			},
		};
		let (operation, name, arguments, bytes) = match super::command_input(operation, name, arguments) {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			let _serial = owner.lock().await?;
			owner.scope.current(generation)?;
			if matches!(name.as_str(), "select" | "acceptInvitation") {
				let snapshot = owner.current()?;
				if let Some(active) = snapshot.checkpoint.active() {
					owner.flush_draft(active).await?;
				}
			}
			let id = OperationId::new(operation.into()).ok_or("Invalid Rooms operation identity")?;
			let result = controller::run(owner.as_ref(), &owner.commands, id, &name, &arguments).await;
			let announcement = owner.announce(None);
			match result {
				Ok(snapshot) => {
					announcement?;
					view::snapshot(&snapshot)
				}
				Err(error) => Err(super::retain(Err(error), announcement).unwrap_err()),
			}
		})
	}
	pub fn driving(&self) -> js_sys::Array {
		self.owner
			.commands
			.driving()
			.iter()
			.map(|id| super::view::document(id.text()))
			.collect()
	}
}

impl Owner {
	/// The caller holds the mutation lock through this external effect and its
	/// acknowledgement observation. Failure exposes the remote pending ID.
	pub async fn external(
		&self,
		operation: &str,
		work: impl std::future::Future<Output = Result<JsValue>>,
	) -> Result<JsValue> {
		let id = OperationId::new(operation.into()).ok_or("Invalid Rooms operation identity")?;
		let active = self.commands.external(id).map_err(|error| error.to_string())?;
		let result = work.await;
		drop(active);
		let announced = self.announce(None);
		match result {
			Ok(value) => {
				announced?;
				Ok(value)
			}
			Err(error) => Err(super::retain(Err(error), announced).unwrap_err()),
		}
	}
}
