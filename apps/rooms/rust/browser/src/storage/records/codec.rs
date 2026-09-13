//! IndexedDB record envelopes and keys. Keys remain JSON strings;
//! record payloads reuse the shared tuple grammar, including BigInt fields.
use super::super::{
	Error,
	value::{self, Stored, Values},
};
use rooms_application::archive::{self, ConversationKind, Kind, Record, blobs::Address, index::Entry, output::Output};
use std::sync::Arc;
use wasm_bindgen::{JsCast, JsValue};
const MAX_SAFE: u64 = (1 << 53) - 1;
fn kind(record: &Record) -> &'static str {
	if record.kind() == Kind::Line {
		"line"
	} else {
		"standing"
	}
}
fn conversation(kind: ConversationKind) -> &'static str {
	match kind {
		ConversationKind::Room => "room",
		ConversationKind::Direct => "direct",
	}
}
fn json(value: impl serde::Serialize) -> JsValue {
	serde_json::to_string(&value).expect("archive key serialization").into()
}
pub(super) fn key(record: &Record) -> JsValue {
	let c = record.coordinates();
	json((
		&c.source,
		&c.generation,
		kind(record),
		record.conversation_kind().map(conversation).unwrap_or(""),
		record.directory(),
		record.conversation(),
		&c.id,
	))
}
pub(super) fn coordinates(record: &Record) -> JsValue {
	let c = record.coordinates();
	match record.conversation_kind() {
		Some(k) => json((
			&c.source,
			&c.generation,
			&c.id,
			"line",
			conversation(k),
			record.directory(),
			record.conversation(),
		)),
		None => json((
			&c.source,
			&c.generation,
			&c.id,
			"standing",
			record.directory(),
			record.conversation(),
		)),
	}
}
pub(in crate::storage) fn address_key(address: &Address) -> JsValue {
	let c = address.coordinates();
	json((
		&c.source,
		&c.generation,
		&c.id,
		conversation(address.conversation_kind()),
		address.directory(),
		address.conversation(),
		address.index(),
	))
}
pub(in crate::storage) fn address_coordinates(address: &Address) -> JsValue {
	let c = address.coordinates();
	json((
		&c.source,
		&c.generation,
		&c.id,
		"line",
		conversation(address.conversation_kind()),
		address.directory(),
		address.conversation(),
	))
}
pub(super) fn encode(record: &Record, revision: u64) -> Result<JsValue, Error> {
	value::object(&[
		("key", key(record)),
		("coordinates", coordinates(record)),
		("revision", (revision as f64).into()),
		("digests", digests(record).into()),
		("row", Values::list(archive::output::record::<Values>(record))),
	])
}
pub(in crate::storage) fn decode(row: JsValue) -> Result<Entry, Error> {
	value::shape(&row, &["key", "coordinates", "revision", "digests", "row"])?;
	let revision = value::natural(&value::get(&row, "revision")?, MAX_SAFE)?;
	if revision == 0 {
		return Err(Error::Invalid("invalid archive storage revision"));
	}
	let record = archive::protocol::record(&Stored::new(value::get(&row, "row")?))?;
	if value::get(&row, "key")? != key(&record) || value::get(&row, "coordinates")? != coordinates(&record) {
		return Err(Error::Invalid("archive record does not match its storage key"));
	}
	if !digests_match(&value::get(&row, "digests")?, &record) {
		return Err(Error::Invalid("archive record does not match its digest index"));
	}
	Ok(Entry {
		revision,
		record: Arc::new(record),
	})
}
fn digests(record: &Record) -> js_sys::Array {
	archive::blobs::files(record)
		.unwrap_or(&[])
		.iter()
		.filter_map(|attachment| attachment.blob())
		.map(JsValue::from_str)
		.collect()
}
fn digests_match(stored: &JsValue, record: &Record) -> bool {
	if !js_sys::Array::is_array(stored) {
		return false;
	}
	let stored = stored.unchecked_ref::<js_sys::Array>();
	let expected = archive::blobs::files(record)
		.unwrap_or(&[])
		.iter()
		.filter_map(|attachment| attachment.blob());
	stored.length() as usize == expected.clone().count()
		&& expected
			.enumerate()
			.all(|(index, digest)| stored.get(index as u32).as_string().as_deref() == Some(digest))
}
pub(in crate::storage) fn meta(row: JsValue, key: &str, maximum: u64) -> Result<u64, Error> {
	if row.is_undefined() {
		return Ok(0);
	}
	value::shape(&row, &["key", "value"])?;
	if value::get(&row, "key")? != JsValue::from_str(key) {
		return Err(Error::Invalid("invalid archive metadata key"));
	}
	value::natural(&value::get(&row, "value")?, maximum)
}
pub(in crate::storage) fn number(key: &str, value: u64) -> Result<JsValue, Error> {
	value::object(&[("key", key.into()), ("value", (value as f64).into())])
}
