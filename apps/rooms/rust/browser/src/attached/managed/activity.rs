//! The local owner supervises membership once. Every viewer, including the
//! local page, consumes the same managed activity reader from its held workspace.
use rooms_runtime::Error as RuntimeError;
mod files;
mod incoming;
use super::*;
use rooms_application::content::session::workspace::DirectRoute;
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
				.await?;
			let route = connection.route(environment.front.is_some());
			let host = environment.runtime.host();
			let key = host.designator().map_err(RuntimeError::from)?;
			let direct = glowcap::Locator::bare(glowcap::TRANSPORT_WEBRTC, &key);
			let uri = |locator: &glowcap::Locator| glowcap::format_locator_uri(locator).map_err(RuntimeError::from);
			// `hello` is the one location this Host states in its CapTP hello,
			// so it is a concrete transport. `advertised` is what the directory
			// lists for this member and embeds in the handoffs it mints for
			// this member's inbox, and may be the identity route across both.
			let (hello, advertised) = match route {
				DirectRoute::Relay => {
					let relay = owner.relay_locator(&environment).await?;
					(relay.clone(), relay)
				}
				// With no Rooms server, the direct route is the only one.
				DirectRoute::Webrtc => (direct.clone(), direct),
				// The hello names WebRTC with the relay as advice a dialing
				// Host tries after WebRTC fails, and the directory lists that
				// same locator.
				DirectRoute::WebrtcThenRelay => {
					let relay = owner.relay_locator(&environment).await?;
					let hinted = direct.with_hint(glowcap::HINT_ALT_LOCATORS, glowcap::HintValue::String(uri(&relay)?));
					(hinted.clone(), hinted)
				}
				// The hello keeps the same hinted WebRTC location, and the
				// directory lists one identity route naming both, which a
				// dialing Host races, keeping the first to prove this key
				// (ADR-0036).
				DirectRoute::Raced => {
					let relay = owner.relay_locator(&environment).await?;
					let raced = rooms_glowcap::routes::identity_route(&key, &[uri(&direct)?, uri(&relay)?])
						.ok_or_else(|| RuntimeError::invalid("Rooms could not compose its identity route"))?;
					let hinted = direct.with_hint(glowcap::HINT_ALT_LOCATORS, glowcap::HintValue::String(uri(&relay)?));
					(hinted, raced)
				}
			};
			environment
				.runtime
				.host()
				.set_advertised_locator(&hello)
				.map_err(RuntimeError::from)?;
			let locator = uri(&advertised)?;
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
							data!({"target":target_data(target),"reason":error.to_string(),"failure":crate::failure::project(error).value()})).collect::<Vec<_>>()})
							}
							Err(error) => data!({"ready":0,"failures":[],"sourceFailure":error.to_string(),"failure":crate::failure::project(&error).value()}),
						};
						if json(&output.to_string())
							.and_then(|value| super::super::observation::call(&report, value))
							.is_err()
						{
							trouble.report("Rooms activity", &RuntimeError::platform_message("The activity listener refused its report"));
						}
					},
				)?;
			let changes = opened.session().changes()?;
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
	/// Report the page relay's registration to `report` as it changes: null
	/// while this browser is reachable through it, or the reason it is not.
	/// Call after `startRooms`, which starts the relay.
	#[wasm_bindgen(js_name = observeRelay)]
	pub fn observe_relay(&self, report: js_sys::Function) -> js_sys::Promise {
		self.driver.submit(0, move |environment| async move {
			let owner = owner(&environment)?;
			let relay = owner.relay.lock().await;
			let relay = relay
				.as_ref()
				.ok_or_else(|| RuntimeError::invalid("Rooms has not started its relay"))?;
			let trouble = environment.trouble.clone();
			relay.observe(move |failure| {
				let failure = failure.map_or(JsValue::NULL, JsValue::from);
				if report.call1(&JsValue::UNDEFINED, &failure).is_err() {
					trouble.report(
						"Rooms relay",
						&RuntimeError::platform_message("The relay listener refused its report"),
					);
				}
			});
			Ok(JsValue::UNDEFINED)
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
				.ok_or_else(|| RuntimeError::invalid("Rooms activity is not running"))?
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
			opened.stop_activity().await?;
			opened.session().close_received_lines().await?;
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
			let reader = workspace.activity_reader().await.map_err(RuntimeError::from)?;
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
	/// classification borrows that projection. A second Rust JSON tree would copy
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
			let raw = reader.read(&cursor, wait).await.map_err(RuntimeError::from)?;
			let envelope: serde_json::Value =
				serde_json::from_str(&raw).map_err(|_| RuntimeError::invalid("Invalid activity delivery"))?;
			let token = envelope["cursor"]
				.as_str()
				.filter(|token| token.len() <= 103)
				.ok_or_else(|| RuntimeError::invalid("Invalid activity cursor"))?;
			let head = envelope["head"]
				.as_str()
				.filter(|head| head.len() <= 103)
				.ok_or_else(|| RuntimeError::invalid("Invalid activity head"))?;
			let Some(event) = envelope["data"].as_str() else {
				return json(&raw);
			};
			let output = json(event)?;
			// The journal's own time for the event, so a page that reads it
			// later presents it when it happened.
			let at = envelope
				.get("at")
				.filter(|at| at.is_u64())
				.ok_or_else(|| RuntimeError::invalid("Missing activity time"))?;
			super::super::view::set(&output, "at", json(&at.to_string())?)?;
			if let Some(history) = envelope.get("history") {
				let notice = js_sys::Reflect::get(&output, &"notice".into())
					.map_err(|_| RuntimeError::invalid("Missing activity notice"))?;
				super::super::view::set(&notice, "history", json(&history.to_string())?)?;
			}
			let mut files = Vec::new();
			if let Some(descriptions) = envelope["files"].as_array() {
				for (index, description) in descriptions.iter().enumerate() {
					// Optional byte access cannot consume or block the message that
					// carries it. Keep metadata and the exact selection for opening
					// or retry; acquisition still checks the current file permission.
					let reader = workspace
						.activity_file(token, index)
						.await
						.map_err(|_| files::Selection {
							workspace: workspace.clone(),
							token: token.to_owned(),
							index,
						});
					files.push(files::hold(&driver, reader, description.clone())?);
				}
			}
			let handles: js_sys::Array = files.into_iter().map(JsValue::from).collect();
			super::super::view::set(&output, "files", handles.into())?;
			if let Some(role) = envelope.get("incoming").filter(|role| !role.is_null()) {
				let role: custody::Role =
					serde_json::from_value(role.clone()).map_err(|_| RuntimeError::invalid("Invalid incoming role"))?;
				let hand = incoming::RoomsManagedIncoming::hold(&driver, (*workspace).clone(), role, token.to_owned())?;
				let notice = js_sys::Reflect::get(&output, &"notice".into())
					.map_err(|_| RuntimeError::invalid("Missing activity notice"))?;
				let kind = js_sys::Reflect::get(&notice, &"kind".into())
					.map_err(|_| RuntimeError::invalid("Missing activity notice kind"))?;
				let field = if kind == JsValue::from_str("line") {
					"route"
				} else {
					"authority"
				};
				super::super::view::set(&output, field, hand.into())?;
			}
			let result = json(&data!({"cursor":token,"head":head}).to_string())?;
			if let Some(gap) = envelope.get("gap") {
				super::super::view::set(&result, "gap", json(&gap.to_string())?)?;
			}
			super::super::view::set(&result, "event", output)?;
			Ok(result)
		})
	}
}
