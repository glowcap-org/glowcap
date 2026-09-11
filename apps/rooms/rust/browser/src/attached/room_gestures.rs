//! Rust owns gesture identities and durable intent material; the UI supplies choices.
use super::{view, RoomsBrowserSession};
use rooms_application::{grants::Access, room::policy::RoomPolicy, session::state::OperationId};
use rooms_glowcap::client::session::controller::{self, Observation};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = joinDestination)]
	pub fn join_destination(
		&self,
		destination: js_sys::JsString,
		nick: js_sys::JsString,
		default_directory: js_sys::JsString,
		signal: Option<web_sys::AbortSignal>,
	) -> js_sys::Promise {
		let bytes = 3 * (destination.length() as usize + nick.length() as usize + default_directory.length() as usize);
		let input = (|| {
			let request: rooms_glowcap::routes::joining::Request =
				serde_json::from_str(&super::scalar(destination, 65_536)?).map_err(|e| e.to_string())?;
			let nick = super::scalar(nick, 32)?;
			if let Some(error) = rooms_application::room::inbox::nick_refusal(&nick) {
				return Err(error);
			}
			let default = super::scalar(default_directory, 16384)?;
			let snapshot = self.owner.current()?;
			if !matches!(snapshot.access, Access::Admin | Access::Interact) {
				return Err("This session cannot join rooms".into());
			}
			let destination = request.resolve(&snapshot.checkpoint, &default)?;
			destination.check(&snapshot)?;
			let key = self.owner.recovery_key()?;
			let plan = snapshot
				.checkpoint
				.join_destination(
					rooms_application::session::checkpoint::gestures::Destination {
						directory: &destination.directory,
						locator: &destination.locator,
						name: &destination.name,
						nick: &nick,
						link: destination.link.as_deref(),
						policy: destination.policy,
					},
					&self.owner.operation_id()?,
					&key,
				)
				.map_err(str::to_owned)?;
			let operation = self.owner.operation_id()?;
			let preparation = self.owner.operation_id()?;
			Ok::<_, String>((
				destination,
				plan,
				operation,
				preparation,
				crate::abort::Abort::new(signal.clone())?,
			))
		})();
		let (destination, plan, operation, preparation, mut abort) = match input {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		let bytes = bytes
			+ plan.admission.retained_bytes()
			+ plan.preparation.as_ref().map_or(0, |step| step.retained_bytes())
			+ plan.readiness.as_ref().map_or(0, |reach| reach.retained_bytes());
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			let run = async {
				{
					let _serial = owner.lock().await?;
					owner.scope.current(generation)?;
					if let Some(active) = owner.current()?.checkpoint.active() {
						owner.flush_draft(active).await?;
					}
					if let Some(gesture) = &plan.preparation {
						let id = OperationId::new(preparation.into()).ok_or("Invalid Rooms operation identity")?;
						controller::run_checked(
							owner.as_ref(),
							&owner.commands,
							id,
							gesture.name(),
							gesture.arguments(),
							|snapshot| {
								owner.scope.current(generation)?;
								if signal.as_ref().is_some_and(web_sys::AbortSignal::aborted) {
									return Err("Rooms join cancelled".into());
								}
								gesture.check(&snapshot.checkpoint).map_err(str::to_owned)
							},
						)
						.await?;
					}
				}
				if let Some(readiness) = &plan.readiness {
					super::directory_reach::wait(owner.as_ref(), generation, readiness, &signal, &mut abort).await?;
				}
				let _serial = owner.lock().await?;
				owner.scope.current(generation)?;
				let gesture = &plan.admission;
				let id = OperationId::new(operation.into()).ok_or("Invalid Rooms operation identity")?;
				controller::run_checked(
					owner.as_ref(),
					&owner.commands,
					id,
					gesture.name(),
					gesture.arguments(),
					|snapshot| {
						owner.scope.current(generation)?;
						if signal.as_ref().is_some_and(web_sys::AbortSignal::aborted) {
							return Err("Rooms join cancelled".into());
						}
						destination.check(snapshot)?;
						gesture.check(&snapshot.checkpoint).map_err(str::to_owned)
					},
				)
				.await
			};
			let result = run.await;
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

	#[wasm_bindgen(js_name = chooseRoom)]
	pub fn choose_room(
		&self,
		directory: js_sys::JsString,
		name: js_sys::JsString,
		policy: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let bytes = 3
			* (directory.length() as usize
				+ name.length() as usize
				+ policy.as_ref().map_or(0, |s| s.length() as usize));
		let input = (|| {
			let directory = super::scalar(directory, 65_536)?;
			let name = super::scalar(name, 32)?;
			let policy: Option<RoomPolicy> = policy
				.map(|policy| serde_json::from_str(&super::scalar(policy, 256)?).map_err(|e| e.to_string()))
				.transpose()?;
			let snapshot = self.owner.current()?;
			if !matches!(snapshot.access, Access::Admin | Access::Interact) {
				return Err("This session cannot join or create rooms".into());
			}
			let conversation = self.owner.operation_id()?;
			let gesture = if let Some(policy) = policy {
				snapshot.checkpoint.create_managed_room(
					&directory,
					&name,
					&conversation,
					&self.owner.recovery_key()?,
					policy,
				)
			} else {
				snapshot.checkpoint.pick_room(&directory, &name, &conversation)
			}
			.map_err(str::to_owned)?;
			Ok::<_, String>((gesture, self.owner.operation_id()?))
		})();
		let (gesture, operation) = match input {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		self.submit_room_gesture(gesture, operation, bytes, None)
	}

	#[wasm_bindgen(js_name = takeRoomLink)]
	pub fn take_room_link(&self, link: js_sys::JsString, label: js_sys::JsString) -> js_sys::Promise {
		let bytes = 3 * (link.length() as usize + label.length() as usize);
		let input = (|| {
			let link = super::scalar(link, 16384)?;
			let label = super::scalar(label, 32)?;
			let address = rooms_glowcap::routes::Address::capability(&link)
				.map_err(|e| e.to_string())?
				.ok_or("The room entry link is invalid")?;
			let snapshot = self.owner.current()?;
			if !matches!(snapshot.access, Access::Admin | Access::Interact) {
				return Err("This session cannot join rooms".into());
			}
			let conversation = self.owner.operation_id()?;
			let gesture = snapshot
				.checkpoint
				.take_room_link(
					&address.authority,
					&address.address,
					&link,
					if label.is_empty() { "private room" } else { &label },
					&conversation,
				)
				.map_err(str::to_owned)?;
			Ok::<_, String>((gesture, self.owner.operation_id()?, conversation))
		})();
		match input {
			Ok((gesture, operation, conversation)) => {
				self.submit_room_gesture(gesture, operation, bytes, Some(conversation))
			}
			Err(error) => super::rejected(error),
		}
	}
}

impl RoomsBrowserSession {
	fn submit_room_gesture(
		&self,
		gesture: rooms_application::session::checkpoint::gestures::RoomGesture,
		operation: String,
		bytes: usize,
		new_conversation: Option<String>,
	) -> js_sys::Promise {
		let bytes = bytes + gesture.retained_bytes() + new_conversation.as_ref().map_or(0, String::capacity);
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			let _serial = owner.lock().await?;
			owner.scope.current(generation)?;
			if let Some(active) = owner.current()?.checkpoint.active() {
				owner.flush_draft(active).await?;
			}
			let id = OperationId::new(operation.into()).ok_or("Invalid Rooms operation identity")?;
			let result = controller::run_checked(
				owner.as_ref(),
				&owner.commands,
				id,
				gesture.name(),
				gesture.arguments(),
				|snapshot| {
					owner.scope.current(generation)?;
					gesture.check(&snapshot.checkpoint).map_err(str::to_owned)
				},
			)
			.await;
			let announcement = owner.announce(None);
			match result {
				Ok(snapshot) => {
					announcement?;
					match new_conversation {
						Some(id) => Ok(JsValue::from_bool(
							snapshot.checkpoint.active().and_then(|value| value.as_str()) != Some(id.as_str()),
						)),
						None => view::snapshot(&snapshot),
					}
				}
				Err(error) => Err(super::retain(Err(error), announcement).unwrap_err()),
			}
		})
	}
}
