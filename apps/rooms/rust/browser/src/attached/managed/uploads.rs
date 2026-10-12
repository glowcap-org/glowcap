//! Local and attached managed uploads use the existing bounded source pool.
//! JavaScript supplies random-access spans. The retained command owns leases.
use super::super::uploads::RoomsBrowserSource;
use super::*;
use rooms_application::{
	content::session::uploads::{Description, Intent, Kind},
	fields::List,
};
#[wasm_bindgen]
impl RoomsManagedWorkspace {
	#[wasm_bindgen(js_name = prepareUpload)]
	#[allow(clippy::too_many_arguments)]
	pub fn prepare_upload(
		&self,
		operation: js_sys::JsString,
		base: js_sys::JsString,
		conversation: js_sys::JsString,
		caption: js_sys::JsString,
		previews: js_sys::JsString,
		files: Vec<RoomsBrowserSource>,
		line: Option<js_sys::JsString>,
		keep: Vec<u32>,
	) -> js_sys::Promise {
		let input = (|| {
			if files.len() + keep.len() > rooms_application::room::line::MAX_MESSAGE_FILES {
				return Err("Too many upload files".into());
			}
			let operation = scalar(operation, 1024)?;
			let base = revision(&scalar(base, 20)?)?;
			let conversation = scalar(conversation, 1024)?;
			let caption = scalar(caption, rooms_application::room::line::MAX_LINE_BYTES)?;
			let previews = scalar(previews, 16384)?;
			let upload = line
				.map(|line| revision(&scalar(line, 20)?).map(Kind::Refile))
				.transpose()?
				.unwrap_or(Kind::Post);
			let sources: Vec<_> = files.into_iter().map(|file| file.source).collect();
			let descriptions = sources
				.iter()
				.map(|source| Description::from_file(source.description()))
				.collect();
			let intent = Intent {
				operation,
				base,
				conversation,
				caption,
				previews,
				upload,
				keep: List::new(keep).ok_or("Too many kept files")?,
				files: List::new(descriptions).ok_or("Too many source files")?,
			};
			let bytes = intent.canonical().map_err(|e| e.to_string())?.len();
			Ok((intent, sources, bytes))
		})();
		let (intent, sources, bytes) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let workspace = self.workspace.clone();
		let driver = self.driver.clone();
		self.driver.submit(bytes, move |environment| async move {
			let command = workspace
				.prepare_upload(&intent, &environment.sources, sources)
				.await
				.map_err(|e| e.to_string())?;
			let bytes = command.retained_bytes();
			let command = driver.hold(command, bytes)?;
			Ok(RoomsManagedCommand { driver, command }.into())
		})
	}
}
