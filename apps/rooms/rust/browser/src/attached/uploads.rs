//! Browser readers supply bounded byte spans. Rust owns source custody and
//! the file-transfer protocol on the application's one source pool.
use super::{js_error, safe_integer, scalar};
use rooms_application::files::FileDescription;
use rooms_glowcap::client::sources::{Reader, Source};
use rooms_runtime::Error as RuntimeError;
use std::{future::Future, pin::Pin};
use wasm_bindgen::prelude::*;

struct BrowserReader(js_sys::Function);
impl Reader for BrowserReader {
	fn read(
		&self,
		offset: usize,
		length: usize,
	) -> Pin<Box<dyn Future<Output = core::result::Result<Vec<u8>, String>>>> {
		let read = self.0.clone();
		Box::pin(async move {
			let pending = read
				.call2(&JsValue::UNDEFINED, &(offset as f64).into(), &(length as f64).into())
				.map_err(|_| "Rooms source reader failed".to_string())?;
			let value = wasm_bindgen_futures::JsFuture::from(js_sys::Promise::resolve(&pending))
				.await
				.map_err(|_| "Rooms source read failed".to_string())?;
			let bytes = value
				.dyn_into::<js_sys::Uint8Array>()
				.map_err(|_| "Rooms source did not return bytes".to_string())?;
			if bytes.length() as usize != length {
				return Err("Rooms source returned an invalid span".to_string());
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
			.map_err(RuntimeError::invalid_by)?;
			Ok(Self {
				source: Source::reader(description, BrowserReader(read)),
			})
		})();
		input.map_err(|error: RuntimeError| js_error(&error))
	}
}
