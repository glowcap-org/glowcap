//! One admitted Connect gesture owns preparation, observation and cleanup.
use super::RoomsBrowserSession;
use rooms_application::{grants::Access, session::state::OperationId};
use rooms_glowcap::client::session::controller::{self, Observation};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = reachDirectory)]
	pub fn reach_directory(
		&self,
		locator: js_sys::JsString,
		nick: js_sys::JsString,
		default_directory: js_sys::JsString,
		signal: Option<web_sys::AbortSignal>,
	) -> js_sys::Promise {
		let bytes = 3 * (locator.length() as usize + nick.length() as usize + default_directory.length() as usize);
		let input = (|| {
			let locator = super::scalar(locator, 16384)?;
			let default = super::scalar(default_directory, 16384)?;
			let locator = if locator.is_empty() { default } else { locator };
			let nick_intent: rooms_application::directory::registration::NicknameIntent =
				serde_json::from_str(&super::scalar(nick, 256)?).map_err(|_| "Invalid nickname intent")?;
			let nick = nick_intent.requested();
			let nick_allocation = nick_intent.allocation();
			if let Some(reason) = rooms_application::room::inbox::nick_refusal(nick) {
				return Err(reason);
			}
			let address = rooms_glowcap::routes::Address::directory(&locator)
				.map_err(|e| e.to_string())?
				.ok_or("The directory address is invalid")?;
			let snapshot = self.owner.current()?;
			if !matches!(snapshot.access, Access::Admin | Access::Interact) {
				return Err("This session cannot connect to directories".into());
			}
			let reach = snapshot
				.checkpoint
				.reach_directory_with_allocation(&address.authority, &locator, nick, nick_allocation)
				.map_err(str::to_owned)?;
			let abort = crate::abort::Abort::new(signal.clone())?;
			Ok::<_, String>((reach, abort, self.owner.operation_id()?, self.owner.operation_id()?))
		})();
		let (reach, mut abort, preparation, retirement) = match input {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		let bytes = bytes + reach.retained_bytes();
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			{
				let _serial = owner.lock().await?;
				owner.scope.current(generation)?;
				if signal.as_ref().is_some_and(web_sys::AbortSignal::aborted) {
					return Ok(JsValue::UNDEFINED);
				}
				if let Some(gesture) = &reach.preparation {
					let id = OperationId::new(preparation.into()).ok_or("Invalid Rooms operation identity")?;
					let result = controller::run_checked(
						owner.as_ref(),
						&owner.commands,
						id,
						gesture.name(),
						gesture.arguments(),
						|snapshot| {
							owner.scope.current(generation)?;
							if signal.as_ref().is_some_and(web_sys::AbortSignal::aborted) {
								return Err("Rooms connection cancelled".into());
							}
							gesture.check(&snapshot.checkpoint).map_err(str::to_owned)
						},
					)
					.await;
					let announcement = owner.announce(None);
					match result {
						Ok(_) => announcement?,
						Err(error)
							if error == "Rooms connection cancelled"
								&& signal.as_ref().is_some_and(web_sys::AbortSignal::aborted) =>
						{
							announcement?;
							return Ok(JsValue::UNDEFINED);
						}
						Err(error) => return Err(super::retain(Err(error), announcement).unwrap_err()),
					}
				}
			}
			// Waiting does not hold the mutation lock: another room or view can
			// make progress while this directory is opening.
			let outcome = wait(owner.as_ref(), generation, &reach, &signal, &mut abort).await;
			let cancelled = signal.as_ref().is_some_and(web_sys::AbortSignal::aborted);
			if (outcome.is_err() || cancelled) && reach.temporary() {
				let _serial = owner.lock().await?;
				owner.scope.current(generation)?;
				let snapshot = owner.refresh().await?;
				if reach.can_retire(&snapshot) {
					let id = OperationId::new(retirement.into()).ok_or("Invalid Rooms operation identity")?;
					let arguments = [reach.id().to_owned()];
					let retired = controller::run_checked(
						owner.as_ref(),
						&owner.commands,
						id,
						"leaveDirectory",
						&arguments,
						|snapshot| {
							owner.scope.current(generation)?;
							if reach.can_retire(snapshot) {
								Ok(())
							} else {
								Err("The directory changed while connecting and has been retained".into())
							}
						},
					)
					.await
					.map(|_| ());
					let announcement = owner.announce(None);
					let cleanup = rooms_runtime::cleanup::combine(retired, announcement);
					rooms_runtime::cleanup::combine(outcome, cleanup)?;
					return Ok(JsValue::UNDEFINED);
				}
			}
			outcome?;
			Ok(JsValue::UNDEFINED)
		})
	}
}

/// Readiness never holds the mutation lock; directory work and sibling views
/// must be able to progress while a connection is registering its nickname.
pub(super) async fn wait(
	owner: &super::owner::Owner,
	generation: u64,
	reach: &rooms_application::session::checkpoint::gestures::Reach,
	signal: &Option<web_sys::AbortSignal>,
	abort: &mut crate::abort::Abort,
) -> Result<(), String> {
	loop {
		owner.scope.current(generation)?;
		if signal.as_ref().is_some_and(web_sys::AbortSignal::aborted) {
			return Ok(());
		}
		if let Some(outcome) = reach.outcome(owner.current()?.as_ref()) {
			return outcome;
		}
		tokio::select! { biased;
			() = owner.scope.stopped() => return Err("Rooms attachment closed while connecting".into()),
			() = abort.cancelled() => return Ok(()),
			() = owner.changed.notified() => {}
		}
	}
}
