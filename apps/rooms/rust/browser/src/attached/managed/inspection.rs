//! Exact saved recipe and operations inspection fronts. No page-side authority
//! map or scope-to-capability reconstruction enters these requests.
use super::*;
use rooms_application::{
	server::operations::operator::{Category, ReferenceKind, view::PageRows},
	session::operations::mutation::Kind,
};
use rooms_glowcap::client::workspace::OperationsReader;

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = peeringSnapshot)]
	pub fn peering_snapshot(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		self.driver.submit(0, move |_| async move {
			json(
				&workspace
					.peering_snapshot()
					.await
					.map_err(|error| error.to_string())?
					.encode()
					.map_err(|error| error.to_string())?,
			)
		})
	}
	#[wasm_bindgen(js_name = traceSnapshot)]
	pub fn trace_snapshot(&self, selected: js_sys::JsString) -> js_sys::Promise {
		let selected = match scalar(selected, 256)
			.and_then(|raw| custody::Coordinate::decode(&raw).map_err(|_| "Invalid trace coordinate".into()))
		{
			Ok(selected) => selected,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		self.driver.submit(256, move |_| async move {
			json(
				&workspace
					.trace_snapshot(selected)
					.await
					.map_err(|error| error.to_string())?
					.encode()
					.map_err(|error| error.to_string())?,
			)
		})
	}
	#[wasm_bindgen(js_name = roomManagementIdentity)]
	pub fn room_management_identity(&self, selected: js_sys::JsString) -> js_sys::Promise {
		let selected = match scalar(selected, 256)
			.and_then(|raw| custody::Coordinate::decode(&raw).map_err(|_| "Invalid room access coordinate".into()))
		{
			Ok(selected) => selected,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		self.driver.submit(256, move |_| async move {
			workspace
				.room_management_identity(selected)
				.await
				.map(Into::into)
				.map_err(|error| error.to_string())
		})
	}
	#[wasm_bindgen(js_name = exportConfiguration)]
	pub fn export_configuration(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		self.driver.submit(0, move |_| async move {
			let (snapshot, coordinates) = workspace.export_configuration().await.map_err(|e| e.to_string())?;
			json(&serde_json::json!({ "revision": snapshot.revision.to_string(), "intent": snapshot.intent, "coordinates": coordinates }).to_string())
		})
	}
	#[wasm_bindgen(js_name = custodyRecipe)]
	pub fn custody_recipe(&self, selected: js_sys::JsString) -> js_sys::Promise {
		let selected = match scalar(selected, 256)
			.and_then(|raw| custody::Coordinate::decode(&raw).map_err(|_| "Invalid recipe coordinate".into()))
		{
			Ok(selected) => selected,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		self.driver.submit(256, move |_| async move {
			Ok(workspace
				.custody_recipe(selected)
				.await
				.map_err(|e| e.to_string())?
				.map_or(JsValue::NULL, Into::into))
		})
	}
	#[wasm_bindgen(js_name = operationsReader)]
	pub fn operations_reader(&self, selected: js_sys::JsString, kind: Option<js_sys::JsString>) -> js_sys::Promise {
		let input = (|| {
			let selected =
				custody::Coordinate::decode(&scalar(selected, 256)?).map_err(|_| "Invalid operations coordinate")?;
			let kind: Option<Kind> = kind
				.map(|raw| -> Result<Kind> {
					serde_json::from_value(serde_json::Value::String(scalar(raw, 64)?))
						.map_err(|_| "Invalid operations interface".into())
				})
				.transpose()?;
			Ok((selected, kind))
		})();
		let (selected, kind) = match input {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(320, move |_| async move {
			let reader = workspace
				.operations_reader(selected, kind)
				.await
				.map_err(|e| e.to_string())?;
			let reader = driver.hold(reader, size_of::<OperationsReader<Platform>>())?;
			Ok(RoomsManagedOperationsReader { driver, reader }.into())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsManagedOperationsReader {
	driver: Driver,
	reader: Held<OperationsReader<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedOperationsReader {
	pub fn snapshot(&self) -> js_sys::Promise {
		let reader = self.reader.clone();
		self.driver.submit(0, move |_| async move {
			json(
				&reader
					.snapshot()
					.await
					.map_err(|e| e.to_string())?
					.encode()
					.map_err(|e| e.to_string())?,
			)
		})
	}
	#[wasm_bindgen(js_name = operatorSnapshot)]
	pub fn operator_snapshot(&self, query: js_sys::JsString, kind: Option<js_sys::JsString>) -> js_sys::Promise {
		let input = (|| Ok((scalar(query, 128)?, reference_kind(kind)?)))();
		let (query, kind) = match input {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let reader = self.reader.clone();
		self.driver.submit(512, move |_| async move {
			let snapshot = reader
				.operator_snapshot(&query, kind)
				.await
				.map_err(|e| e.to_string())?;
			json(&serde_json::to_string(&snapshot).map_err(|e| e.to_string())?)
		})
	}
	#[wasm_bindgen(js_name = operatorPage)]
	pub fn operator_page(
		&self,
		category: js_sys::JsString,
		cursor: js_sys::JsString,
		query: js_sys::JsString,
		kind: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let input = (|| {
			Ok((
				Category::parse(&scalar(category, 32)?).ok_or("Invalid operator category")?,
				revision(&scalar(cursor, 20)?)?,
				scalar(query, 128)?,
				reference_kind(kind)?,
			))
		})();
		let (category, cursor, query, kind) = match input {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let reader = self.reader.clone();
		self.driver.submit(512, move |_| async move {
			let page = reader
				.operator_page(category, cursor, &query, kind)
				.await
				.map_err(|e| e.to_string())?;
			let rows = match page.rows {
				PageRows::Stewardships(rows) => serde_json::to_value(rows),
				PageRows::Links(rows) => serde_json::to_value(rows),
				PageRows::Registrations(rows) => serde_json::to_value(rows),
				PageRows::Sessions(rows) => serde_json::to_value(rows),
				PageRows::Rooms(rows) => serde_json::to_value(rows),
				PageRows::References(rows) => serde_json::to_value(rows),
				PageRows::Trouble(rows) => serde_json::to_value(rows),
			}
			.map_err(|e| e.to_string())?;
			json(
				&serde_json::json!({"revision":page.revision,"next":page.next,"total":page.total,"rows":rows})
					.to_string(),
			)
		})
	}
}
fn reference_kind(raw: Option<js_sys::JsString>) -> Result<Option<ReferenceKind>> {
	raw.map(|raw| ReferenceKind::parse(&scalar(raw, 32)?).ok_or_else(|| "Invalid reference kind".into()))
		.transpose()
}
