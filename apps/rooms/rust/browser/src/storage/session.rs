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
use web_sys::{IdbCursor, IdbKeyRange, IdbTransactionMode};
const META: &str = "archive-meta";
const OWNER_PREFIX: &str = "session-owner:";

pub(crate) fn valid_tab(id: &str) -> bool {
	!id.is_empty() && id.len() <= 64 && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

/// Inventory the private bootstrap keys without reading the identities they hold.
pub(super) async fn saved_owners() -> std::result::Result<Vec<String>, Error> {
	let Some(database) = Database::existing().await? else {
		return Ok(Vec::new());
	};
	let mut operation = Operation::start(&database, &[META], IdbTransactionMode::Readonly, Vec::new(), |steps| {
		let range = IdbKeyRange::bound(&OWNER_PREFIX.into(), &format!("{OWNER_PREFIX}\u{ffff}").into())?;
		let request = steps.store(META)?.open_key_cursor_with_range(&range)?;
		steps.request(request, |steps, result| {
			if result.is_null() {
				return Ok(());
			}
			let cursor = result.dyn_into::<IdbCursor>().map_err(|_| Error::Schema)?;
			if let Some(key) = cursor.key()?.as_string()
				&& let Some(id) = key.strip_prefix(OWNER_PREFIX).filter(|id| valid_tab(id))
			{
				steps.data(|ids| {
					ids.push(id.to_owned());
					Ok(())
				})?;
			}
			cursor.continue_()?;
			Ok(())
		})
	})?;
	operation.wait().await
}

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
	pub async fn open(database: Database, tab: &str, existing: bool, mut entropy: impl Entropy) -> Result<Self> {
		if !valid_tab(tab) {
			return Err(loam::refusal("invalid Rooms tab identity"));
		}
		let key = format!("{OWNER_PREFIX}{tab}");
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
							if existing {
								return Err(Error::Invalid("The saved workspace identity is missing on this device"));
							}
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
		if existing && bootstrap.anchor.is_none() {
			return Err(loam::refusal("The saved workspace has no committed session"));
		}
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
		report: impl Fn(&str, &rooms_runtime::Error) + 'static,
	) -> core::result::Result<Opened<Platform>, rooms_runtime::Error> {
		let reply_bytes =
			NonZeroUsize::new(limits.forward_reply_bytes).ok_or_else(|| loam::refusal("Rooms reply budget is zero"))?;
		let store = if self.bootstrap.anchor.is_none() {
			Store::open_bootstrap(&self.name, self.bootstrap.store_identity, &schemas(), limits).await
		} else {
			Store::open(&self.name, self.bootstrap.store_identity, false, &schemas(), limits).await
		}
		.map_err(|error| {
			if error.code() == loam::WOULD_BLOCK {
				rooms_runtime::Error::coded(rooms_application::failure::FailureCode::WorkspaceAlreadyOpen, "")
			} else {
				rooms_runtime::Error::from(error)
			}
		})?;
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
					initial_connection: rooms_application::content::session::workspace::Connection::Fastest,
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
			return Err(rooms_runtime::cleanup::failed(error, opened.close().await));
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
