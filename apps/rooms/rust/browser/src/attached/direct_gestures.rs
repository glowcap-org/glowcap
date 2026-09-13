//! Outgoing direct intent selection from Rust's authoritative observation.
use super::{RoomsBrowserSession, view};
use rooms_application::session::{checkpoint::gestures::DirectGesture, state::OperationId};
use rooms_glowcap::client::session::controller::{self, Observation};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = chooseDirect)]
	pub fn choose_direct(&self, directory: js_sys::JsString, who: js_sys::JsString, select: bool) -> js_sys::Promise {
		let bytes = 3 * (directory.length() as usize + who.length() as usize);
		let input = (|| {
			let directory = super::scalar(directory, 65_536)?;
			let who = super::scalar(who, 32)?;
			let snapshot = self.owner.current()?;
			let gesture = DirectGesture::select(&snapshot, &directory, &who, select)?;
			Ok::<_, String>((gesture, self.owner.operation_id()?))
		})();
		let (gesture, operation) = match input {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		let bytes = bytes + gesture.retained_bytes();
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			let _serial = owner.lock().await?;
			owner.scope.current(generation)?;
			if select {
				if let Some(active) = owner.current()?.checkpoint.active() {
					owner.flush_draft(active).await?;
				}
			}
			let result = if let Some((name, arguments)) = gesture.command() {
				let id = OperationId::new(operation.into()).ok_or("Invalid Rooms operation identity")?;
				controller::run_checked(owner.as_ref(), &owner.commands, id, name, arguments, |snapshot| {
					owner.scope.current(generation)?;
					gesture.check(snapshot)
				})
				.await
			} else {
				let snapshot = owner.current()?;
				gesture.check(&snapshot)?;
				Ok(snapshot)
			};
			let announcement = owner.announce(None);
			match result {
				Ok(snapshot) => {
					announcement?;
					view::json(&gesture.conversation(&snapshot.checkpoint).map_err(str::to_owned)?)
				}
				Err(error) => Err(super::retain(Err(error), announcement).unwrap_err()),
			}
		})
	}
}
