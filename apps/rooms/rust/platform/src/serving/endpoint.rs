//! Private byte-stream routing for a local supervisor. This never enters an
//! OCapN locator or a Rooms capability response.
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum Endpoint {
	Tcp { host: String, port: u16 },
	Unix { path: PathBuf },
}
impl Endpoint {
	pub fn tcp(bind: &str, port: u16) -> Self {
		let host = match bind {
			"0.0.0.0" => "127.0.0.1",
			"::" | "[::]" => "::1",
			host => host,
		};
		Self::Tcp {
			host: host.into(),
			port,
		}
	}
	pub fn validate(&self) -> Result<(), String> {
		let valid = match self {
			Self::Tcp { host, port } => {
				*port != 0 && glowcap::designator_host_port(&glowcap::tcp::address_designator(host, *port)).is_ok()
			}
			Self::Unix { path } => path.is_absolute() && path.to_str().is_some_and(|s| !s.contains('\0')),
		};
		if valid {
			Ok(())
		} else {
			Err("server readiness names an invalid local endpoint".into())
		}
	}
}

pub fn bound(transport: &super::Transport, listener: &super::Listener) -> Option<Endpoint> {
	match (transport, listener) {
		(super::Transport::Tcp { .. }, super::Listener::Tcp(server)) => {
			let bound = server.local_addr();
			Some(Endpoint::tcp(&bound.ip().to_string(), bound.port()))
		}
		(super::Transport::Onion(config), super::Listener::Onion(_)) => match &config.forward {
			Some(path) => Some(Endpoint::Unix { path: path.clone() }),
			None if config.port != 0 => Some(Endpoint::tcp("127.0.0.1", config.port)),
			None => None,
		},
		_ => None,
	}
}
