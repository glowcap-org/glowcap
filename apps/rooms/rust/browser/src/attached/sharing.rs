//! Sharing gestures keep room and registration identity in Rust through every
//! await. The page supplies a choice and renders the acknowledged outcome.
use super::{RoomsBrowserSession, view};
use rooms_application::session::{
	checkpoint::gestures::{DirectGesture, ShareRoom},
	state::OperationId,
};
use rooms_glowcap::client::session::controller::{self, Observation};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = inviteToRoom)]
	pub fn invite_to_room(&self, conversation: js_sys::JsString, who: js_sys::JsString) -> js_sys::Promise {
		let bytes = 3 * (conversation.length() as usize + who.length() as usize);
		let input = (|| {
			let conversation = super::scalar(conversation, 65_536)?;
			let who = super::scalar(who, 32)?;
			let snapshot = self.owner.current()?;
			let room = ShareRoom::select(&snapshot.checkpoint, &conversation, None)?;
			let direct = DirectGesture::select(&snapshot, room.directory(), &who, false)?;
			Ok::<_, String>((room, direct, self.owner.operation_id()?, self.owner.operation_id()?))
		})();
		let (room, direct, opening, offering) = match input {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		let bytes = bytes + room.retained_bytes() + direct.retained_bytes();
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			let _serial = owner.lock().await?;
			let run = async {
				let check = |snapshot: &rooms_application::session::snapshot::Snapshot| {
					owner.scope.current(generation)?;
					room.check(&snapshot.checkpoint)?;
					direct.check(snapshot)
				};
				if let Some((name, arguments)) = direct.command() {
					let id = OperationId::new(opening.into()).ok_or("Invalid Rooms operation identity")?;
					controller::run_checked(owner.as_ref(), &owner.commands, id, name, arguments, check).await?;
				} else {
					check(owner.current()?.as_ref())?;
				}
				let id = OperationId::new(offering.into()).ok_or("Invalid Rooms operation identity")?;
				let arguments = [room.id().to_owned(), direct.id().to_owned()];
				controller::run_checked(owner.as_ref(), &owner.commands, id, "offerRoom", &arguments, check).await
			};
			let result = run.await;
			let announcement = owner.announce(None);
			match result {
				Ok(_) => {
					announcement?;
					Ok(JsValue::UNDEFINED)
				}
				Err(error) => Err(super::retain(Err(error), announcement).unwrap_err()),
			}
		})
	}
	#[wasm_bindgen(js_name = roomLinkFor)]
	pub fn room_link_for(&self, conversation: js_sys::JsString, name: Option<js_sys::JsString>) -> js_sys::Promise {
		let bytes = 3 * (conversation.length() as usize + name.as_ref().map_or(0, |name| name.length() as usize));
		let input = (|| {
			let conversation = super::scalar(conversation, 65_536)?;
			let name = name.map(|name| super::scalar(name, 32)).transpose()?;
			let snapshot = self.owner.current()?;
			let room = ShareRoom::select(&snapshot.checkpoint, &conversation, name.as_deref())?;
			Ok::<_, String>((room, self.owner.operation_id()?))
		})();
		let (room, operation) = match input {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		let bytes = bytes + room.retained_bytes();
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			let _serial = owner.lock().await?;
			let run = async {
				owner.scope.current(generation)?;
				let snapshot = owner.current()?;
				room.check(&snapshot.checkpoint)?;
				if let Ok(link) = room.link(&snapshot.checkpoint) {
					return view::json(&link);
				}
				let id = OperationId::new(operation.into()).ok_or("Invalid Rooms operation identity")?;
				let arguments = [room.id().to_owned()];
				let snapshot = controller::run_checked(
					owner.as_ref(),
					&owner.commands,
					id,
					"ensureRoomLink",
					&arguments,
					|snapshot| {
						owner.scope.current(generation)?;
						room.check(&snapshot.checkpoint).map_err(str::to_owned)
					},
				)
				.await?;
				view::json(&room.link(&snapshot.checkpoint)?)
			};
			let result = run.await;
			let announcement = owner.announce(None);
			match result {
				Ok(value) => {
					announcement?;
					Ok(value)
				}
				Err(error) => Err(super::retain(Err(error), announcement).unwrap_err()),
			}
		})
	}
}
