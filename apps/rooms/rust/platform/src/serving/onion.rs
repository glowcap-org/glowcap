//! Startup onion configuration and opaque service-key custody. Tor owns the
//! key format; Rooms keeps exactly the bytes its listener returned.
use crate::storage::{self, Directory};
use std::sync::Arc;

pub struct Config {
	pub socks: String,
	pub control: String,
	pub port: u16,
	/// Explicit private Unix forwarding socket. With none, bind loopback TCP.
	pub forward: Option<std::path::PathBuf>,
}
impl Config {
	pub(super) fn parse(
		value: impl Fn(&str) -> Option<String>,
		env: impl Fn(&str) -> Option<String>,
		peer: &str,
	) -> Result<Self, String> {
		let endpoint = |option, global| {
			value(option)
				.or_else(|| env(global))
				.map(|s| s.trim().to_owned())
				.filter(|s| !s.is_empty())
				.ok_or_else(|| {
					format!("{peer} onion transport needs --{option} or {global} naming a running Tor endpoint")
				})
		};
		let port = value("port")
			.unwrap_or_else(|| "0".into())
			.parse()
			.map_err(|_| format!("{peer} onion forward port must be an integer from 0 through 65535"))?;
		let forward = value("onion-forward").map(std::path::PathBuf::from);
		if let Some(path) = &forward
			&& (!path.is_absolute() || path.as_os_str().is_empty() || port != 0)
		{
			return Err(format!(
				"{peer} --onion-forward needs an absolute Unix socket path and --port=0"
			));
		}
		Ok(Self {
			socks: endpoint("onion-socks", "GLOWCAP_ONION_SOCKS")?,
			control: endpoint("onion-control", "GLOWCAP_ONION_CONTROL")?,
			port,
			forward,
		})
	}
}

/// Only an absent file requests a fresh service. Empty or oversized state is
/// refused locally; Tor validates the opaque key itself without a fallback.
pub trait KeyStore {
	fn read_key(&mut self) -> impl core::future::Future<Output = Result<Option<Vec<u8>>, String>>;
	fn save_key(&mut self, key: Vec<u8>) -> impl core::future::Future<Output = Result<(), String>>;
}

pub const FILE: &str = "onion-key";
// The binding owns the restoration-state capacity, including future formats.
const MAX_KEY: usize = glowcap::onion::MAX_SERVICE_KEY_BYTES;

pub fn read(directory: &Directory) -> Result<Option<Vec<u8>>, String> {
	let key = storage::read(&directory.path().join(FILE), MAX_KEY).map_err(|e| e.to_string())?;
	if let Some(key) = &key {
		validate(key)?;
	}
	Ok(key)
}
pub fn validate(key: &[u8]) -> Result<(), String> {
	if key.is_empty() || key.len() > MAX_KEY {
		Err("onion-key has no usable service restoration state".into())
	} else {
		Ok(())
	}
}

/// Reuses the peer's existing lease. A process-local peer explicitly has no
/// directory; dropping an observer still leaves disk work holding its lease.
pub struct KeyFile(pub Option<Arc<Directory>>);
impl KeyStore for KeyFile {
	async fn read_key(&mut self) -> Result<Option<Vec<u8>>, String> {
		let directory = self.0.clone();
		let Some(directory) = directory else {
			return Ok(None);
		};
		tokio::task::spawn_blocking(move || read(&directory))
			.await
			.map_err(|e| e.to_string())?
	}
	async fn save_key(&mut self, key: Vec<u8>) -> Result<(), String> {
		let directory = self.0.clone();
		validate(&key)?;
		let Some(directory) = directory else { return Ok(()) };
		tokio::task::spawn_blocking(move || {
			storage::atomic::replace(&directory, FILE, [key.as_slice()]).map_err(|failure| match failure {
				rooms_application::documents::WriteFailure::Unchanged(e) => e.to_string(),
				rooms_application::documents::WriteFailure::Indeterminate(e) => {
					format!("onion-key replacement is uncertain; restart to reconcile it: {e}")
				}
			})
		})
		.await
		.map_err(|e| e.to_string())?
	}
}
