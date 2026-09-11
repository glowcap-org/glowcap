//! Bounded file materialization in the browser heap. Only individual chunks
//! cross Wasm memory; the displayed URL retains the shared receiver charge.
use super::{hold, Reader, RoomsBrowserFile};
use crate::{
	abort::Abort,
	attached::{observation::call, Environment, Result, RoomsBrowserSession},
};
use rooms_application::{
	archive::Record,
	files::{receiving::Charge, CHUNK_BYTES},
};
use std::rc::Rc;
use wasm_bindgen::prelude::*;

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
async fn materialize(
	environment: &Environment,
	mut reader: Reader,
	progress: Option<js_sys::Function>,
) -> Result<JsValue> {
	let description = reader.payload.file.description()?;
	let size = description.size();
	let mime = description.mime().to_owned();
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
	options.set_type(&mime);
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
#[wasm_bindgen]
impl RoomsBrowserFile {
	pub fn open(&self, progress: Option<js_sys::Function>, signal: Option<web_sys::AbortSignal>) -> js_sys::Promise {
		let input = self.reader().and_then(|reader| Ok((reader, Abort::new(signal)?)));
		let (reader, mut abort) = match input {
			Ok(input) => input,
			Err(error) => return crate::attached::rejected(error),
		};
		self.driver.submit(CHUNK_BYTES, move |environment| async move {
			tokio::select! { biased;
				() = abort.cancelled() => Err("Rooms file view was cancelled".into()),
				result = materialize(&environment, reader, progress) => result,
			}
		})
	}
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = openArchivedFile)]
	pub fn open_archived_file(
		&self,
		record: js_sys::JsString,
		index: u32,
		progress: Option<js_sys::Function>,
		signal: Option<web_sys::AbortSignal>,
	) -> js_sys::Promise {
		let bytes = record.length() as usize * 3 + CHUNK_BYTES;
		let input = (|| {
			Ok((
				crate::attached::scalar(record, 512 * 1024)?,
				self.owner.session()?,
				Abort::new(signal)?,
			))
		})();
		let (json, session, mut abort) = match input {
			Ok(input) => input,
			Err(error) => return crate::attached::rejected(error),
		};
		let driver = self.driver.clone();
		let scope = self.scope.clone();
		let generation = scope.generation();
		self.driver
			.submit(bytes, move |environment: Rc<Environment>| async move {
				let work = async {
					scope.current(generation)?;
					let record: Record = serde_json::from_str(&json).map_err(|e| e.to_string())?;
					let file = session
						.archived_attachment(&record, index as usize)
						.await
						.map_err(|e| e.to_string())?;
					scope.current(generation)?;
					let file = hold(&driver, &scope, file)?;
					materialize(&environment, file.reader()?, progress).await
				};
				tokio::select! { biased;
					() = abort.cancelled() => Err("Rooms archived-file view was cancelled".into()),
					() = scope.stopped() => Err("Rooms attachment closed during its archived-file lookup".into()),
					result = work => result,
				}
			})
	}
}
