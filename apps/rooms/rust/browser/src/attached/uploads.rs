//! Browser readers supply bounded byte spans. Rust owns source custody and
//! the file-transfer protocol on the application's one source pool.
use super::{Result, RoomsBrowserSession, actions::text, js_error, rejected, safe_integer};
use rooms_application::files::FileDescription;
use rooms_glowcap::client::session::controller::Observation;
use rooms_glowcap::client::{
	session::{FileMessage, Refile},
	sources::{Reader, Source},
};
use std::{future::Future, pin::Pin};
use wasm_bindgen::prelude::*;

struct BrowserReader(js_sys::Function);
impl Reader for BrowserReader {
	fn read(&self, offset: usize, length: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>>>>> {
		let read = self.0.clone();
		Box::pin(async move {
			let pending = read
				.call2(&JsValue::UNDEFINED, &(offset as f64).into(), &(length as f64).into())
				.map_err(|_| "Rooms source reader failed")?;
			let value = wasm_bindgen_futures::JsFuture::from(js_sys::Promise::resolve(&pending))
				.await
				.map_err(|_| "Rooms source read failed")?;
			let bytes = value
				.dyn_into::<js_sys::Uint8Array>()
				.map_err(|_| "Rooms source did not return bytes")?;
			if bytes.length() as usize != length {
				return Err("Rooms source returned an invalid span".into());
			}
			Ok(bytes.to_vec())
		})
	}
}
#[wasm_bindgen]
pub struct RoomsBrowserSource {
	source: Source,
}
#[wasm_bindgen]
impl RoomsBrowserSource {
	#[wasm_bindgen(constructor)]
	pub fn new(
		name: js_sys::JsString,
		mime: js_sys::JsString,
		size: f64,
		width: u32,
		height: u32,
		read: js_sys::Function,
	) -> std::result::Result<RoomsBrowserSource, JsValue> {
		let input = (|| {
			let description = FileDescription::new(
				text(name)?,
				text(mime)?,
				safe_integer(size)?,
				width.into(),
				height.into(),
			)
			.map_err(|e| e.to_string())?;
			Ok(Self {
				source: Source::reader(description, BrowserReader(read)),
			})
		})();
		input.map_err(|error: String| js_error(&error))
	}
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = sendFiles)]
	pub fn send_files(
		&self,
		operation: Option<js_sys::JsString>,
		base: Option<f64>,
		conversation: js_sys::JsString,
		caption: js_sys::JsString,
		preview_urls: js_sys::JsString,
		files: Vec<RoomsBrowserSource>,
	) -> js_sys::Promise {
		let caption_text = caption.as_string().unwrap_or_default();
		let previews = match rooms_application::open_graph::Selection::decode(
			&caption_text,
			&preview_urls.as_string().unwrap_or_default(),
		) {
			Ok(previews) => previews,
			Err(error) => return rejected(error.to_string()),
		};
		self.upload(operation, base, conversation, caption, previews, files, None)
	}
	#[wasm_bindgen(js_name = refileLine)]
	#[allow(clippy::too_many_arguments)]
	pub fn refile_line(
		&self,
		operation: Option<js_sys::JsString>,
		base: Option<f64>,
		conversation: js_sys::JsString,
		line: f64,
		caption: js_sys::JsString,
		keep: Vec<u32>,
		files: Vec<RoomsBrowserSource>,
	) -> js_sys::Promise {
		let line = match safe_integer(line) {
			Ok(line) => line,
			Err(error) => return rejected(error),
		};
		self.upload(
			operation,
			base,
			conversation,
			caption,
			Default::default(),
			files,
			Some((line, keep)),
		)
	}
}
impl RoomsBrowserSession {
	fn upload(
		&self,
		operation: Option<js_sys::JsString>,
		base: Option<f64>,
		conversation: js_sys::JsString,
		caption: js_sys::JsString,
		previews: rooms_application::open_graph::Selection,
		files: Vec<RoomsBrowserSource>,
		refile: Option<(u64, Vec<u32>)>,
	) -> js_sys::Promise {
		let input = (|| {
			self.scope.open()?;
			if files.len() > rooms_application::room::line::MAX_MESSAGE_FILES {
				return Err("Too many Rooms file sources".into());
			}
			let sources: Vec<_> = files.into_iter().map(|file| file.source).collect();
			let (operation, base, conversation, caption) = (
				operation
					.map(text)
					.transpose()?
					.map_or_else(|| self.owner.operation_id(), Ok)?,
				base.map(safe_integer).transpose()?,
				text(conversation)?,
				text(caption)?,
			);
			let bytes = operation.len()
				+ conversation.len()
				+ caption.len()
				+ previews.retained_bytes()
				+ sources
					.iter()
					.map(|source| source.description().retained_bytes())
					.sum::<usize>()
				+ refile.as_ref().map_or(0, |(_, keep)| keep.len() * 4);
			Ok((operation, base, conversation, caption, previews, sources, bytes))
		})();
		let (operation, base, conversation, caption, previews, sources, bytes) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let session = match self.owner.session() {
			Ok(session) => session,
			Err(error) => return rejected(error),
		};
		let scope = self.scope.clone();
		let generation = scope.generation();
		let owner = self.owner.clone();
		self.driver.submit(bytes, move |environment| async move {
			let _serial = owner.lock().await?;
			scope.current(generation)?;
			owner
				.external(&operation, async {
					let message = FileMessage {
						operation: &operation,
						base: base.map_or_else(|| owner.current().map(|snapshot| snapshot.revision.get()), Ok)?,
						conversation: &conversation,
						caption: &caption,
						previews,
					};
					let revision = match refile {
						Some((line, keep)) => {
							session
								.refile(
									&environment.sources,
									Refile {
										message,
										line,
										keep: &keep,
									},
									sources,
								)
								.await
						}
						None => session.send_files(&environment.sources, message, sources).await,
					}
					.map_err(|e| e.to_string())?;
					scope.current(generation)?;
					if base.is_none() {
						let snapshot = owner.settle(revision).await?;
						super::view::snapshot(&snapshot)
					} else {
						Ok((revision as f64).into())
					}
				})
				.await
		})
	}
}
