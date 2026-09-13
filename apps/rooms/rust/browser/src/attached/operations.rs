use super::{Result, RoomsBrowserSession, actions::text, safe_integer, view};
use rooms_application::{
	server::operations::operator::{Category, ReferenceKind, view::PageRows},
	session::operations::{Capability, Snapshot},
};
use wasm_bindgen::prelude::*;

fn reference(value: Option<js_sys::JsString>) -> Result<Option<ReferenceKind>> {
	value
		.map(|value| ReferenceKind::parse(&text(value)?).ok_or_else(|| "Invalid Rooms reference kind".into()))
		.transpose()
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = operationsSnapshot)]
	pub fn operations_snapshot(&self, scope: js_sys::JsString, capability: js_sys::JsString) -> js_sys::Promise {
		let bytes = 3 * (scope.length() + capability.length()) as usize;
		let input = (|| {
			let capability = match text(capability)?.as_str() {
				"listeners" => Capability::Listeners,
				"diagnostics" => Capability::Diagnostics,
				"trace" => Capability::Trace,
				"peering" => Capability::Peering,
				"irc" => Capability::Irc,
				_ => return Err("Invalid Rooms operations capability".into()),
			};
			Ok((text(scope)?, capability))
		})();
		self.action(input, bytes, |session, (scope, capability)| async move {
			let snapshot = session
				.operations_snapshot(&scope, capability)
				.await
				.map_err(|e| e.to_string())?;
			snapshot_view(snapshot, capability)
		})
	}
	#[wasm_bindgen(js_name = operatorSnapshot)]
	pub fn operator_snapshot(
		&self,
		scope: js_sys::JsString,
		query: js_sys::JsString,
		kind: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let bytes =
			3 * (scope.length() as usize + query.length() as usize + kind.as_ref().map_or(0, |s| s.length() as usize));
		let input = (|| Ok((text(scope)?, text(query)?, reference(kind)?)))();
		self.action(input, bytes, |session, (scope, query, kind)| async move {
			view::json(
				&session
					.operator_snapshot(&scope, &query, kind)
					.await
					.map_err(|e| e.to_string())?,
			)
		})
	}
	#[wasm_bindgen(js_name = operatorPage)]
	pub fn operator_page(
		&self,
		scope: js_sys::JsString,
		category: js_sys::JsString,
		cursor: f64,
		query: js_sys::JsString,
		kind: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let bytes = 3
			* (scope.length() as usize
				+ category.length() as usize
				+ query.length() as usize
				+ kind.as_ref().map_or(0, |s| s.length() as usize));
		let input = (|| {
			Ok((
				text(scope)?,
				Category::parse(&text(category)?).ok_or("Invalid Rooms operator category")?,
				safe_integer(cursor)?,
				text(query)?,
				reference(kind)?,
			))
		})();
		self.action(
			input,
			bytes,
			|session, (scope, category, cursor, query, kind)| async move {
				let page = session
					.operator_page(&scope, category, cursor, &query, kind)
					.await
					.map_err(|e| e.to_string())?;
				let output = js_sys::Object::new().into();
				view::set(&output, "revision", view::json(&page.revision)?)?;
				view::set(&output, "next", view::json(&page.next)?)?;
				view::set(&output, "total", view::json(&page.total)?)?;
				let rows = match page.rows {
					PageRows::Stewardships(rows) => view::json(&rows)?,
					PageRows::Links(rows) => view::json(&rows)?,
					PageRows::Registrations(rows) => view::json(&rows)?,
					PageRows::Sessions(rows) => view::json(&rows)?,
					PageRows::Rooms(rows) => view::json(&rows)?,
					PageRows::References(rows) => view::json(&rows)?,
					PageRows::Trouble(rows) => view::json(&rows)?,
				};
				view::set(&output, "rows", rows)?;
				Ok(output)
			},
		)
	}
	#[wasm_bindgen(js_name = operatorRetireMatching)]
	pub fn operator_retire_matching(
		&self,
		scope: js_sys::JsString,
		category: js_sys::JsString,
		query: js_sys::JsString,
		limit: f64,
		kind: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let bytes = 3
			* (scope.length() as usize
				+ category.length() as usize
				+ query.length() as usize
				+ kind.as_ref().map_or(0, |s| s.length() as usize));
		let input = (|| {
			Ok((
				text(scope)?,
				Category::parse(&text(category)?).ok_or("Invalid Rooms operator category")?,
				text(query)?,
				safe_integer(limit)?,
				reference(kind)?,
			))
		})();
		self.mutation(
			input,
			bytes,
			|session, (scope, category, query, limit, kind)| async move {
				let batch = session
					.operator_retire(&scope, category, &query, limit, kind)
					.await
					.map_err(|e| e.to_string())?;
				let output = js_sys::Object::new().into();
				view::set(&output, "retired", view::json(&batch.retired)?)?;
				view::set(&output, "remaining", view::json(&batch.remaining)?)?;
				view::set(&output, "refused", view::json(&batch.refused)?)?;
				Ok(output)
			},
		)
	}
}

pub(super) fn snapshot_view(snapshot: Snapshot, capability: Capability) -> Result<JsValue> {
	let output = match &snapshot {
		Snapshot::Trace(value) => view::json(value)?,
		_ => js_sys::Object::new().into(),
	};
	view::set(&output, "capability", capability.name().into())?;
	match snapshot {
		Snapshot::Listeners(rows) => view::set(&output, "rows", view::json(&rows)?)?,
		Snapshot::Diagnostics(rows) => view::set(&output, "rows", view::json(&rows)?)?,
		Snapshot::Peering(rows) => view::set(&output, "rows", view::json(&rows)?)?,
		Snapshot::Irc(gateway) => view::set(&output, "gateway", view::json(&gateway)?)?,
		Snapshot::Trace(_) => {}
	}
	Ok(output)
}
