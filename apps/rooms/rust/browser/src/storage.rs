//! Browser storage effects. Request callbacks extend a transaction synchronously;
//! only its complete/abort event publishes the operation's outcome.
mod backend;
pub use backend::PageArchive;
mod blobs;
mod database;
mod erase;
pub(crate) use erase::Eraser;
mod memory;
mod metadata;
mod records;
mod transaction;
mod value;
pub use database::Database;
pub use records::Archive;
pub(crate) use transaction::{Operation, Steps};
use wasm_bindgen::{JsCast, JsValue};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	Unavailable,
	Blocked,
	Closed,
	Schema,
	Invalid(&'static str),
	Platform(String),
	Archive(rooms_application::archive::Error),
}
impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::Unavailable => f.write_str("browser storage is unavailable"),
			Self::Blocked => f.write_str("browser storage is blocked by another tab"),
			Self::Closed => f.write_str("browser storage is closed"),
			Self::Schema => f.write_str("browser history has an unsupported schema"),
			Self::Invalid(why) => f.write_str(why),
			Self::Archive(error) => error.fmt(f),
			Self::Platform(why) => write!(f, "browser storage: {why}"),
		}
	}
}
impl std::error::Error for Error {}
impl From<JsValue> for Error {
	fn from(value: JsValue) -> Self {
		let message = if value.is_string() {
			value
		} else {
			js_sys::Reflect::get(&value, &"message".into()).unwrap_or(JsValue::UNDEFINED)
		};
		let reason = message
			.dyn_ref::<js_sys::JsString>()
			.map(|text| String::from(text.slice(0, rooms_application::failure::MAX_REASON_BYTES as u32)))
			.unwrap_or_else(|| "IndexedDB operation failed".into());
		Self::Platform(rooms_application::failure::reason_prefix(&reason).into())
	}
}

impl From<rooms_application::archive::Error> for Error {
	fn from(value: rooms_application::archive::Error) -> Self {
		Self::Archive(value)
	}
}
