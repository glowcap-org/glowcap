//! Device deletion retains its bounded plan and exact blocked browser request.
//! Session databases go first, so a refused deletion keeps bootstrap metadata.
use super::{
	Error,
	erase::{Deletion, Effects},
};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use wasm_bindgen::{JsCast, prelude::*};
use wasm_bindgen_futures::JsFuture;

#[wasm_bindgen]
pub struct RoomsBrowserData {
	plan: Rc<Plan>,
}
struct Plan {
	names: RefCell<Option<Vec<String>>>,
	at: Cell<usize>,
	pending: RefCell<Option<Rc<Deletion>>>,
	serial: tokio::sync::Mutex<()>,
}
impl Plan {
	async fn erase(&self) -> Result<(), Error> {
		let _serial = self.serial.lock().await;
		if self.names.borrow().is_none() {
			let factory = js_sys::Reflect::get(&js_sys::global(), &"indexedDB".into())?;
			let enumerate = js_sys::Reflect::get(&factory, &"databases".into())?
				.dyn_into::<js_sys::Function>()
				.map_err(|_| Error::Unavailable)?;
			let promise = enumerate
				.call0(&factory)?
				.dyn_into::<js_sys::Promise>()
				.map_err(|_| Error::Unavailable)?;
			let names = js_sys::Array::from(&JsFuture::from(promise).await?);
			let mut selected = Vec::new();
			for row in names.iter() {
				let Some(name) = js_sys::Reflect::get(&row, &"name".into())?.as_string() else {
					continue;
				};
				if name.strip_prefix("rooms-session-").is_some_and(|tab| {
					!tab.is_empty()
						&& tab.len() <= 64 && tab.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
				}) {
					if selected.len() >= 512 {
						return Err(Error::Platform(
							"Rooms database inventory exceeds its deletion budget".into(),
						));
					}
					selected.push(name);
				}
			}
			selected.sort();
			selected.push("rooms-history".into());
			*self.names.borrow_mut() = Some(selected);
		}
		loop {
			let name = self
				.names
				.borrow()
				.as_ref()
				.and_then(|names| names.get(self.at.get()))
				.cloned();
			let Some(name) = name else {
				return Ok(());
			};
			let prior = self.pending.borrow().clone();
			let request = match prior {
				Some(prior) => prior,
				None => {
					let request = Deletion::start_named(Effects::default(), &name)?;
					*self.pending.borrow_mut() = Some(request.clone());
					request
				}
			};
			request.wait().await?;
			self.pending.borrow_mut().take();
			self.at.set(self.at.get() + 1);
		}
	}
}
#[wasm_bindgen]
impl RoomsBrowserData {
	#[wasm_bindgen(constructor)]
	pub fn new() -> Self {
		Self {
			plan: Rc::new(Plan {
				names: RefCell::default(),
				at: Cell::new(0),
				pending: RefCell::default(),
				serial: tokio::sync::Mutex::new(()),
			}),
		}
	}
	pub fn erase(&self) -> js_sys::Promise {
		let plan = self.plan.clone();
		wasm_bindgen_futures::future_to_promise(async move {
			plan.erase()
				.await
				.map(|()| JsValue::UNDEFINED)
				.map_err(|e| js_sys::Error::new(&e.to_string()).into())
		})
	}
}
impl Default for RoomsBrowserData {
	fn default() -> Self {
		Self::new()
	}
}
