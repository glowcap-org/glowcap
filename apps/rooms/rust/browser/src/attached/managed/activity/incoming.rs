//! Handed authority stays opaque. A retained candidate saves its actual target
//! and initiating endpoint through one ordinary workspace acquisition.
use super::*;
use std::{cell::RefCell, rc::Rc};

struct Incoming {
	source: Workspace<Platform>,
	role: custody::Role,
	token: String,
}
type Custody = Rc<RefCell<Option<Incoming>>>;
#[wasm_bindgen]
pub struct RoomsManagedIncoming {
	driver: Driver,
	incoming: Held<Custody>,
}
impl RoomsManagedIncoming {
	/// The shared Driver admits the fixed occurrence/source guards and shells.
	/// It retains no bearer recipe or second authority inventory.
	pub(super) fn hold(
		driver: &Driver,
		source: Workspace<Platform>,
		role: custody::Role,
		token: String,
	) -> Result<Self> {
		let bytes =
			token.capacity() + size_of::<Incoming>() + size_of::<RefCell<Option<Incoming>>>() + 2 * size_of::<usize>();
		let incoming = driver.hold(Rc::new(RefCell::new(Some(Incoming { source, role, token }))), bytes)?;
		Ok(Self {
			driver: driver.clone(),
			incoming,
		})
	}
}
#[wasm_bindgen]
impl RoomsManagedIncoming {
	pub fn release(&self) {
		self.driver.with_local(|| {
			self.incoming.borrow_mut().take();
		});
	}
	/// The candidate uses the received authority's declared role. An optional
	/// source coordinate saves the same initiating endpoint beside it. No owner
	/// root or replacement source can enter this request.
	#[wasm_bindgen(js_name = prepareAcquisition)]
	pub fn prepare_acquisition(
		&self,
		expected: js_sys::JsString,
		destination: js_sys::JsString,
		releases: js_sys::JsString,
		intent: js_sys::JsString,
		source: Option<js_sys::JsString>,
	) -> js_sys::Promise {
		let input = (|| {
			let candidate = super::super::acquisition::candidate(expected, releases, intent)?;
			let destination = custody::Coordinate::decode(&scalar(destination, 256)?)
				.map_err(|_| "Invalid incoming custody coordinate")?;
			let source = source
				.map(|raw| -> Result<custody::Coordinate> {
					let source = custody::Coordinate::decode(&scalar(raw, 256)?)
						.map_err(|_| "Invalid incoming source coordinate")?;
					if source.role != custody::Role::SessionAccess {
						return Err("Incoming source must select session access".into());
					}
					Ok(source)
				})
				.transpose()?;
			Ok((candidate, destination, source))
		})();
		let ((expected, releases, intent), destination, source) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let incoming = self.incoming.clone();
		let driver = self.driver.clone();
		self.driver
			.submit(custody::MAX_AUTHORITY_BYTES + 16384, move |_| async move {
				let incoming = incoming
					.borrow()
					.as_ref()
					.map(|incoming| (incoming.source.clone(), incoming.role, incoming.token.clone()))
					.ok_or("Incoming capability custody has been released")?;
				if destination.role != incoming.1 {
					return Err("Incoming capability cannot change its admitted role".into());
				}
				let acquisition = incoming
					.0
					.prepare_activity_acquisition(&incoming.2, destination, source, expected, &releases, &intent)
					.await
					.map_err(|e| e.to_string())?;
				let bytes = acquisition.retained_bytes();
				let acquisition = driver.hold(acquisition, bytes)?;
				Ok(RoomsManagedAcquisition { driver, acquisition }.into())
			})
	}
}
