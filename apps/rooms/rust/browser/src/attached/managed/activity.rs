//! The local owner supervises membership once. Every viewer, including the
//! local page, consumes the same managed activity reader from its held workspace.
mod files;
mod incoming;
use super::*;
use rooms_glowcap::client::workspace::ActivityReader;
use rooms_runtime::session::managed::{MembershipKinds, MembershipTarget};
use serde_json::json as data;

#[wasm_bindgen]
impl RoomsManagedApplication {
	#[wasm_bindgen(js_name = startRooms)]
	pub fn start_rooms(&self, report: js_sys::Function) -> js_sys::Promise {
		self.driver.submit(0, move |environment| async move {
			let owner = owner(&environment)?;
			let connection = owner
				.opened
				.lock()
				.await
				.session()
				.connection_choice()
				.await
				.map_err(|e| e.to_string())?;
			let locator = match connection {
				workspace::Connection::Relay => owner.reachable(&environment).await?,
				workspace::Connection::Webrtc => {
					let host = environment.runtime.host();
					let key = host.designator().map_err(|e| e.to_string())?;
					let direct = glowcap::Locator::bare(glowcap::TRANSPORT_WEBRTC, &key);
					let relay = owner.reachable(&environment).await?;
					// Keep WebRTC first. This relay advice is scoped to each
					// handoff; it is not a durable identity-route declaration.
					// The relay's Noise channel independently authenticates its
					// key. Node owns serial fallback when WebRTC is unavailable.
					direct.with_hint(
						"alt-locators",
						glowcap::HintValue::String(glowcap::format_locator_uri(&relay).map_err(|e| e.to_string())?),
					)
				}
			};
			environment
				.runtime
				.host()
				.set_advertised_locator(&locator)
				.map_err(|e| e.to_string())?;
			let locator = glowcap::format_locator_uri(&locator).map_err(|e| e.to_string())?;
			let trouble = environment.trouble.clone();
			let mut opened = owner.opened.lock().await;
			let receive = opened.session().activity_receivers();
			opened
				.supervise_workspace(
					&locator,
					environment.platform.clone(),
					MembershipKinds::ALL,
					receive,
					move |state| {
						let output = match state {
							Ok(state) => {
								data!({"ready":state.ready,"failures":state.failures.iter().map(|(target,error)|
							data!({"target":target_data(target),"reason":error.to_string()})).collect::<Vec<_>>()})
							}
							Err(error) => data!({"ready":0,"failures":[],"sourceFailure":error.to_string()}),
						};
						if json(&output.to_string())
							.and_then(|value| super::super::observation::call(&report, value))
							.is_err()
						{
							trouble.report("Rooms activity", "The activity listener refused its report");
						}
					},
				)
				.map_err(|e| e.to_string())?;
			let changes = opened.session().changes().map_err(|e| e.to_string())?;
			drop(opened);
			let mut signaling = owner.signaling.lock().await;
			if signaling.is_none() {
				*signaling = Some(super::signaling::Owner::start(&environment, changes));
			}
			// The page displays this exact advertised locator; it cannot infer it
			// from directory names or reconstruct the Host identity.
			Ok(locator.into())
		})
	}
	#[wasm_bindgen(js_name = retryRooms)]
	pub fn retry_rooms(&self) -> js_sys::Promise {
		self.driver.submit(0, move |environment| async move {
			let owner = owner(&environment)?;
			if let Some(signaling) = owner.signaling.lock().await.as_ref() {
				signaling.retry();
			}
			owner
				.opened
				.lock()
				.await
				.activity()
				.ok_or("Rooms activity is not running")?
				.retry();
			Ok(JsValue::UNDEFINED)
		})
	}
	#[wasm_bindgen(js_name = stopRooms)]
	pub fn stop_rooms(&self) -> js_sys::Promise {
		self.driver.submit(0, move |environment| async move {
			let owner = owner(&environment)?;
			owner.stop_signaling().await?;
			let mut opened = owner.opened.lock().await;
			opened.stop_activity().await.map_err(|e| e.to_string())?;
			opened
				.session()
				.close_received_lines()
				.await
				.map_err(|e| e.to_string())?;
			Ok(JsValue::UNDEFINED)
		})
	}
}
fn target_data(target: &MembershipTarget) -> serde_json::Value {
	let (kind, id) = match target {
		MembershipTarget::Discovery(id) => ("discovery", id),
		MembershipTarget::Directory(id) => ("directory", id),
		MembershipTarget::Room(id) => ("room", id),
		MembershipTarget::Direct(id) => ("direct", id),
	};
	data!({"kind":kind,"id":id})
}
#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = activityReader)]
	pub fn activity_reader(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |_| async move {
			let reader = workspace.activity_reader().await.map_err(|e| e.to_string())?;
			let reader = driver.hold(reader, size_of::<ActivityReader<Platform>>())?;
			Ok(RoomsManagedActivityReader {
				driver,
				workspace,
				reader,
			}
			.into())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsManagedActivityReader {
	driver: Driver,
	workspace: Held<Workspace<Platform>>,
	reader: Held<ActivityReader<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedActivityReader {
	/// Decode one admitted envelope and one JavaScript event projection. Incoming
	/// classification borrows that projection; a second Rust JSON tree would copy
	/// every message leaf solely to inspect its scalar notice kind. Wrappers keep
	/// the exact workspace/token, bounded by Driver admission, never event payloads.
	pub fn read(&self, cursor: js_sys::JsString, wait: bool) -> js_sys::Promise {
		let cursor = match scalar(cursor, 103) {
			Ok(cursor) => cursor,
			Err(error) => return rejected(error),
		};
		let reader = self.reader.clone();
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(103, move |_| async move {
			let raw = reader.read(&cursor, wait).await.map_err(|e| e.to_string())?;
			let envelope: serde_json::Value = serde_json::from_str(&raw).map_err(|_| "Invalid activity delivery")?;
			let token = envelope["cursor"].as_str().ok_or("Missing activity cursor")?;
			let Some(event) = envelope["data"].as_str() else {
				return json(&raw);
			};
			let output = json(event)?;
			if let Some(history) = envelope.get("history") {
				let notice = js_sys::Reflect::get(&output, &"notice".into()).map_err(|_| "Missing activity notice")?;
				super::super::view::set(&notice, "history", json(&history.to_string())?)?;
			}
			let mut files = Vec::new();
			if let Some(descriptions) = envelope["files"].as_array() {
				for (index, description) in descriptions.iter().enumerate() {
					let reader = workspace.activity_file(token, index).await.map_err(|e| e.to_string())?;
					files.push(files::hold(&driver, reader, description.clone())?);
				}
			}
			let handles: js_sys::Array = files.into_iter().map(JsValue::from).collect();
			super::super::view::set(&output, "files", handles.into())?;
			if let Some(role) = envelope.get("incoming").filter(|role| !role.is_null()) {
				let role: custody::Role = serde_json::from_value(role.clone()).map_err(|_| "Invalid incoming role")?;
				let hand = incoming::RoomsManagedIncoming::hold(&driver, (*workspace).clone(), role, token.to_owned())?;
				let notice = js_sys::Reflect::get(&output, &"notice".into()).map_err(|_| "Missing activity notice")?;
				let kind = js_sys::Reflect::get(&notice, &"kind".into()).map_err(|_| "Missing activity notice kind")?;
				let field = if kind == JsValue::from_str("line") {
					"route"
				} else {
					"authority"
				};
				super::super::view::set(&output, field, hand.into())?;
			}
			let result = json(&data!({"cursor":token}).to_string())?;
			if let Some(gap) = envelope.get("gap") {
				super::super::view::set(&result, "gap", json(&gap.to_string())?)?;
			}
			super::super::view::set(&result, "event", output)?;
			Ok(result)
		})
	}
}
