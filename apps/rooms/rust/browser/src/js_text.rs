//! One owner for reading a bounded JavaScript string into Rust. A crossing is
//! refused when it is longer than its caller's limit, and otherwise copied once.
//! `scalar` requires Unicode scalar text. `document` keeps isolated UTF-16
//! surrogates by copying them a code unit at a time only when the string is not
//! well formed. `String.prototype.isWellFormed` answers that in one call without
//! building a second JavaScript string.
use rooms_application::text::DocumentText;
use wasm_bindgen::{JsCast, prelude::*};

// Bind `isWellFormed` on a `JsString` view. A method binding needs
// a type declared in this block.
#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(extends = js_sys::JsString)]
	type WellFormedString;
	#[wasm_bindgen(method, js_name = isWellFormed)]
	fn is_well_formed(this: &WellFormedString) -> bool;
}

/// Why a crossing was refused. The caller renders it in its own error idiom.
pub enum Refusal {
	TooLong,
	Malformed,
}
impl Refusal {
	pub fn message(&self) -> &'static str {
		match self {
			Self::TooLong => "Rooms text exceeds its input limit",
			Self::Malformed => "Rooms protocol text must contain Unicode scalar values",
		}
	}
}
impl std::fmt::Display for Refusal {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str(self.message())
	}
}

/// Whether a JavaScript string contains no isolated UTF-16 surrogate. A decoder
/// that reads scalar and non-scalar text into different types branches on this.
pub fn well_formed(value: &js_sys::JsString) -> bool {
	value.unchecked_ref::<WellFormedString>().is_well_formed()
}

/// Read a bounded string that must contain only Unicode scalar values.
pub fn scalar(value: &js_sys::JsString, max_units: usize) -> Result<String, Refusal> {
	if value.length() as usize > max_units {
		return Err(Refusal::TooLong);
	}
	if !well_formed(value) {
		return Err(Refusal::Malformed);
	}
	value.as_string().ok_or(Refusal::Malformed)
}

/// Read a bounded document, keeping isolated UTF-16 surrogates. Only a document
/// that is not well formed takes the slow code-unit path. Ordinary text takes
/// the one bulk transfer.
pub fn document(value: &js_sys::JsString, max_units: usize) -> Result<DocumentText, Refusal> {
	if value.length() as usize > max_units {
		return Err(Refusal::TooLong);
	}
	if well_formed(value) {
		value.as_string().map(DocumentText::from).ok_or(Refusal::Malformed)
	} else {
		Ok(DocumentText::from_utf16(&value.iter().collect::<Vec<_>>()))
	}
}
