//! Structured-clone values, not CapTP references. Scalar syntax is small;
//! document fields are admitted by their UTF-8 replacement length before copy.
use super::Error;
use js_sys::{Array, JsString, Object, Reflect};
use rooms_application::{
	archive::output::Output,
	room::{ArgumentView, ListArgument},
	text::DocumentText,
};
use std::cell::OnceCell;
use wasm_bindgen::{JsCast, JsValue};
pub(super) struct Stored {
	value: JsValue,
	text: OnceCell<Option<String>>,
}
impl Stored {
	pub fn new(value: JsValue) -> Self {
		Self {
			value,
			text: OnceCell::new(),
		}
	}
}
impl ArgumentView for Stored {
	fn boolean(&self) -> Option<bool> {
		self.value.as_bool()
	}
	fn is_null(&self) -> bool {
		self.value.is_null()
	}
	fn text(&self) -> Option<&str> {
		self.text
			.get_or_init(|| {
				let text = self.value.dyn_ref::<JsString>()?;
				(text.length() <= 64).then(|| self.value.as_string()).flatten()
			})
			.as_deref()
	}
	fn document(&self, maximum: usize) -> Option<DocumentText> {
		document(&self.value, maximum)
	}
	fn integer(&self) -> Option<i128> {
		self.value
			.dyn_ref::<js_sys::BigInt>()
			.and_then(|n| i128::try_from(n.clone()).ok())
	}
	fn float(&self) -> Option<f64> {
		self.value.as_f64()
	}
	fn contains_capability(&self) -> bool {
		false
	}
}
impl ListArgument for Stored {
	fn list_len(&self) -> Option<usize> {
		Array::is_array(&self.value).then(|| self.value.unchecked_ref::<Array>().length() as usize)
	}
	fn at(&self, index: usize) -> Option<Self> {
		(index < self.list_len()?).then(|| Self::new(self.value.unchecked_ref::<Array>().get(index as u32)))
	}
}
pub(super) fn document(value: &JsValue, maximum: usize) -> Option<DocumentText> {
	let text = value.dyn_ref::<JsString>()?;
	if text.length() as usize > maximum {
		return None;
	}
	let units = || (0..text.length()).map(|i| text.char_code_at(i) as u16);
	let bytes: usize = char::decode_utf16(units())
		.map(|c| c.unwrap_or(char::REPLACEMENT_CHARACTER).len_utf8())
		.sum();
	if bytes > maximum {
		return None;
	}
	Some(DocumentText::from_utf16(&units().collect::<Vec<_>>()))
}
pub(super) fn text(value: &DocumentText) -> JsValue {
	match value.as_str() {
		Some(value) => value.into(),
		None => JsString::from_char_code(&value.utf16().collect::<Vec<_>>()).into(),
	}
}
pub(super) struct Values;
impl Output for Values {
	type Value = JsValue;
	fn document(value: &DocumentText) -> JsValue {
		text(value)
	}
	fn text(value: &str) -> JsValue {
		value.into()
	}
	fn integer(value: u64) -> JsValue {
		js_sys::BigInt::from(value).into()
	}
	fn boolean(value: bool) -> JsValue {
		value.into()
	}
	fn null() -> JsValue {
		JsValue::NULL
	}
	fn list(values: Vec<JsValue>) -> JsValue {
		values.into_iter().collect::<Array>().into()
	}
}
pub(super) fn object(fields: &[(&str, JsValue)]) -> Result<JsValue, Error> {
	let row = Object::new();
	for (name, value) in fields {
		Reflect::set(&row, &(*name).into(), value)?;
	}
	Ok(row.into())
}
pub(super) fn get(row: &JsValue, key: &str) -> Result<JsValue, Error> {
	Reflect::get(row, &key.into()).map_err(Into::into)
}
pub(super) fn shape(row: &JsValue, fields: &[&str]) -> Result<(), Error> {
	if !row.is_object() || row.is_null() || Array::is_array(row) {
		return Err(Error::Invalid("invalid archive storage row"));
	}
	let keys = Object::keys(row.unchecked_ref::<Object>());
	if keys.length() as usize != fields.len() || keys.iter().any(|k| !fields.iter().any(|f| k == JsValue::from_str(f)))
	{
		return Err(Error::Invalid("invalid archive storage fields"));
	}
	Ok(())
}
pub(super) fn natural(value: &JsValue, maximum: u64) -> Result<u64, Error> {
	let n = value
		.as_f64()
		.filter(|n| n.is_finite() && *n >= 0.0 && n.fract() == 0.0 && *n <= maximum as f64)
		.ok_or(Error::Invalid("invalid archive storage integer"))?;
	Ok(n as u64)
}
