//! The exact current records, blob and metadata schema. Prerelease schemas are
//! refused rather than rewritten; browser settings owns explicit deletion.
use super::Error;
use web_sys::{IdbDatabase, IdbIndexParameters, IdbObjectStoreParameters};
pub(super) const VERSION: u32 = 1;

pub fn create(database: &IdbDatabase) -> Result<(), Error> {
	if database.object_store_names().length() != 0 {
		return Err(Error::Schema);
	}
	let parameters = IdbObjectStoreParameters::new();
	parameters.set_key_path(&"key".into());
	let records = database.create_object_store_with_optional_parameters("archive-records", &parameters)?;
	let index = IdbIndexParameters::new();
	index.set_unique(true);
	records.create_index_with_str_and_optional_parameters("revision", "revision", &index)?;
	let context: js_sys::Array = ["context", "revision"]
		.into_iter()
		.map(wasm_bindgen::JsValue::from_str)
		.collect();
	records.create_index_with_str_sequence_and_optional_parameters("context", &context, &index)?;
	records.create_index_with_str("coordinates", "coordinates")?;
	let digest = IdbIndexParameters::new();
	digest.set_multi_entry(true);
	records.create_index_with_str_and_optional_parameters("digest", "digests", &digest)?;
	database.create_object_store_with_optional_parameters("archive-blobs", &parameters)?;
	database.create_object_store_with_optional_parameters("archive-meta", &parameters)?;
	Ok(())
}
pub fn validate(database: &IdbDatabase) -> Result<(), Error> {
	let names = database.object_store_names();
	let expected = ["archive-records", "archive-blobs", "archive-meta"];
	if database.version() != VERSION as f64 || names.length() != 3 || expected.iter().any(|name| !names.contains(name))
	{
		return Err(Error::Schema);
	}
	let stores = expected
		.iter()
		.map(|name| wasm_bindgen::JsValue::from_str(name))
		.collect::<js_sys::Array>();
	let transaction = database.transaction_with_str_sequence(&stores)?;
	for name in expected {
		let store = transaction.object_store(name)?;
		if store.key_path()?.as_string().as_deref() != Some("key") || store.auto_increment() {
			return Err(Error::Schema);
		}
	}
	let records = transaction.object_store("archive-records")?;
	if records.index_names().length() != 4 {
		return Err(Error::Schema);
	}
	for (name, unique) in [("revision", true), ("coordinates", false)] {
		let index = records.index(name)?;
		if index.key_path()?.as_string().as_deref() != Some(name) || index.unique() != unique || index.multi_entry() {
			return Err(Error::Schema);
		}
	}
	let context = records.index("context")?;
	let path = context.key_path()?;
	if !js_sys::Array::is_array(&path) || !context.unique() || context.multi_entry() {
		return Err(Error::Schema);
	}
	let path = js_sys::Array::from(&path);
	if path.length() != 2 || path.get(0) != "context" || path.get(1) != "revision" {
		return Err(Error::Schema);
	}
	let digest = records.index("digest")?;
	if digest.key_path()?.as_string().as_deref() != Some("digests") || digest.unique() || !digest.multi_entry() {
		return Err(Error::Schema);
	}
	Ok(())
}
