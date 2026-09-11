//! Existing rooms-history v1 envelopes and keys. Keys remain JSON strings;
//! record payloads reuse the shared tuple grammar, including BigInt fields.
use super::super::{
	value::{self, Stored, Values},
	Error,
};
use rooms_application::archive::{self, blobs::Address, index::Entry, output::Output, ConversationKind, Kind, Record};
use std::sync::Arc;
use wasm_bindgen::JsValue;
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
		("row", Values::list(archive::output::record::<Values>(record))),
	])
}
pub(in crate::storage) fn decode(row: JsValue) -> Result<Entry, Error> {
	value::shape(&row, &["key", "coordinates", "revision", "row"])?;
	let revision = value::natural(&value::get(&row, "revision")?, MAX_SAFE)?;
	if revision == 0 {
		return Err(Error::Invalid("invalid archive storage revision"));
	}
	let record = archive::protocol::record(&Stored::new(value::get(&row, "row")?))?;
	if value::get(&row, "key")? != key(&record) || value::get(&row, "coordinates")? != coordinates(&record) {
		return Err(Error::Invalid("archive record does not match its storage key"));
	}
	Ok(Entry {
		revision,
		record: Arc::new(record),
	})
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
