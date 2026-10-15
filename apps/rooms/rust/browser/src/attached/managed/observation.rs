//! Registration, cursor and cancellation remain exact independently held
//! capabilities. A UI retry submits the same sequence and source.
use super::*;
use glowcap::loam::{ObservationCursor, ObservedDescription};
use rooms_glowcap::client::access::{Observation, ObservationRequest};

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = prepareObservation)]
	pub fn prepare_observation(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |environment| async move {
			let sequence = workspace.mutation_sequence().await.map_err(|e| e.to_string())?;
			use rooms_runtime::entropy::Entropy;
			let mut identity = [0; 16];
			environment
				.platform
				.clone()
				.fill(&mut identity)
				.map_err(|e| e.to_string())?;
			let request = ObservationRequest::new_live(sequence, identity).map_err(|e| e.to_string())?;
			let request = driver.hold(request, size_of::<ObservationRequest>() + 12 + 16)?;
			Ok(RoomsManagedObservationRequest {
				driver,
				workspace,
				request,
			}
			.into())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsManagedObservationRequest {
	driver: Driver,
	workspace: Held<Workspace<Platform>>,
	request: Held<ObservationRequest>,
}
#[wasm_bindgen]
impl RoomsManagedObservationRequest {
	pub fn submit(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		let request = self.request.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |_| async move {
			let observation = workspace.observe(&request).await.map_err(|e| e.to_string())?;
			let observation = driver.hold(observation, size_of::<Observation<Platform>>())?;
			Ok(RoomsManagedObservation { driver, observation }.into())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsManagedObservation {
	driver: Driver,
	observation: Held<Observation<Platform>>,
}
fn cursor(raw: js_sys::Uint8Array) -> Result<ObservationCursor> {
	if raw.length() != 56 {
		return Err("Invalid observation cursor".into());
	}
	let mut cursor = [0; 56];
	raw.copy_to(&mut cursor);
	Ok(cursor)
}
#[wasm_bindgen]
impl RoomsManagedObservation {
	pub fn poll(&self, position: Option<js_sys::Uint8Array>) -> js_sys::Promise {
		let position = match position.map(cursor).transpose() {
			Ok(position) => position,
			Err(error) => return rejected(error),
		};
		let observation = self.observation.clone();
		self.driver.submit(56, move |_| async move {
			let reply = observation.poll(position.as_ref()).await.map_err(|e| e.to_string())?;
			project(reply.view())
		})
	}
	pub fn receive(&self, position: js_sys::Uint8Array) -> js_sys::Promise {
		let position = match cursor(position) {
			Ok(position) => position,
			Err(error) => return rejected(error),
		};
		let observation = self.observation.clone();
		self.driver.submit(56, move |_| async move {
			let reply = observation.receive(&position).await.map_err(|e| e.to_string())?;
			project(reply.view())
		})
	}
	/// Free releases local custody. Cancel retires the durable registration and
	/// keeps this exact handle available if its acknowledgement is lost.
	pub fn cancel(&self) -> js_sys::Promise {
		let observation = self.observation.clone();
		self.driver.submit(0, move |_| async move {
			observation.cancel().await.map(Into::into).map_err(|e| e.to_string())
		})
	}
}
fn project(view: glowcap::loam::ObservationDescription<'_>) -> Result<JsValue> {
	let source = match view.source {
		ObservedDescription::Control(control) => projection::control(control),
		ObservedDescription::Use(access) => projection::use_access(access),
	};
	let output = json(&serde_json::json!({"source": source, "changed": view.changed, "resync": view.resync, "notices": {"access": view.notices.access, "target": view.notices.target, "inventory": view.notices.inventory, "management": view.notices.management, "subtree": view.notices.subtree}}).to_string())?;
	js_sys::Reflect::set(
		&output,
		&"cursor".into(),
		&js_sys::Uint8Array::from(view.cursor.as_slice()),
	)
	.map_err(|_| "Observation cursor projection failed")?;
	Ok(output)
}
