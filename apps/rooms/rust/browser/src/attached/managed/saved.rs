//! Save and release actual held use and control independently. One
//! acquisition commits the exact occurrences and row together. Missing
//! custody stays absent.
use super::*;

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	/// Replace the selected view atomically, retaining independently held control.
	#[wasm_bindgen(js_name = prepareSelectWorkspace)]
	pub fn prepare_select_workspace(&self, id: js_sys::JsString, access: &RoomsManagedWorkspace) -> js_sys::Promise {
		self.prepare_saved(
			id,
			Some((access.workspace.reference().clone(), access.home.clone())),
			None,
			true,
		)
	}
	#[wasm_bindgen(js_name = prepareSaveAccess)]
	pub fn prepare_save_access(
		&self,
		id: js_sys::JsString,
		access: &RoomsManagedWorkspace,
		control: &RoomsManagedControl,
	) -> js_sys::Promise {
		self.prepare_saved(
			id,
			Some((access.workspace.reference().clone(), access.home.clone())),
			Some((control.reference().clone(), control.home.clone())),
			false,
		)
	}
	#[wasm_bindgen(js_name = prepareSaveWorkspace)]
	pub fn prepare_save_workspace(&self, id: js_sys::JsString, access: &RoomsManagedWorkspace) -> js_sys::Promise {
		self.prepare_saved(
			id,
			Some((access.workspace.reference().clone(), access.home.clone())),
			None,
			false,
		)
	}
	/// Release one row's saved management control. A row that also holds use
	/// keeps it. A row left holding nothing leaves the intent. Answers `null`
	/// when the row holds no control, so a retry after a committed release
	/// that lost its reply finds nothing left to do.
	#[wasm_bindgen(js_name = prepareForgetControl)]
	pub fn prepare_forget_control(&self, id: js_sys::JsString) -> js_sys::Promise {
		let id = match scalar(id, 1024) {
			Ok(id) => id,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(id.len(), move |_| async move {
			let mut snapshot = workspace.snapshot().await.map_err(|e| e.to_string())?;
			let rows = &mut snapshot.intent.accesses;
			let Some(index) = rows
				.as_slice()
				.iter()
				.position(|row| row.id.text().as_str() == Some(&id))
			else {
				return Ok(JsValue::NULL);
			};
			let Some(control) = rows.as_slice()[index].control else {
				return Ok(JsValue::NULL);
			};
			if rows.as_slice()[index].access.is_some() {
				rows.as_mut_slice()[index].control = None;
			} else {
				rows.remove(index);
			}
			let releases = [coordinate(custody::Role::SessionControl, control)];
			let acquisition = workspace
				.prepare_acquisition(snapshot.revision, Vec::new(), &releases, &snapshot.intent)
				.map_err(|e| e.to_string())?;
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedAcquisition { driver, acquisition }.into())
		})
	}
	#[wasm_bindgen(js_name = prepareSaveControl)]
	pub fn prepare_save_control(&self, id: js_sys::JsString, control: &RoomsManagedControl) -> js_sys::Promise {
		self.prepare_saved(
			id,
			None,
			Some((control.reference().clone(), control.home.clone())),
			false,
		)
	}
}
impl RoomsManagedWorkspace {
	fn prepare_saved(
		&self,
		id: js_sys::JsString,
		access: Option<(Ref, PublicationHome)>,
		control: Option<(Ref, PublicationHome)>,
		replace_view: bool,
	) -> js_sys::Promise {
		let id = match scalar(id, 1024) {
			Ok(id) => id,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(id.len(), move |environment| async move {
			let access = match access {
				Some((reference, home)) => {
					let uri = home.recipe(&environment, &reference).await?;
					Some((reference, uri))
				}
				None => None,
			};
			let control = match control {
				Some((reference, home)) => {
					let uri = home.recipe(&environment, &reference).await?;
					Some((reference, uri))
				}
				None => None,
			};
			let mut snapshot = workspace.snapshot().await.map_err(|e| e.to_string())?;
			let existing = snapshot
				.intent
				.accesses
				.as_slice()
				.iter()
				.position(|row| row.id.text().as_str() == Some(&id));
			if existing.is_some() && !replace_view {
				return Err("Access row already exists; recover its original request".into());
			}
			let mut releases = Vec::new();
			if let Some(index) = existing
				&& let Some(access) = snapshot.intent.accesses.as_slice()[index].access
			{
				releases.push(coordinate(custody::Role::SessionAccess, access));
			}
			let mut platform = environment.platform.clone();
			let access = access
				.map(|(reference, uri)| key(&mut platform).map(|key| (key, reference, uri)))
				.transpose()?;
			let control = control
				.map(|(reference, uri)| key(&mut platform).map(|key| (key, reference, uri)))
				.transpose()?;
			if let Some(index) = existing {
				snapshot.intent.accesses.as_mut_slice()[index].access = access.as_ref().map(|(key, _, _)| *key);
			} else {
				snapshot
					.intent
					.accesses
					.try_push(workspace::Access {
						id: rooms_application::fields::Text::new(id.into()).ok_or("Invalid row identity")?,
						access: access.as_ref().map(|(key, _, _)| *key),
						control: control.as_ref().map(|(key, _, _)| *key),
					})
					.map_err(|_| "Saved access capacity is exhausted")?;
			}
			// Each selected occurrence is held once through the same bounded
			// candidate. Foreign recipes use the established home and the exact
			// publication supplied by that held capability's original owner.
			let mut imports = Vec::with_capacity(usize::from(access.is_some()) + usize::from(control.is_some()));
			if let Some((key, reference, uri)) = access {
				imports.push(Import {
					coordinate: coordinate(custody::Role::SessionAccess, key),
					reference,
					uri,
				});
			}
			if let Some((key, reference, uri)) = control {
				imports.push(Import {
					coordinate: coordinate(custody::Role::SessionControl, key),
					reference,
					uri,
				});
			}
			let acquisition = workspace
				.prepare_acquisition(snapshot.revision, imports, &releases, &snapshot.intent)
				.map_err(|e| e.to_string())?;
			let bytes = acquisition.retained_bytes();
			let acquisition = driver.hold(acquisition, bytes)?;
			Ok(RoomsManagedAcquisition { driver, acquisition }.into())
		})
	}
}
