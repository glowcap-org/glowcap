//! Workspace attachment runs on the page Host. A provisional view is retired
//! before completion; sibling capabilities use the already-held connection.
use super::{
	connections, driver::Driver, owner::Owner, Environment, Result, RoomsBrowserApplication, RoomsBrowserSession,
};
use crate::workspace_persistence::{Inner as Persistence, RoomsWorkspacePersistence};
use rooms_application::{
	session::{checkpoint::Checkpoint, snapshot::views::Adoption},
	workspace::transition::Attachment,
};
use rooms_glowcap::client::session::controller::Observation;
use serde::{Deserialize, Serialize};
use std::rc::Rc;
use wasm_bindgen::prelude::*;

#[derive(Default, Deserialize, Serialize)]
struct Outcome {
	workspace: Option<String>,
	cleanup: Option<String>,
}
fn finish(result: Result<Outcome>, cleanup: Result<()>) -> Result<Outcome> {
	match (result, cleanup) {
		(Ok(mut outcome), Err(reason)) => {
			outcome.cleanup = Some(match outcome.cleanup {
				Some(first) => format!("{first}; cleanup: {reason}"),
				None => reason,
			});
			Ok(outcome)
		}
		(Err(reason), cleanup) => Err(super::retain(Err(reason), cleanup).unwrap_err()),
		(result, _) => result,
	}
}
fn encode(result: Result<Outcome>) -> Result<JsValue> {
	serde_json::to_string(&result?)
		.map(JsValue::from)
		.map_err(|e| e.to_string())
}

#[wasm_bindgen]
impl RoomsBrowserApplication {
	/// Setup has no page Host. Own the temporary driver through physical close.
	#[wasm_bindgen(js_name = selectWorkspace)]
	pub fn select_workspace(
		persistence: &RoomsWorkspacePersistence,
		link: js_sys::JsString,
		home: js_sys::JsString,
	) -> js_sys::Promise {
		let persistence = persistence.handle();
		let (plan, home) = match prepare(&persistence, link, home) {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		if plan.unchanged {
			return js_sys::Promise::resolve(&encode(Ok(Outcome::default())).expect("empty outcome"));
		}
		let driver = Driver::start();
		let pending = submit(&driver, None, persistence, plan, home);
		wasm_bindgen_futures::future_to_promise(async move {
			let result = wasm_bindgen_futures::JsFuture::from(pending)
				.await
				.map_err(reason)
				.and_then(|value| {
					serde_json::from_str::<Outcome>(&value.as_string().ok_or("Rooms attachment returned no outcome")?)
						.map_err(|e| e.to_string())
				});
			let cleanup = wasm_bindgen_futures::JsFuture::from(driver.close())
				.await
				.map(|_| ())
				.map_err(reason);
			encode(finish(result, cleanup)).map_err(|e| super::js_error(&e))
		})
	}
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = selectWorkspace)]
	pub fn select_workspace(
		&self,
		persistence: &RoomsWorkspacePersistence,
		link: js_sys::JsString,
		home: js_sys::JsString,
	) -> js_sys::Promise {
		let persistence = persistence.handle();
		let (plan, home) = match prepare(&persistence, link, home) {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		submit(&self.driver, Some(self.owner.clone()), persistence, plan, home)
	}
}
fn prepare(persistence: &Persistence, link: js_sys::JsString, home: js_sys::JsString) -> Result<(Attachment, String)> {
	let link = super::scalar(link, 16_384)?;
	let home = super::scalar(home, 65_536)?;
	let plan = Attachment::new(
		persistence.read()?.controller(),
		link,
		&rooms_glowcap::routes::CheckpointRoutes,
	)
	.map_err(str::to_owned)?;
	Ok((plan, home))
}
fn submit(
	driver: &Driver,
	current: Option<Rc<Owner>>,
	persistence: Rc<Persistence>,
	plan: Attachment,
	home: String,
) -> js_sys::Promise {
	let driver_copy = driver.clone();
	// At most one attachment per workspace. The driver accounts for the bounded
	// checkpoint retained during adoption as well as the locator inputs.
	driver.submit(
		plan.link().len() + home.len() + 3 * rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS,
		move |environment| async move {
			let _transition = persistence
				.transition
				.try_lock()
				.map_err(|_| "A Rooms controller change is already running")?;
			encode(attach(environment, driver_copy, current, &persistence, plan, home).await)
		},
	)
}
async fn attach(
	environment: Rc<Environment>,
	driver: Driver,
	current: Option<Rc<Owner>>,
	persistence: &Rc<Persistence>,
	plan: Attachment,
	home: String,
) -> Result<Outcome> {
	if plan.unchanged {
		return Ok(Outcome::default());
	}
	let generation = current.as_ref().map(|owner| owner.scope.generation());
	let check = |plan: &Attachment| -> Result<()> {
		driver.require_open()?;
		if let (Some(owner), Some(generation)) = (&current, generation) {
			owner.scope.current(generation)?;
		}
		plan.check(persistence.read()?.controller()).map_err(str::to_owned)
	};
	check(&plan)?;
	if plan.same_peer {
		if let Some(owner) = &current {
			owner.verify_sibling(plan.link().into()).await?;
			check(&plan)?;
			if plan.keeps_hosting() {
				return Ok(Outcome::default());
			}
			return persistence.commit_attachment(plan, None).map(|workspace| Outcome {
				workspace: Some(workspace),
				cleanup: None,
			});
		}
	}
	let scope = driver.scope()?;
	let provisional = Owner::open(environment, driver.clone(), scope, plan.link().into(), Some(home)).await?;
	let result = async {
		check(&plan)?;
		let mut snapshot = provisional.refresh().await?;
		let mut adopted_local = false;
		if snapshot.workspace_adoption == Adoption::Available {
			check(&plan)?;
			let checkpoint = if plan.adopts_local() {
				if let Some(owner) = &current {
					let _serial = owner.lock().await?;
					if let Some(active) = owner.current()?.checkpoint.active() { owner.flush_draft(active).await?; }
					owner.current()?.checkpoint.clone()
				} else { persistence.read()?.into_session() }
			} else { Rc::new(Checkpoint::empty()) };
			let operation = provisional.operation_id()?;
			let revision = provisional.remote_session()?.adopt_workspace(&operation, snapshot.revision.get(), &checkpoint).await.map_err(|e| e.to_string())?;
			adopted_local = plan.adopts_local();
			snapshot = provisional.refresh().await?;
			if snapshot.revision.get() < revision { return Err("The shared session did not confirm workspace adoption".into()); }
		}
		check(&plan)?;
		let workspace = persistence.commit_attachment(plan, Some(snapshot.checkpoint.clone())).map_err(|reason| {
			if adopted_local { format!("The shared session adopted this workspace, but this browser could not remember it: {reason} Retry the same capability to finish attaching.") }
			else { reason }
		})?;
		Ok(Outcome { workspace: Some(workspace), cleanup: None })
	}.await;
	provisional.stop();
	let cleanup = connections::terminal(&mut provisional.ended.clone()).await;
	finish(result, cleanup)
}
fn reason(error: JsValue) -> String {
	use wasm_bindgen::JsCast;
	if let Some(error) = error.dyn_ref::<js_sys::Error>() {
		error.message().into()
	} else {
		error.as_string().unwrap_or_else(|| "Rooms attachment failed".into())
	}
}
