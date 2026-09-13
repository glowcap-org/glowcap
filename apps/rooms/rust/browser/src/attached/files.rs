//! Each exported file object holds one typed grant. Release fences reads and
//! relinquishes custody; no numeric lookup can manufacture a file capability.
mod access;
mod display;
use super::{
	Result,
	driver::{Driver, Retained},
	observation::Scope,
	rejected, safe_integer,
};
use crate::platform::Platform;
pub(crate) use access::Access;
use rooms_application::files::CHUNK_BYTES;
use std::{
	cell::RefCell,
	rc::{Rc, Weak},
};
use wasm_bindgen::prelude::*;

struct Payload {
	file: Access,
	_retained: Retained,
}
pub(super) struct Held {
	payload: RefCell<Option<Rc<Payload>>>,
	stopped: tokio::sync::watch::Sender<bool>,
}
impl Held {
	pub fn release(&self) {
		self.stopped.send_replace(true);
		self.payload.borrow_mut().take();
	}
	pub fn live(&self) -> bool {
		self.payload.borrow().is_some()
	}
}

#[wasm_bindgen]
pub struct RoomsBrowserFile {
	held: Rc<Held>,
	scope: Weak<Scope>,
	driver: Driver,
	name: String,
	mime: String,
	size: usize,
	width: u32,
	height: u32,
}
pub(super) fn hold(driver: &Driver, scope: &Rc<Scope>, file: impl Into<Access>) -> Result<RoomsBrowserFile> {
	let file = file.into();
	let description = file.description()?;
	// The wrapper retains display metadata separately from the grant so a
	// released object can still explain what it displayed.
	let retained = driver.retain_file(description.retained_bytes().saturating_mul(2))?;
	let (width, height) = description.dimensions();
	let (stopped, _) = tokio::sync::watch::channel(false);
	let result = RoomsBrowserFile {
		name: description.name().into(),
		mime: description.mime().into(),
		size: description.size(),
		width,
		height,
		held: Rc::new(Held {
			payload: RefCell::new(Some(Rc::new(Payload {
				file,
				_retained: retained,
			}))),
			stopped,
		}),
		scope: Rc::downgrade(scope),
		driver: driver.clone(),
	};
	scope.keep(&result.held)?;
	Ok(result)
}
impl RoomsBrowserFile {
	pub(super) fn held(&self) -> Rc<Held> {
		self.held.clone()
	}
}
#[wasm_bindgen]
impl RoomsBrowserFile {
	#[wasm_bindgen(getter)]
	pub fn name(&self) -> String {
		self.name.clone()
	}
	#[wasm_bindgen(getter)]
	pub fn mime(&self) -> String {
		self.mime.clone()
	}
	#[wasm_bindgen(getter)]
	pub fn size(&self) -> f64 {
		self.size as f64
	}
	#[wasm_bindgen(getter)]
	pub fn width(&self) -> u32 {
		self.width
	}
	#[wasm_bindgen(getter)]
	pub fn height(&self) -> u32 {
		self.height
	}

	pub fn read(&self, offset: f64, maximum: u32) -> js_sys::Promise {
		let admitted = (|| {
			let offset = safe_integer(offset)?;
			if maximum == 0 || maximum as usize > CHUNK_BYTES {
				return Err("Rooms file reads require a bounded nonzero chunk".into());
			}
			Ok((offset, self.reader()?))
		})();
		let (offset, mut reader) = match admitted {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		self.driver.submit(maximum as usize, move |_| async move {
			let bytes = reader.read(offset, maximum as usize).await?;
			Ok(js_sys::Uint8Array::from(bytes.as_slice()).into())
		})
	}

	pub fn release(&self) {
		self.driver.with_local(|| self.held.release());
	}
}
impl Drop for RoomsBrowserFile {
	fn drop(&mut self) {
		self.driver.with_local(|| self.held.release());
	}
}

struct Reader {
	payload: Rc<Payload>,
	scope: Weak<Scope>,
	held: Rc<Held>,
	stopped: tokio::sync::watch::Receiver<bool>,
}
impl RoomsBrowserFile {
	fn reader(&self) -> Result<Reader> {
		self.driver.require_open()?;
		self.scope.upgrade().ok_or("Rooms attachment retired")?.open()?;
		let payload = self.held.payload.borrow().clone().ok_or("Rooms file was released")?;
		Ok(Reader {
			payload,
			scope: self.scope.clone(),
			held: self.held.clone(),
			stopped: self.held.stopped.subscribe(),
		})
	}
}
impl Reader {
	async fn read(&mut self, offset: u64, maximum: usize) -> Result<Vec<u8>> {
		if *self.stopped.borrow() {
			return Err("Rooms file was released".into());
		}
		let bytes = tokio::select! { biased;
			_ = self.stopped.changed() => return Err("Rooms file read was cancelled".into()),
			result = self.payload.file.read(offset, maximum) => result.map_err(|e| e.to_string())?,
		};
		self.scope.upgrade().ok_or("Rooms attachment retired")?.open()?;
		if !self.held.live() {
			return Err("Rooms file was released".into());
		}
		Ok(bytes)
	}
}
