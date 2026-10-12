//! One browser display budget and Blob materializer for live and archived
//! readers. Chunks cross Wasm once. The URL owns its charge until retirement.
use crate::attached::{Environment, Result, observation::call};
use rooms_application::files::{CHUNK_BYTES, receiving::Charge};
use wasm_bindgen::prelude::*;

pub(crate) trait Reader {
	async fn read(&mut self, offset: u64, maximum: usize) -> Result<Vec<u8>>;
}

#[wasm_bindgen]
pub struct RoomsBrowserFileView {
	url: String,
	charge: Option<Charge>,
}
#[wasm_bindgen]
impl RoomsBrowserFileView {
	#[wasm_bindgen(getter)]
	pub fn url(&self) -> String {
		self.url.clone()
	}
	pub fn release(&mut self) -> std::result::Result<(), JsValue> {
		if self.charge.is_some() {
			web_sys::Url::revoke_object_url(&self.url)?;
			self.charge.take();
		}
		Ok(())
	}
}
impl Drop for RoomsBrowserFileView {
	fn drop(&mut self) {
		let _ = self.release();
	}
}

pub(crate) async fn materialize(
	environment: &Environment,
	mut reader: impl Reader,
	size: usize,
	mime: &str,
	progress: Option<js_sys::Function>,
) -> Result<JsValue> {
	let mut charge = environment
		.displays
		.reserve(size)
		.ok_or("Rooms displayed files fill the receiver budget; close an existing file view before retrying")?;
	let chunks = js_sys::Array::new();
	let mut offset = 0;
	while offset < size {
		let length = CHUNK_BYTES.min(size - offset);
		let bytes = reader.read(offset as u64, length).await?;
		if bytes.len() != length {
			return Err("Rooms file returned an incomplete span".into());
		}
		chunks.push(&js_sys::Uint8Array::from(bytes.as_slice()));
		offset += length;
		if let Some(progress) = &progress {
			call(progress, (offset as f64).into())?;
		}
	}
	let options = web_sys::BlobPropertyBag::new();
	options.set_type(mime);
	let blob = web_sys::Blob::new_with_u8_array_sequence_and_options(&chunks, &options)
		.map_err(|_| "Rooms file could not be materialized")?;
	let url = web_sys::Url::create_object_url_with_blob(&blob).map_err(|_| "Rooms file view could not be opened")?;
	charge.captured();
	Ok(RoomsBrowserFileView {
		url,
		charge: Some(charge),
	}
	.into())
}
