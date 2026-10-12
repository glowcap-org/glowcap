//! Device recorder identity and the cross-tab retention fence are committed in
//! the same metadata store the existing application reads.
use super::{Database, Error, Operation, Steps};
use rooms_application::text::DocumentText;
use rooms_runtime::entropy::Entropy;
use wasm_bindgen::JsValue;
use web_sys::IdbTransactionMode;
const META: &str = "archive-meta";
const SOURCE: &str = "source";
const EPOCH: &str = "retention-epoch";
pub(super) fn valid(value: &DocumentText) -> bool {
	let mut count = 0;
	for unit in value.utf16() {
		count += 1;
		if count > 128 || unit <= 0x1f || (0x7f..=0x9f).contains(&unit) {
			return false;
		}
	}
	count != 0
}
pub(super) fn identity(value: JsValue, key: &str) -> Result<DocumentText, Error> {
	if !value.is_object() || value.is_null() {
		return Err(Error::Invalid("invalid history identity"));
	}
	let object = js_sys::Object::from(value);
	if js_sys::Object::keys(&object).length() != 2
		|| js_sys::Reflect::get(&object, &"key".into())? != JsValue::from_str(key)
	{
		return Err(Error::Invalid("invalid history identity"));
	}
	let value = js_sys::Reflect::get(&object, &"value".into())?;
	if !value.is_string() {
		return Err(Error::Invalid("invalid history identity"));
	}
	let text = js_sys::JsString::from(value);
	if text.length() == 0 || text.length() > 128 {
		return Err(Error::Invalid("invalid history identity"));
	}
	let units: Vec<u16> = (0..text.length()).map(|at| text.char_code_at(at) as u16).collect();
	let text = DocumentText::from_utf16(&units);
	if !valid(&text) {
		return Err(Error::Invalid("invalid history identity"));
	}
	Ok(text)
}
pub(super) fn row(key: &str, value: DocumentText) -> Result<JsValue, Error> {
	let object = js_sys::Object::new();
	let units: Vec<_> = value.utf16().collect();
	js_sys::Reflect::set(&object, &"key".into(), &key.into())?;
	js_sys::Reflect::set(&object, &"value".into(), &js_sys::JsString::from_char_code(&units))?;
	Ok(object.into())
}
pub(super) fn fresh(entropy: &mut impl Entropy) -> Result<DocumentText, Error> {
	let mut bytes = [0u8; 16];
	entropy
		.fill(&mut bytes)
		.map_err(|_| Error::Invalid("history identity entropy unavailable"))?;
	bytes[6] = (bytes[6] & 0x0f) | 0x40;
	bytes[8] = (bytes[8] & 0x3f) | 0x80;
	use std::fmt::Write;
	let mut text = String::with_capacity(36);
	for (i, byte) in bytes.iter().enumerate() {
		if matches!(i, 4 | 6 | 8 | 10) {
			text.push('-');
		}
		write!(text, "{byte:02x}").expect("writing into String");
	}
	Ok(text.into())
}
impl Database {
	async fn identity(&self, key: &'static str, entropy: &mut impl Entropy) -> Result<DocumentText, Error> {
		let initial = fresh(entropy)?;
		let mut operation = Operation::start(self, &[META], IdbTransactionMode::Readwrite, initial, |steps| {
			steps.request(steps.store(META)?.get(&key.into())?, move |steps, value| {
				if value.is_undefined() {
					steps.data(|value| {
						steps.store(META)?.put(&row(key, value.clone())?)?;
						Ok(())
					})
				} else {
					steps.data(|held| {
						*held = identity(value, key)?;
						Ok(())
					})
				}
			})
		})?;
		operation.wait().await
	}
	pub async fn source(&self, entropy: &mut impl Entropy) -> Result<DocumentText, Error> {
		self.identity(SOURCE, entropy).await
	}
	pub async fn retention_epoch(&self, entropy: &mut impl Entropy) -> Result<DocumentText, Error> {
		self.identity(EPOCH, entropy).await
	}
	/// Atomically fence old recorders and optionally erase content. Source and
	/// revision high-water mark survive. Abandoning observation changes no effect.
	pub async fn set_retention_epoch(&self, epoch: DocumentText, erase: bool) -> Result<(), Error> {
		if !valid(&epoch) {
			return Err(Error::Invalid("invalid history retention identity"));
		}
		let mut operation = Operation::start(
			self,
			if erase {
				&[META, "archive-records", "archive-blobs"]
			} else {
				&[META]
			},
			IdbTransactionMode::Readwrite,
			(),
			|steps| {
				steps.store(META)?.put(&row(EPOCH, epoch)?)?;
				if erase {
					clear(steps)?;
				}
				Ok(())
			},
		)?;
		operation.wait().await
	}
}
pub(super) fn clear<T>(steps: &Steps<T>) -> Result<(), Error> {
	steps.store("archive-records")?.clear()?;
	steps.store("archive-blobs")?.clear()?;
	steps
		.store(META)?
		.put(&super::records::codec::number("blob-bytes", 0)?)?;
	Ok(())
}
