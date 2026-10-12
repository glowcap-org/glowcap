//! Directory metadata stays descriptive. Held readers own exact admission.
use super::*;
use rooms_glowcap::client::workspace::DirectoryReader;

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = resynchronizeDiscovery)]
	pub fn resynchronize_discovery(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		self.driver.submit(0, move |_| async move {
			workspace
				.resynchronize_discovery()
				.await
				.map_err(|error| error.to_string())?;
			Ok(JsValue::UNDEFINED)
		})
	}
	#[wasm_bindgen(js_name = preparePublicRoom)]
	pub fn prepare_public_room(&self, expected: js_sys::JsString, selection: js_sys::JsString) -> js_sys::Promise {
		let input = (|| {
			let expected = revision(&scalar(expected, 20)?)?;
			let selection = scalar(selection, 8192)?;
			let bytes = selection.len();
			let selection: rooms_glowcap::client::workspace::PublicRoomImport =
				serde_json::from_str(&selection).map_err(|_| "Invalid public room selection")?;
			Ok((expected, selection, bytes))
		})();
		let (expected, selection, bytes) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(bytes, move |_| async move {
			let acquisition = match workspace.prepare_public_room(expected, selection).await {
				Ok(acquisition) => acquisition,
				Err(rooms_glowcap::client::Error::WorkspaceConflict) => return Ok(JsValue::NULL),
				Err(error) => return Err(error.to_string()),
			};
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedAcquisition { driver, acquisition }.into())
		})
	}
	#[wasm_bindgen(js_name = directoryReader)]
	pub fn directory_reader(&self, id: js_sys::JsString) -> js_sys::Promise {
		let id = match scalar(id, 1024) {
			Ok(id) => id,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(id.len(), move |_| async move {
			let reader = workspace
				.directory_reader(&id)
				.await
				.map_err(|error| error.to_string())?;
			let reader = driver.hold(reader, size_of::<DirectoryReader<Platform>>())?;
			Ok(RoomsManagedDirectoryReader { driver, reader }.into())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsManagedDirectoryReader {
	driver: Driver,
	reader: Held<DirectoryReader<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedDirectoryReader {
	#[wasm_bindgen(js_name = namedRooms)]
	pub fn named_rooms(&self, name: js_sys::JsString) -> js_sys::Promise {
		let name = match scalar(name, 32) {
			Ok(name) => name,
			Err(error) => return rejected(error),
		};
		let reader = self.reader.clone();
		self.driver.submit(name.len(), move |_| async move {
			let rooms = reader.named_rooms(&name).await.map_err(|error| error.to_string())?;
			json(&serde_json::to_string(&rooms).map_err(|_| "Invalid directory projection")?)
		})
	}
	pub fn list(&self) -> js_sys::Promise {
		let reader = self.reader.clone();
		self.driver.submit(0, move |_| async move {
			let rooms = reader.list().await.map_err(|error| error.to_string())?;
			json(&serde_json::to_string(&rooms).map_err(|_| "Invalid directory projection")?)
		})
	}
	#[wasm_bindgen(js_name = advertisedLocation)]
	pub fn advertised_location(&self) -> js_sys::Promise {
		let reader = self.reader.clone();
		self.driver.submit(0, move |_| async move {
			reader
				.advertised_location()
				.await
				.map(Into::into)
				.map_err(|error| error.to_string())
		})
	}
	#[wasm_bindgen(js_name = memberRegistration)]
	pub fn member_registration(&self, peer: js_sys::JsString) -> js_sys::Promise {
		let peer = match scalar(peer, 32) {
			Ok(peer) => peer,
			Err(error) => return rejected(error),
		};
		let reader = self.reader.clone();
		self.driver.submit(peer.len(), move |_| async move {
			reader
				.member_registration(&peer)
				.await
				.map(|id| id.as_str().into())
				.map_err(|error| error.to_string())
		})
	}
}
