//! Production ingress and result selection retain their complete transaction.
//! The page supplies intent. Shared admission owns custody and revision checks.
use super::*;
use rooms_glowcap::client::{
	Deadline,
	workspace::{ResultAcquisition, ResultImport},
};
use workspace::ImportRecipe as Incoming;
pub(super) fn candidate(
	expected: js_sys::JsString,
	releases: js_sys::JsString,
	intent: js_sys::JsString,
) -> Result<(u64, Vec<custody::Coordinate>, workspace::Intent)> {
	let expected = revision(&scalar(expected, 20)?)?;
	let releases = scalar(releases, 16384)?;
	let releases: Vec<custody::Coordinate> = serde_json::from_str(&releases).map_err(|_| "Invalid custody releases")?;
	if releases.len() > rooms_application::content::session::records::FIELDS_PER_PAGE {
		return Err("Custody releases exceed one page".into());
	}
	let intent = scalar(intent, custody::MAX_AUTHORITY_BYTES)?;
	let intent = workspace::Intent::decode(&intent).map_err(|_| "Invalid workspace intent")?;
	Ok((expected, releases, intent))
}
#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = preparePresentationImport)]
	pub fn prepare_presentation_import(&self, raw: js_sys::JsString) -> js_sys::Promise {
		let input = scalar(raw, custody::MAX_AUTHORITY_BYTES)
			.and_then(|raw| workspace::PresentationImport::decode(&raw).map_err(Into::into));
		let input = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(custody::MAX_AUTHORITY_BYTES, move |_| async move {
			let snapshot = workspace.snapshot().await.map_err(|error| error.to_string())?;
			let intent = input.apply(&snapshot.intent)?;
			let request = workspace
				.prepare_acquisition(snapshot.revision, Vec::new(), &[], &intent)
				.map_err(|error| error.to_string())?;
			let bytes = request.retained_bytes();
			let request = driver.hold(request, bytes)?;
			Ok(RoomsManagedAcquisition {
				driver,
				acquisition: request,
			}
			.into())
		})
	}
	/// Workspace decoding requires complete recipe coverage before any network work.
	#[wasm_bindgen(js_name = prepareConfigurationImport)]
	pub fn prepare_configuration_import(&self, expected: js_sys::JsString, raw: js_sys::JsString) -> js_sys::Promise {
		let input = (|| {
			let expected = revision(&scalar(expected, 20)?)?;
			let raw = scalar(raw, workspace::ConfigurationImport::MAX_BYTES)?;
			let imported = workspace::ConfigurationImport::decode(&raw)?;
			validate_recipes(&imported.imports)?;
			Ok(((expected, Vec::new(), imported.intent), imported.imports, None))
		})();
		acquire(self, input)
	}
	/// Pasted recipes are transient input. Acquisition saves actual fetched
	/// capabilities and intent together, after checking the original held source.
	#[wasm_bindgen(js_name = prepareAcquisition)]
	pub fn prepare_acquisition(
		&self,
		expected: js_sys::JsString,
		imports: js_sys::JsString,
		releases: js_sys::JsString,
		intent: js_sys::JsString,
		source: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let input = (|| {
			let candidate = candidate(expected, releases, intent)?;
			let source = source
				.map(|raw| -> Result<custody::Coordinate> {
					let raw = scalar(raw, 256)?;
					let source = custody::Coordinate::decode(&raw).map_err(|_| "Invalid source coordinate")?;
					if source.role != custody::Role::SessionAccess {
						return Err("An acquisition source must be session access".into());
					}
					Ok(source)
				})
				.transpose()?;
			let raw = scalar(imports, 131072)?;
			let imports: Vec<Incoming> = serde_json::from_str(&raw).map_err(|_| "Invalid custody acquisition")?;
			if imports.len() + usize::from(source.is_some())
				> rooms_application::content::session::records::FIELDS_PER_PAGE
			{
				return Err("Custody acquisition exceeds one page".into());
			}
			validate_recipes(&imports)?;
			Ok((candidate, imports, source))
		})();
		acquire(self, input)
	}
}
pub(super) fn validate_recipes(imports: &[Incoming]) -> Result<()> {
	for entry in imports {
		if entry.coordinate.role.live() || entry.uri.len() > glowcap::loam::ReferenceRequest::MAX_URI_BYTES {
			return Err("This acquisition requires a bounded durable capability recipe".into());
		}
		glowcap::parse_sturdyref(&entry.uri, glowcap::CaptpVersion::V1_0).map_err(|e| e.to_string())?;
	}
	Ok(())
}
type AcquisitionInput = (
	(u64, Vec<custody::Coordinate>, workspace::Intent),
	Vec<Incoming>,
	Option<custody::Coordinate>,
);
fn acquire(owner: &RoomsManagedWorkspace, input: Result<AcquisitionInput>) -> js_sys::Promise {
	let ((expected, releases, mut intent), incoming, source) = match input {
		Ok(value) => value,
		Err(error) => return rejected(error),
	};
	let workspace = owner.workspace.clone();
	let driver = owner.driver.clone();
	owner
		.driver
		.submit(custody::MAX_AUTHORITY_BYTES + 131072, move |environment| async move {
			let mut imports = Vec::with_capacity(incoming.len() + usize::from(source.is_some()));
			if let Some(source) = source {
				imports.push(Import {
					coordinate: source,
					reference: workspace.reference().clone(),
					uri: None,
				});
			}
			for entry in incoming {
				let reference = environment
					.platform
					.within(
						rooms_application::room::authority::REQUEST_TIMEOUT_MS,
						environment.runtime.host().enliven(&entry.uri),
					)
					.await
					.ok_or("Capability acquisition did not answer")?
					.map_err(|e| e.to_string())?;
				imports.push(Import {
					coordinate: entry.coordinate,
					reference,
					uri: Some(entry.uri),
				});
			}
			workspace
				.resolve_imported_room_names(&imports, &mut intent)
				.await
				.map_err(|error| error.to_string())?;
			workspace
				.validate_room_authority_imports(&imports, &intent)
				.await
				.map_err(|error| error.to_string())?;
			let acquisition = workspace
				.prepare_acquisition(expected, imports, &releases, &intent)
				.map_err(|e| e.to_string())?;
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedAcquisition { driver, acquisition }.into())
		})
}
#[wasm_bindgen]
impl RoomsManagedCommand {
	/// Adopt a creation receipt as one room append through its original directory.
	#[wasm_bindgen(js_name = prepareCreatedRoomAcquisition)]
	pub fn prepare_created_room_acquisition(
		&self,
		expected: js_sys::JsString,
		mappings: js_sys::JsString,
		releases: js_sys::JsString,
		intent: js_sys::JsString,
		source: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let command = self.command.clone();
		result_acquisition(
			&self.driver,
			(expected, mappings, releases, intent, source),
			move |expected, imports, releases, intent, source| {
				command
					.prepare_result_acquisition_with_source(expected, imports, releases, intent, source)?
					.created_room()
			},
		)
	}
	/// Results stay in Loam. Exact coordinates select them without re-fetching a
	/// URI, exposing private actors, or sending the original effect a second time.
	#[wasm_bindgen(js_name = prepareResultAcquisition)]
	pub fn prepare_result_acquisition(
		&self,
		expected: js_sys::JsString,
		mappings: js_sys::JsString,
		releases: js_sys::JsString,
		intent: js_sys::JsString,
		source: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let command = self.command.clone();
		result_acquisition(
			&self.driver,
			(expected, mappings, releases, intent, source),
			move |expected, imports, releases, intent, source| {
				command.prepare_result_acquisition_with_source(expected, imports, releases, intent, source)
			},
		)
	}
}
#[wasm_bindgen]
pub struct RoomsManagedResultAcquisition {
	driver: Driver,
	request: Held<ResultAcquisition<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedResultAcquisition {
	/// A conflict proves no result adoption. Unknown outcomes reject and retain
	/// this candidate. Only a proved conflict permits another preparation.
	pub fn submit(&self) -> js_sys::Promise {
		let request = self.request.clone();
		self.driver
			.submit(0, move |_| async move { outcome::acquisition(request.submit().await) })
	}
}

pub(super) fn result_acquisition(
	driver: &Driver,
	raw: (
		js_sys::JsString,
		js_sys::JsString,
		js_sys::JsString,
		js_sys::JsString,
		Option<js_sys::JsString>,
	),
	prepare: impl FnOnce(
		u64,
		&[ResultImport],
		&[custody::Coordinate],
		&workspace::Intent,
		Option<custody::FieldKey<custody::SessionAccess>>,
	) -> glowcap::Result<ResultAcquisition<Platform>>
	+ 'static,
) -> js_sys::Promise {
	let (expected, mappings, releases, intent, source) = raw;
	let input = (|| {
		let candidate = candidate(expected, releases, intent)?;
		let raw = scalar(mappings, 32768)?;
		let pairs: Vec<[custody::Coordinate; 2]> =
			serde_json::from_str(&raw).map_err(|_| "Invalid result selection")?;
		if pairs.len() > rooms_application::content::session::records::FIELDS_PER_PAGE {
			return Err("Result selection exceeds one page".into());
		}
		let imports: Vec<_> = pairs
			.into_iter()
			.map(|[result, destination]| ResultImport { result, destination })
			.collect();
		Ok((candidate, imports))
	})();
	let ((expected, releases, intent), imports) = match input {
		Ok(value) => value,
		Err(error) => return rejected(error),
	};
	let source = match source
		.map(|value| {
			let value = scalar(value, 1024)?;
			let coordinate = custody::Coordinate::decode(&value).map_err(|_| "Invalid worker source custody")?;
			if coordinate.role != custody::Role::SessionAccess {
				return Err("Worker source must select session access".into());
			}
			Ok(custody::FieldKey::<custody::SessionAccess>::new(
				coordinate.key.slot(),
				coordinate.key.generation(),
			))
		})
		.transpose()
	{
		Ok(source) => source,
		Err(error) => return rejected(error),
	};
	let owner = driver.clone();
	driver.submit(custody::MAX_AUTHORITY_BYTES + 32768, move |_| async move {
		let request = prepare(expected, &imports, &releases, &intent, source).map_err(|e| e.to_string())?;
		let bytes = request.retained_bytes();
		let request = owner.hold(request, bytes)?;
		Ok(RoomsManagedResultAcquisition { driver: owner, request }.into())
	})
}
