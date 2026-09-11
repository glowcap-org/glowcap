//! Preserve the version-one records, blob and metadata keys used by existing tabs.
use super::Error;
use web_sys::{IdbDatabase, IdbIndexParameters, IdbObjectStoreParameters};
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
	records.create_index_with_str("coordinates", "coordinates")?;
	database.create_object_store_with_optional_parameters("archive-blobs", &parameters)?;
	database.create_object_store_with_optional_parameters("archive-meta", &parameters)?;
	Ok(())
}
pub fn validate(database: &IdbDatabase) -> Result<(), Error> {
	let names = database.object_store_names();
	let expected = ["archive-records", "archive-blobs", "archive-meta"];
	if database.version() != 1.0 || names.length() != 3 || expected.iter().any(|name| !names.contains(name)) {
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
	if records.index_names().length() != 2 {
		return Err(Error::Schema);
	}
	for (name, unique) in [("revision", true), ("coordinates", false)] {
		let index = records.index(name)?;
		if index.key_path()?.as_string().as_deref() != Some(name) || index.unique() != unique || index.multi_entry() {
			return Err(Error::Schema);
		}
	}
	Ok(())
}
