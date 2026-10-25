//! Per-tab private bootstrap persists through reload. IndexedDB commits metadata
//! before the shared Store can commit a root or expose public custody.
use super::{Database, Error, Operation};
use crate::platform::Platform;
use glowcap::{
	Host, Result,
	loam::{self, Limits, Store},
};
use rooms_runtime::{
	entropy::Entropy,
	session::managed::{Bootstrap, BootstrapOptions, Opened, schemas},
};
use std::num::NonZeroUsize;
use wasm_bindgen::{JsCast, JsValue};
use web_sys::IdbTransactionMode;
const META: &str = "archive-meta";

/// The embedding supplies a reload-stable tab identity. Sharing a tab identity
/// while its Store is open refuses through the existing Web Lock owner.
pub struct Prepared {
	database: Database,
	key: String,
	name: String,
	bootstrap: Bootstrap,
}
fn split_failure() -> glowcap::Error {
	loam::refusal("Rooms identity entropy has an unexpected length")
}
impl Prepared {
	pub async fn open(database: Database, tab: &str, mut entropy: impl Entropy) -> Result<Self> {
		if tab.is_empty() || tab.len() > 64 || !tab.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-') {
			return Err(loam::refusal("invalid Rooms tab identity"));
		}
		let key = format!("session-owner:{tab}");
		let name = format!("rooms-session-{tab}");
		let mut random = [0; 64];
		entropy
			.fill(&mut random)
			.map_err(|_| loam::refusal("Rooms identity entropy unavailable"))?;
		let fresh = Bootstrap {
			seed: random[..32].try_into().map_err(|_| split_failure())?,
			store_identity: random[32..48].try_into().map_err(|_| split_failure())?,
			owner_identity: random[48..].try_into().map_err(|_| split_failure())?,
			anchor: None,
		};
		let selected = key.clone();
		let mut operation = Operation::start(&database, &[META], IdbTransactionMode::Readwrite, fresh, |steps| {
			steps.request(
				steps.store(META)?.get(&selected.as_str().into())?,
				move |steps, value| {
					steps.data(|bootstrap| {
						if value.is_undefined() {
							steps.store(META)?.put(&row(&selected, *bootstrap)?)?;
						} else {
							*bootstrap = decode(&selected, value)?;
						}
						Ok(())
					})
				},
			)
		})
		.map_err(storage)?;
		let bootstrap = operation.wait().await.map_err(storage)?;
		Ok(Self {
			database,
			key,
			name,
			bootstrap,
		})
	}
	pub fn seed(&self) -> [u8; 32] {
		self.bootstrap.seed
	}
	pub async fn start(
		self,
		host: Host,
		platform: Platform,
		limits: Limits,
		live_capacity: u32,
		admission: rooms_application::admission::Settings,
		report: impl Fn(&str, &glowcap::Error) + 'static,
	) -> Result<Opened<Platform>> {
		let reply_bytes =
			NonZeroUsize::new(limits.forward_reply_bytes).ok_or_else(|| loam::refusal("Rooms reply budget is zero"))?;
		let store = if self.bootstrap.anchor.is_none() {
			Store::open_bootstrap(&self.name, self.bootstrap.store_identity, &schemas(), limits).await?
		} else {
			Store::open(&self.name, self.bootstrap.store_identity, false, &schemas(), limits).await?
		};
		let mut expected = self.bootstrap;
		let credentials = super::Credentials::new(self.database.clone(), &self.bootstrap.owner_identity);
		let mut opened = self
			.bootstrap
			.open(
				store,
				host,
				platform,
				BootstrapOptions {
					reply_bytes,
					live_capacity,
					initial_connection: rooms_application::content::session::workspace::Connection::Webrtc,
				},
				move |bootstrap| {
					let previous = expected;
					// Bootstrap awaits each confirmed write before requesting another.
					// A refusal or abandoned opening cannot submit the next stage.
					expected = bootstrap;
					persist(self.database.clone(), self.key.clone(), previous, bootstrap)
				},
			)
			.await?;
		let configured = async {
			// Install policy before credential recovery starts any session feed.
			opened.session().configure_admission(admission)?;
			// Credential retention starts the session feeds. Install their failure
			// owner before admitting that worker, including on a cold reopen.
			opened.session().on_trouble(report)?;
			opened.session().configure_credentials(credentials).await
		}
		.await;
		if let Err(error) = configured {
			return Err(error.with_cleanup(opened.close().await));
		}
		Ok(opened)
	}
}
async fn persist(database: Database, key: String, expected: Bootstrap, bootstrap: Bootstrap) -> Result<()> {
	let mut operation = Operation::start(&database, &[META], IdbTransactionMode::Readwrite, (), |steps| {
		steps.request(steps.store(META)?.get(&key.as_str().into())?, move |steps, value| {
			let prior = decode(&key, value)?;
			if prior.encode() != expected.encode() {
				return Err(Error::Invalid(
					"Rooms private startup metadata changed; reopen this session",
				));
			}
			steps.store(META)?.put(&row(&key, bootstrap)?)?;
			Ok(())
		})
	})
	.map_err(storage)?;
	operation.wait().await.map_err(storage)
}
/// One fixed Rust buffer copies to the Uint8Array supplied to IndexedDB. Its
/// existing terminal transaction owner retains the browser serialization. No
/// capability inventory or variable metadata allocation accompanies this row.
fn row(key: &str, bootstrap: Bootstrap) -> std::result::Result<JsValue, Error> {
	let object = js_sys::Object::new();
	js_sys::Reflect::set(&object, &"key".into(), &key.into())?;
	js_sys::Reflect::set(
		&object,
		&"value".into(),
		&js_sys::Uint8Array::from(bootstrap.encode().as_slice()),
	)?;
	Ok(object.into())
}
fn decode(key: &str, value: JsValue) -> std::result::Result<Bootstrap, Error> {
	if !value.is_object() || value.is_null() {
		return Err(Error::Invalid("Rooms private metadata is missing or invalid"));
	}
	let object = js_sys::Object::from(value);
	if js_sys::Object::keys(&object).length() != 2 || js_sys::Reflect::get(&object, &"key".into())? != key {
		return Err(Error::Invalid("invalid Rooms private metadata row"));
	}
	let bytes = js_sys::Reflect::get(&object, &"value".into())?
		.dyn_into::<js_sys::Uint8Array>()
		.map_err(|_| Error::Invalid("Rooms private metadata is not bytes"))?;
	if bytes.length() as usize != Bootstrap::BYTES {
		return Err(Error::Invalid("invalid Rooms private metadata length"));
	}
	let mut fixed = [0; Bootstrap::BYTES];
	bytes.copy_to(&mut fixed);
	Bootstrap::decode(fixed).map_err(|_| Error::Invalid("unsupported Rooms private metadata"))
}
fn storage(error: Error) -> glowcap::Error {
	loam::refusal(error.to_string())
}
