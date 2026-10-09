//! Browser readers retain shared Loam facades. Narrowing and returned blobs
//! keep the original session and upstream admission through every await.
use super::*;
use crate::{abort::Abort, attached::file_display};
use rooms_application::archive::{Access, Filter, Record};
use rooms_glowcap::client::archive::{Archive, Blob};

fn coordinate(raw: js_sys::JsString) -> Result<custody::Coordinate> {
	let raw = scalar(raw, 256)?;
	custody::Coordinate::decode(&raw).map_err(|_| "Invalid reader custody coordinate".into())
}
fn filter(raw: js_sys::JsString) -> Result<Filter> {
	let raw = scalar(raw, 16384)?;
	let filter: Filter = serde_json::from_str(&raw).map_err(|_| "Invalid archive filter")?;
	filter.validate().map_err(|e| e.to_string())?;
	Ok(filter)
}
#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = issuedArchiveShares)]
	pub fn issued_archive_shares(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		self.driver.submit(0, move |_| async move {
			let shares = workspace.issued_archive_shares().await.map_err(|error| error.to_string())?;
			let rows: Vec<_> = shares.iter().map(|row| serde_json::json!({ "id": row.share.id(), "label": row.share.label(), "filter": row.share.filter(), "sturdyref": row.sturdyref })).collect();
			json(&serde_json::to_string(&rows).map_err(|_| "Invalid issued archive shares")?)
		})
	}
	#[wasm_bindgen(js_name = deviceHistory)]
	pub fn device_history(&self, files: bool) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |_| async move {
			let archive = workspace.device_history(files).await.map_err(|e| e.to_string())?;
			RoomsManagedArchive::new(driver, archive).map(Into::into)
		})
	}
	#[wasm_bindgen(js_name = selectedArchive)]
	pub fn selected_archive(&self, files: bool) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |_| async move {
			let archive = workspace.selected_archive(files).await.map_err(|e| e.to_string())?;
			RoomsManagedArchive::new(driver, archive).map(Into::into)
		})
	}
	#[wasm_bindgen(js_name = readBridgeForm)]
	pub fn read_bridge_form(&self, seat: js_sys::JsString) -> js_sys::Promise {
		let seat = match coordinate(seat) {
			Ok(seat) => seat,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		self.driver.submit(256, move |_| async move {
			match workspace.bridge_form(seat).await.map_err(|e| e.to_string())? {
				Some(form) => json(&form.encode().map_err(|e| e.to_string())?),
				None => Ok(JsValue::NULL),
			}
		})
	}
	#[wasm_bindgen(js_name = readHistory)]
	pub fn read_history(&self, seat: js_sys::JsString) -> js_sys::Promise {
		let seat = match coordinate(seat) {
			Ok(seat) => seat,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		self.driver.submit(256, move |_| async move {
			let lines = workspace.history(seat).await.map_err(|e| e.to_string())?;
			let output = js_sys::Array::new();
			for line in lines {
				output.push(&json(&serde_json::json!({"from": line.from, "text": line.text, "at": line.at, "previewUrls": line.previews.urls()}).to_string())?);
			}
			Ok(output.into())
		})
	}
	#[wasm_bindgen(js_name = archiveReader)]
	pub fn archive_reader(&self, selected: js_sys::JsString, files: bool) -> js_sys::Promise {
		let selected = match coordinate(selected) {
			Ok(selected) => selected,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(256, move |environment| async move {
			let reference = workspace
				.archive_reader(selected, files)
				.await
				.map_err(|e| e.to_string())?;
			let archive = Archive::local(
				environment.runtime.host().clone(),
				environment.platform.clone(),
				reference,
			);
			RoomsManagedArchive::new(driver, archive).map(Into::into)
		})
	}
}

#[wasm_bindgen]
pub struct RoomsManagedArchive {
	driver: Driver,
	archive: Held<Archive<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedArchive {
	#[wasm_bindgen(js_name = readTogether)]
	pub fn read_together(&self, device: &RoomsManagedArchive, selection: js_sys::JsString) -> js_sys::Promise {
		let filter = match filter(selection) {
			Ok(filter) => filter,
			Err(error) => return rejected(error),
		};
		let archive = self.archive.clone();
		let device = device.archive.clone();
		self.driver.submit(16384, move |_| async move {
			let records = archive.read_together(&device, &filter).await.map_err(|e| e.to_string())?;
			json(&serde_json::json!({"records":records.iter().map(|row| serde_json::json!({"record":row.record,"keeper":row.keeper})).collect::<Vec<_>>()}).to_string())
		})
	}
	#[wasm_bindgen(js_name = openAttachment)]
	pub fn open_attachment(
		&self,
		record: js_sys::JsString,
		index: u32,
		progress: Option<js_sys::Function>,
		signal: Option<web_sys::AbortSignal>,
	) -> js_sys::Promise {
		let input = (|| {
			let raw = scalar(record, 65536)?;
			let record: Record = serde_json::from_str(&raw).map_err(|_| "Invalid archive record")?;
			let description = rooms_application::archive::blobs::files(&record)
				.map_err(|e| e.to_string())?
				.get(index as usize)
				.ok_or("Missing archive attachment")?
				.live_description()
				.map_err(|e| e.to_string())?;
			Ok((raw.len(), record, description, Abort::new(signal)?))
		})();
		let (bytes, record, description, mut abort) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let archive = self.archive.clone();
		self.driver.submit(
			bytes + rooms_application::files::CHUNK_BYTES,
			move |environment| async move {
				let work = async {
					let blob = archive
						.attachment(&record, index as usize)
						.await
						.map_err(|e| e.to_string())?;
					file_display::materialize(
						&environment,
						BlobReader(blob),
						description.size(),
						description.mime(),
						progress,
					)
					.await
				};
				tokio::select! { biased;
					() = abort.cancelled() => Err("Rooms archived-file view was cancelled".into()),
					result = work => result,
				}
			},
		)
	}
}
impl RoomsManagedArchive {
	fn new(driver: Driver, archive: Archive<Platform>) -> Result<Self> {
		let archive = driver.hold(archive, size_of::<Archive<Platform>>())?;
		Ok(Self { driver, archive })
	}
}

struct BlobReader(Blob<Platform>);
impl file_display::Reader for BlobReader {
	async fn read(&mut self, offset: u64, maximum: usize) -> Result<Vec<u8>> {
		self.0.read(offset, maximum).await.map_err(|e| e.to_string())
	}
}
#[wasm_bindgen]
impl RoomsManagedArchive {
	pub fn read(&self, selection: js_sys::JsString, after: js_sys::JsString, limit: u32) -> js_sys::Promise {
		let input = (|| Ok((filter(selection)?, revision(&scalar(after, 20)?)?)))();
		let (filter, after) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let archive = self.archive.clone();
		self.driver.submit(16384, move |_| async move {
			let page = archive.read(&filter, after, limit as usize).await.map_err(|e| e.to_string())?;
			json(&serde_json::json!({"next": page.next.to_string(), "more": page.more, "records": page.records.iter().map(|entry| serde_json::json!({"revision": entry.revision.to_string(), "record": entry.record})).collect::<Vec<_>>()}).to_string())
		})
	}
	pub fn narrow(&self, selection: js_sys::JsString) -> js_sys::Promise {
		let filter = match filter(selection) {
			Ok(filter) => filter,
			Err(error) => return rejected(error),
		};
		let archive = self.archive.clone();
		let driver = self.driver.clone();
		self.driver.submit(16384, move |_| async move {
			let archive = archive.narrow(&filter, Access::Read).await.map_err(|e| e.to_string())?;
			Self::new(driver, archive).map(Into::into)
		})
	}
	pub fn attachment(&self, record: js_sys::JsString, index: u32) -> js_sys::Promise {
		let raw = match scalar(record, 65536) {
			Ok(raw) => raw,
			Err(error) => return rejected(error),
		};
		let record: Record = match serde_json::from_str(&raw) {
			Ok(record) => record,
			Err(_) => return rejected("Invalid archive record".into()),
		};
		let archive = self.archive.clone();
		let driver = self.driver.clone();
		self.driver.submit(raw.len(), move |_| async move {
			let blob = archive
				.attachment(&record, index as usize)
				.await
				.map_err(|e| e.to_string())?;
			RoomsManagedBlob::new(driver, blob).map(Into::into)
		})
	}
	pub fn blob(&self, digest: js_sys::JsString) -> js_sys::Promise {
		let digest = match scalar(digest, 64) {
			Ok(digest) => digest,
			Err(error) => return rejected(error),
		};
		let archive = self.archive.clone();
		let driver = self.driver.clone();
		self.driver.submit(digest.len(), move |_| async move {
			let blob = archive.blob(&digest).await.map_err(|e| e.to_string())?;
			RoomsManagedBlob::new(driver, blob).map(Into::into)
		})
	}
}

#[wasm_bindgen]
pub struct RoomsManagedBlob {
	driver: Driver,
	blob: Held<Blob<Platform>>,
}
impl RoomsManagedBlob {
	fn new(driver: Driver, blob: Blob<Platform>) -> Result<Self> {
		let blob = driver.hold(blob, size_of::<Blob<Platform>>())?;
		Ok(Self { driver, blob })
	}
}
#[wasm_bindgen]
impl RoomsManagedBlob {
	/// Streaming reads never assemble a complete file in the intermediary.
	pub fn read(&self, offset: js_sys::JsString, maximum: u32) -> js_sys::Promise {
		let offset = match scalar(offset, 20).and_then(|value| revision(&value)) {
			Ok(offset) => offset,
			Err(error) => return rejected(error),
		};
		if maximum == 0 || maximum as usize > rooms_application::files::CHUNK_BYTES {
			return rejected("File reads require a bounded nonzero chunk".into());
		}
		let blob = self.blob.clone();
		self.driver.submit(maximum as usize, move |_| async move {
			let bytes = blob.read(offset, maximum as usize).await.map_err(|e| e.to_string())?;
			Ok(js_sys::Uint8Array::from(bytes.as_slice()).into())
		})
	}
}
