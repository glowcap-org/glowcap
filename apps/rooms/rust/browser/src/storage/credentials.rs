//! Private credential bytes share IndexedDB's transaction owner and tab lease.
//! A cancelled observer leaves the admitted operation here until readback.
use super::{Database, Error, Operation, value};
use rooms_application::documents::{SessionDocument, WriteFailure};
use rooms_runtime::documents::{Completion, Document};
use wasm_bindgen::JsCast;
use web_sys::IdbTransactionMode;

const META: &str = "archive-meta";
enum Pending {
	Read(Operation<Option<Vec<u8>>>),
	Write(Operation<()>),
}

/// Constructed only by the tab bootstrap whose Store owns the exclusive Web
/// Lock. The opaque owner identity keeps credentials separate even if an
/// embedding reuses a tab label after an explicit reset.
pub struct Credentials {
	database: Database,
	key: String,
	pending: Option<Pending>,
}
impl Credentials {
	/// Bind the journal to the private Loam owner identity. The embedding must
	/// hold that owner's exclusive Store lease through document retirement.
	/// Construction does not acquire a second lock or confer session authority.
	pub fn new(database: Database, owner: &[u8; 16]) -> Self {
		Self {
			database,
			key: format!("session-credentials:{}", rooms_application::fields::lower_hex(owner)),
			pending: None,
		}
	}
	fn idle(&self) -> Result<(), Error> {
		if self.pending.is_some() {
			Err(Error::Invalid("bridge credential observation is still pending"))
		} else {
			Ok(())
		}
	}
}
impl Document for Credentials {
	type Error = Error;
	fn document(&self) -> SessionDocument {
		SessionDocument::BridgeSecrets
	}
	fn has_pending(&self) -> bool {
		self.pending.is_some()
	}
	async fn read(&mut self) -> Result<Option<Vec<u8>>, Error> {
		self.idle()?;
		let key = self.key.clone();
		self.pending = Some(Pending::Read(Operation::start(
			&self.database,
			&[META],
			IdbTransactionMode::Readonly,
			None,
			move |steps| {
				steps.request(steps.store(META)?.get(&key.as_str().into())?, move |steps, row| {
					if row.is_undefined() {
						return Ok(());
					}
					value::shape(&row, &["key", "value"])?;
					if value::get(&row, "key")? != wasm_bindgen::JsValue::from_str(&key) {
						return Err(Error::Invalid("bridge credential owner differs"));
					}
					let bytes = value::get(&row, "value")?
						.dyn_into::<js_sys::Uint8Array>()
						.map_err(|_| Error::Invalid("bridge credentials are not bytes"))?;
					if bytes.length() as usize > SessionDocument::BridgeSecrets.max_bytes() {
						return Err(Error::Invalid("bridge credentials exceed their byte ceiling"));
					}
					// One bounded copy crosses structured-clone storage into the Rust
					// document owner. Validate the browser length before allocating.
					let bytes = bytes.to_vec();
					SessionDocument::BridgeSecrets
						.decode(&bytes)
						.map_err(|_| Error::Invalid("invalid bridge credential document"))?;
					steps.data(|data| {
						*data = Some(bytes);
						Ok(())
					})
				})
			},
		)?));
		let Some(Completion::Read(result)) = self.finish_pending().await else {
			unreachable!("owned read")
		};
		result
	}
	async fn replace(&mut self, bytes: Vec<u8>) -> Result<(), WriteFailure<Error>> {
		self.idle().map_err(WriteFailure::Unchanged)?;
		SessionDocument::BridgeSecrets
			.decode(&bytes)
			.map_err(|_| WriteFailure::Unchanged(Error::Invalid("invalid bridge credential replacement")))?;
		let key = self.key.clone();
		let operation = Operation::start(
			&self.database,
			&[META],
			IdbTransactionMode::Readwrite,
			(),
			move |steps| {
				// IndexedDB owns one structured-clone copy until terminal commitment;
				// the input Vec retires after this synchronous transaction admission.
				let row = value::object(&[
					("key", key.into()),
					("value", js_sys::Uint8Array::from(bytes.as_slice()).into()),
				])?;
				steps.store(META)?.put(&row)?;
				Ok(())
			},
		)
		.map_err(WriteFailure::Unchanged)?;
		self.pending = Some(Pending::Write(operation));
		let Some(Completion::Write(result)) = self.finish_pending().await else {
			unreachable!("owned write")
		};
		result
	}
	async fn finish_pending(&mut self) -> Option<Completion<Error>> {
		let result = match self.pending.as_mut()? {
			Pending::Read(operation) => Completion::Read(operation.wait().await),
			// Operation publishes only complete or abort. An abort establishes
			// unchanged storage; abandoning this wait retains that evidence.
			Pending::Write(operation) => Completion::Write(operation.wait().await.map_err(WriteFailure::Unchanged)),
		};
		self.pending.take();
		Some(result)
	}
}
