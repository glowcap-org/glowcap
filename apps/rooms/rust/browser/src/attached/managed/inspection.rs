//! Exact saved recipe and operations inspection fronts. No page-side authority
//! map or scope-to-capability reconstruction enters these requests.
use super::*;
use rooms_application::{
	server::operations::operator::{Category, ReferenceKind, view::PageRows},
	session::operations::mutation::Kind,
};
use rooms_glowcap::client::workspace::OperationsReader;
use rooms_runtime::Error as RuntimeError;

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
					.map_err(RuntimeError::from)?
					.encode()
					.map_err(RuntimeError::operator)?,
			)
		})
	}
	#[wasm_bindgen(js_name = traceSnapshot)]
	pub fn trace_snapshot(&self, selected: js_sys::JsString) -> js_sys::Promise {
		let selected = match scalar(selected, 256).and_then(|raw| {
			custody::Coordinate::decode(&raw).map_err(|_| RuntimeError::invalid("Invalid trace coordinate"))
		}) {
			Ok(selected) => selected,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		self.driver.submit(256, move |_| async move {
			json(
				&workspace
					.trace_snapshot(selected)
					.await
					.map_err(RuntimeError::from)?
					.encode()
					.map_err(RuntimeError::operator)?,
			)
		})
	}
	#[wasm_bindgen(js_name = roomManagementIdentity)]
	pub fn room_management_identity(&self, selected: js_sys::JsString) -> js_sys::Promise {
		let selected = match scalar(selected, 256).and_then(|raw| {
			custody::Coordinate::decode(&raw).map_err(|_| RuntimeError::invalid("Invalid room seat coordinate"))
		}) {
			Ok(selected) => selected,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		self.driver.submit(256, move |_| async move {
			workspace
				.room_management_identity(selected)
				.await
				.map(Into::into)
				.map_err(RuntimeError::from)
		})
	}
	#[wasm_bindgen(js_name = exportConfiguration)]
	pub fn export_configuration(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		self.driver.submit(0, move |_| async move {
			let (snapshot, coordinates) = workspace.export_configuration().await.map_err(RuntimeError::from)?;
			json(&serde_json::json!({ "revision": snapshot.revision.to_string(), "intent": snapshot.intent, "coordinates": coordinates }).to_string())
		})
	}
	#[wasm_bindgen(js_name = custodyRecipe)]
	pub fn custody_recipe(&self, selected: js_sys::JsString) -> js_sys::Promise {
		optional_text(
			&self.driver,
			&self.workspace,
			selected,
			"Invalid recipe coordinate",
			|workspace, selected| async move { workspace.custody_recipe(selected).await },
		)
	}
	/// The transport an open direct line runs over, or null while no live
	/// session carries its installed route.
	#[wasm_bindgen(js_name = directRoute)]
	pub fn direct_route(&self, selected: js_sys::JsString) -> js_sys::Promise {
		optional_text(
			&self.driver,
			&self.workspace,
			selected,
			"Invalid direct route coordinate",
			|workspace, selected| async move { workspace.direct_route(selected).await },
		)
	}
	#[wasm_bindgen(js_name = operationsReader)]
	pub fn operations_reader(&self, selected: js_sys::JsString, kind: Option<js_sys::JsString>) -> js_sys::Promise {
		let input = (|| {
			let selected = custody::Coordinate::decode(&scalar(selected, 256)?)
				.map_err(|_| RuntimeError::invalid("Invalid operations coordinate"))?;
			let kind: Option<Kind> = kind
				.map(|raw| -> Result<Kind> {
					serde_json::from_value(serde_json::Value::String(scalar(raw, 64)?))
						.map_err(|_| RuntimeError::invalid("Invalid operations interface"))
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
				.map_err(RuntimeError::from)?;
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
					.map_err(RuntimeError::from)?
					.encode()
					.map_err(RuntimeError::operator)?,
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
				.map_err(RuntimeError::from)?;
			json(&serde_json::to_string(&snapshot).map_err(RuntimeError::invalid_by)?)
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
				Category::parse(&scalar(category, 32)?)
					.ok_or_else(|| RuntimeError::invalid("Invalid operator category"))?,
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
				.map_err(RuntimeError::from)?;
			let rows = match page.rows {
				PageRows::Stewardships(rows) => serde_json::to_value(rows),
				PageRows::Links(rows) => serde_json::to_value(rows),
				PageRows::Registrations(rows) => serde_json::to_value(rows),
				PageRows::Sessions(rows) => serde_json::to_value(rows),
				PageRows::Rooms(rows) => serde_json::to_value(rows),
				PageRows::References(rows) => serde_json::to_value(rows),
				PageRows::Trouble(rows) => serde_json::to_value(rows),
			}
			.map_err(RuntimeError::invalid_by)?;
			json(
				&serde_json::json!({"revision":page.revision,"next":page.next,"total":page.total,"rows":rows})
					.to_string(),
			)
		})
	}
}
fn reference_kind(raw: Option<js_sys::JsString>) -> Result<Option<ReferenceKind>> {
	raw.map(|raw| {
		ReferenceKind::parse(&scalar(raw, 32)?).ok_or_else(|| RuntimeError::invalid("Invalid reference kind"))
	})
	.transpose()
}

/// One coordinate in and one text or null out, the shape of a workspace read
/// that names a fact of held custody.
fn optional_text<W, E>(
	driver: &Driver,
	workspace: &Held<Workspace<Platform>>,
	selected: js_sys::JsString,
	invalid: &'static str,
	read: impl FnOnce(Held<Workspace<Platform>>, custody::Coordinate) -> W + 'static,
) -> js_sys::Promise
where
	W: std::future::Future<Output = core::result::Result<Option<String>, E>> + 'static,
	RuntimeError: From<E>,
{
	let selected = match scalar(selected, 256)
		.and_then(|raw| custody::Coordinate::decode(&raw).map_err(|_| RuntimeError::invalid(invalid)))
	{
		Ok(selected) => selected,
		Err(error) => return rejected(error),
	};
	let workspace = workspace.clone();
	driver.submit(256, move |_| async move {
		Ok(read(workspace, selected)
			.await
			.map_err(RuntimeError::from)?
			.map_or(JsValue::NULL, Into::into))
	})
}
