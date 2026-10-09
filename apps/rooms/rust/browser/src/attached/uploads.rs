//! Browser readers supply bounded byte spans. Rust owns source custody and
//! the file-transfer protocol on the application's one source pool.
use super::{Result, js_error, safe_integer, scalar};
use rooms_application::files::FileDescription;
use rooms_glowcap::client::sources::{Reader, Source};
use std::{future::Future, pin::Pin};
use wasm_bindgen::prelude::*;

struct BrowserReader(js_sys::Function);
impl Reader for BrowserReader {
	fn read(&self, offset: usize, length: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>>>>> {
		let read = self.0.clone();
		Box::pin(async move {
			let pending = read
				.call2(&JsValue::UNDEFINED, &(offset as f64).into(), &(length as f64).into())
				.map_err(|_| "Rooms source reader failed")?;
			let value = wasm_bindgen_futures::JsFuture::from(js_sys::Promise::resolve(&pending))
				.await
				.map_err(|_| "Rooms source read failed")?;
			let bytes = value
				.dyn_into::<js_sys::Uint8Array>()
				.map_err(|_| "Rooms source did not return bytes")?;
			if bytes.length() as usize != length {
				return Err("Rooms source returned an invalid span".into());
			}
			Ok(bytes.to_vec())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsBrowserSource {
	pub(super) source: Source,
}
#[wasm_bindgen]
impl RoomsBrowserSource {
	#[wasm_bindgen(constructor)]
	pub fn new(
		name: js_sys::JsString,
		mime: js_sys::JsString,
		size: f64,
		width: u32,
		height: u32,
		read: js_sys::Function,
	) -> std::result::Result<RoomsBrowserSource, JsValue> {
		let input = (|| {
			let description = FileDescription::new(
				scalar(name, 65_536)?,
				scalar(mime, 65_536)?,
				safe_integer(size)?,
				width.into(),
				height.into(),
			)
			.map_err(|e| e.to_string())?;
			Ok(Self {
				source: Source::reader(description, BrowserReader(read)),
			})
		})();
		input.map_err(|error: String| js_error(&error))
	}
}
