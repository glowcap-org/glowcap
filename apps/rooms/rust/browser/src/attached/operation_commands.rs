//! Presentation supplies a verb and form values; Rust selects its authority.
use super::{view, RoomsBrowserSession};
use rooms_application::session::{
	controller::operations::{Kind, Target},
	state::OperationId,
};
use rooms_glowcap::client::session::controller::{self, Observation};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = retireOperatorMatches)]
	pub fn retire_operator_matches(
		&self,
		category: js_sys::JsString,
		query: js_sys::JsString,
		limit: f64,
		reference: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		use rooms_application::server::operations::operator::{Category, ReferenceKind};
		let bytes = 3
			* (category.length() as usize
				+ query.length() as usize
				+ reference.as_ref().map_or(0, |s| s.length() as usize));
		let input = (|| {
			let snapshot = self.owner.current()?;
			let target = Target::select(&snapshot, Kind::parse("operator").expect("operator inventory"))
				.map_err(str::to_owned)?;
			let category = Category::parse(&super::actions::text(category)?).ok_or("Invalid operator category")?;
			let query = super::scalar(query, rooms_application::server::operations::operator::MAX_QUERY)?;
			let limit = super::safe_integer(limit)?;
			let reference = reference
				.map(|value| {
					ReferenceKind::parse(&super::actions::text(value)?)
						.ok_or_else(|| "Invalid operator reference kind".to_owned())
				})
				.transpose()?;
			Ok::<_, String>((target, category, query, limit, reference))
		})();
		let (target, category, query, limit, reference) = match input {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			let _serial = owner.lock().await?;
			owner.scope.current(generation)?;
			// A fresh snapshot checks authority even when notification delivery lags.
			let snapshot = owner.refresh().await?;
			target.check(&snapshot).map_err(str::to_owned)?;
			owner.scope.current(generation)?;
			let batch = owner
				.session()?
				.operator_retire_at(
					target.scope(),
					category,
					&query,
					limit,
					reference,
					Some(snapshot.revision.get()),
				)
				.await
				.map_err(|error| error.to_string())?;
			let output = js_sys::Object::new().into();
			view::set(&output, "retired", view::json(&batch.retired)?)?;
			view::set(&output, "remaining", view::json(&batch.remaining)?)?;
			view::set(&output, "refused", view::json(&batch.refused)?)?;
			Ok(output)
		})
	}

	#[wasm_bindgen(js_name = runOperation)]
	pub fn run_operation(
		&self,
		capability: js_sys::JsString,
		action: js_sys::JsString,
		arguments: js_sys::Array,
	) -> js_sys::Promise {
		let input = (|| {
			if arguments.length() as usize > rooms_application::session::command::MAX_ARGUMENTS {
				return Err("Too many Rooms command arguments".into());
			}
			let capability = super::actions::text(capability)?;
			let kind = Kind::parse(&capability).ok_or("Invalid Rooms operations capability")?;
			let snapshot = self.owner.current()?;
			let target = Target::select(&snapshot, kind).map_err(str::to_owned)?;
			let (operation, action, arguments, bytes) =
				super::command_input(self.owner.operation_id()?.into(), action, arguments)?;
			let (name, args) = target
				.command(&snapshot, &operation, &action, &arguments)
				.map_err(str::to_owned)?;
			let bytes = bytes + name.len() + args.iter().map(String::len).sum::<usize>();
			if bytes > super::driver::MAX_BYTES {
				return Err("Rooms command exceeds the retained input budget".into());
			}
			let name = name.to_owned();
			Ok::<_, String>((target, operation, name, args, bytes))
		})();
		let (target, operation, name, arguments, bytes) = match input {
			Ok(input) => input,
			Err(error) => return super::rejected(error),
		};
		let owner = self.owner.clone();
		let generation = owner.scope.generation();
		self.driver.submit(bytes, move |_| async move {
			let _serial = owner.lock().await?;
			let id = OperationId::new(operation.into()).ok_or("Invalid Rooms operation identity")?;
			let result = controller::run_checked(owner.as_ref(), &owner.commands, id, &name, &arguments, |snapshot| {
				owner.scope.current(generation)?;
				target.check(snapshot).map_err(str::to_owned)
			})
			.await;
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
}
