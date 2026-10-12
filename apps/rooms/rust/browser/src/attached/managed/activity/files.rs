//! Incoming files retain their exact source. Reads acquire one dependent facade.
use super::*;
use crate::{abort::Abort, attached::file_display};
use rooms_glowcap::client::{Deadline, workspace::Workspace};
use std::{
	cell::{OnceCell, RefCell},
	rc::Rc,
};

pub(super) struct Selection {
	pub workspace: Held<Workspace<Platform>>,
	pub token: String,
	pub index: usize,
}

pub(super) struct File {
	description: serde_json::Value,
	reader: OnceCell<Ref>,
	selection: Option<Selection>,
}
pub(super) type Custody = Rc<RefCell<Option<Rc<File>>>>;
#[wasm_bindgen]
pub struct RoomsManagedFile {
	driver: Driver,
	file: Held<Custody>,
}
impl RoomsManagedFile {
	pub(super) fn retire(&self) {
		self.file.borrow_mut().take();
	}
}
/// One admitted attachment retains metadata and the actual source/blob guards.
/// If byte access was refused, one workspace edge and at most 103 cursor bytes
/// retain its exact selection for retry without losing the message. Both cases
/// charge fixed state below. No payload copies until a bounded Wasm read. The
/// first acquired reader stays installed and rechecks both grants on every read.
pub(super) fn hold(
	driver: &Driver,
	reader: std::result::Result<Ref, Selection>,
	description: serde_json::Value,
) -> Result<RoomsManagedFile> {
	let (reader, selection) = match reader {
		Ok(reader) => (OnceCell::from(reader), None),
		Err(selection) => (OnceCell::new(), Some(selection)),
	};
	let bytes = size_of::<File>()
		+ size_of::<RefCell<Option<Rc<File>>>>()
		+ 4 * size_of::<usize>()
		+ description.to_string().len()
		+ selection.as_ref().map_or(0, |selection| selection.token.len());
	let file = driver.hold(
		Rc::new(RefCell::new(Some(Rc::new(File {
			description,
			reader,
			selection,
		})))),
		bytes,
	)?;
	Ok(RoomsManagedFile {
		driver: driver.clone(),
		file,
	})
}
struct Reader {
	custody: Held<Custody>,
	environment: Rc<Environment>,
}
impl file_display::Reader for Reader {
	async fn read(&mut self, offset: u64, maximum: usize) -> Result<Vec<u8>> {
		read(&self.environment, &self.custody, offset, maximum).await
	}
}
async fn read(environment: &Environment, custody: &Custody, offset: u64, maximum: usize) -> Result<Vec<u8>> {
	let file = custody
		.borrow()
		.as_ref()
		.cloned()
		.ok_or("File custody has been released")?;
	let length = rooms_application::files::transfer::read_length(
		file.description["size"]
			.as_u64()
			.and_then(|size| usize::try_from(size).ok())
			.ok_or("Invalid file size")?,
		offset,
		maximum,
	)
	.map_err(|e| e.to_string())?;
	if file.reader.get().is_none() {
		let selection = file.selection.as_ref().ok_or("File has no source")?;
		let reader = selection
			.workspace
			.activity_file(&selection.token, selection.index)
			.await
			.map_err(|e| e.to_string())?;
		// Concurrent opens may acquire the same exact occurrence. The first
		// reader keeps it; a later redundant facade drops without replacing it.
		let _ = file.reader.set(reader);
	}
	if custody.borrow().is_none() {
		return Err("File custody was released during its acquisition".into());
	}
	let reply = environment
		.platform
		.within(
			rooms_application::room::authority::REQUEST_TIMEOUT_MS,
			std::future::IntoFuture::into_future(environment.runtime.host().send(
				file.reader.get().expect("acquired file reader"),
				rooms_application::protocol_data::READ,
				&[Argument::Integer(offset as i64), Argument::Integer(maximum as i64)],
			)),
		)
		.await
		.ok_or("File read did not answer")?
		.map_err(|e| e.to_string())?;
	if custody.borrow().is_none() {
		return Err("File custody was released during its read".into());
	}
	match reply {
		Argument::Bytes(bytes) if bytes.len() <= length => Ok(bytes),
		_ => Err("File returned an invalid chunk".into()),
	}
}
#[wasm_bindgen]
impl RoomsManagedFile {
	pub fn open(&self, progress: Option<js_sys::Function>, signal: Option<web_sys::AbortSignal>) -> js_sys::Promise {
		let mut abort = match Abort::new(signal) {
			Ok(abort) => abort,
			Err(error) => return rejected(error),
		};
		let custody = self.file.clone();
		self.driver
			.submit(rooms_application::files::CHUNK_BYTES, move |environment| async move {
				let file = custody
					.borrow()
					.as_ref()
					.cloned()
					.ok_or("File custody has been released")?;
				let size = file.description["size"]
					.as_u64()
					.and_then(|size| usize::try_from(size).ok())
					.ok_or("Invalid file size")?;
				let mime = file.description["mime"].as_str().ok_or("Invalid file MIME type")?;
				let reader = Reader {
					custody,
					environment: environment.clone(),
				};
				tokio::select! { biased;
					() = abort.cancelled() => Err("Rooms file view was cancelled".into()),
					result = file_display::materialize(&environment, reader, size, mime, progress) => result,
				}
			})
	}
	pub fn description(&self) -> std::result::Result<JsValue, JsValue> {
		self.driver.with_local(|| {
			self.driver
				.require_open()
				.and_then(|()| {
					let file = self
						.file
						.borrow()
						.as_ref()
						.cloned()
						.ok_or("File custody has been released")?;
					json(&file.description.to_string())
				})
				.map_err(|error| js_error(&error))
		})
	}
	pub fn release(&self) {
		self.driver.with_local(|| self.retire());
	}
	pub fn read(&self, offset: js_sys::JsString, maximum: u32) -> js_sys::Promise {
		let offset = match scalar(offset, 20).and_then(|text| revision(&text)) {
			Ok(offset) => offset,
			Err(error) => return rejected(error),
		};
		if rooms_application::fields::SafeInteger::<false>::new(offset).is_none() {
			return rejected("File offset exceeds its exact integer range".into());
		}
		if maximum == 0 || maximum as usize > rooms_application::files::CHUNK_BYTES {
			return rejected("File reads require a bounded nonzero chunk".into());
		}
		let custody = self.file.clone();
		self.driver.submit(maximum as usize, move |environment| async move {
			let bytes = read(&environment, &custody, offset, maximum as usize).await?;
			Ok(js_sys::Uint8Array::from(bytes.as_slice()).into())
		})
	}
}
