//! One production ingress for a public directory locator or an exact access URI.
use super::*;
use rooms_application::{directory, fields::Text};
use rooms_glowcap::client::{
	Deadline,
	workspace::{DirectoryAcquisition, DirectoryImport},
};

#[wasm_bindgen]
pub struct RoomsManagedDirectoryAcquisition {
	driver: Driver,
	acquisition: Held<DirectoryAcquisition<Platform>>,
}
#[wasm_bindgen]
impl RoomsManagedDirectoryAcquisition {
	pub fn submit(&self) -> js_sys::Promise {
		let acquisition = self.acquisition.clone();
		self.driver.submit(
			0,
			move |_| async move { outcome::acquisition(acquisition.submit().await) },
		)
	}
	/// A replacement is charged while the rejected candidate remains held.
	pub fn reprepare(&self) -> js_sys::Promise {
		let acquisition = self.acquisition.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |_| async move {
			let acquisition = acquisition.reprepare().await.map_err(|error| error.to_string())?;
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedDirectoryAcquisition { driver, acquisition }.into())
		})
	}
}

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	/// Preparation fetches once and retains the complete candidate. Submission
	/// compares the saved revision. It never overwrites an intervening workspace.
	#[wasm_bindgen(js_name = prepareDirectory)]
	pub fn prepare_directory(
		&self,
		id: js_sys::JsString,
		route: js_sys::JsString,
		nick: js_sys::JsString,
		home: bool,
		exact: bool,
	) -> js_sys::Promise {
		let input = (|| {
			let id = scalar(id, 1024)?;
			let nick = scalar(nick, 32)?;
			if !nick.is_empty() && !rooms_application::room::inbox::valid_nick(&nick) {
				return Err("Invalid directory nickname".into());
			}
			let route = scalar(route, glowcap::loam::ReferenceRequest::MAX_URI_BYTES)?;
			let uri = rooms_glowcap::routes::directory_recipe(&route).map_err(|error| error.to_string())?;
			if uri.len() > glowcap::loam::ReferenceRequest::MAX_URI_BYTES {
				return Err("Directory capability recipe is too large".into());
			}
			let bytes = id.len() + nick.len() + uri.len();
			Ok((
				Text::new(id.into()).ok_or("Invalid directory row identity")?,
				Text::new(nick.into()).ok_or("Invalid nickname")?,
				uri,
				bytes,
			))
		})();
		let (id, nick, uri, bytes) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(bytes, move |environment| async move {
			let reference = environment
				.platform
				.within(
					rooms_application::room::authority::REQUEST_TIMEOUT_MS,
					environment.runtime.host().enliven(&uri),
				)
				.await
				.ok_or("Directory acquisition did not answer")?
				.map_err(|error| error.to_string())?;
			// Fetching holds no workspace candidate. Session activity may commit
			// while it waits; select intent only after the capability is held.
			let snapshot = workspace.snapshot().await.map_err(|error| error.to_string())?;
			if snapshot.intent.directories.as_slice().iter().any(|row| row.id == id) {
				return Err("Directory row already exists; recover its original request".into());
			}
			if snapshot.intent.directories.as_slice().len() == workspace::MAX_DIRECTORIES {
				return Err("Directory capacity is exhausted".into());
			}
			let mut platform = environment.platform.clone();
			let row = workspace::Directory {
				id,
				access: key(&mut platform)?,
				source: Some(key(&mut platform)?),
				name: None,
				inbox: None,
				home,
				nick,
				assigned_nick: None,
				nick_allocation: if exact {
					directory::registration::NicknameAllocation::Exact
				} else {
					directory::registration::NicknameAllocation::Automatic
				},
				standing: None,
			};
			let acquisition = workspace
				.prepare_directory(
					snapshot.revision,
					DirectoryImport {
						row,
						reference,
						uri: Some(uri),
					},
					&snapshot.intent,
				)
				.map_err(|error| error.to_string())?;
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedDirectoryAcquisition { driver, acquisition }.into())
		})
	}
}
