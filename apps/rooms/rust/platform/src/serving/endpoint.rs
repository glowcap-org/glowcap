//! Private byte-stream routing for a local supervisor. This never enters an
//! OCapN locator or a Rooms capability response.
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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

/// The local endpoint a web front forwards browser bytes to. Every tcp profile
/// is reached at its socket: a keyed or sealed profile's handshake rides inside
/// the forwarded bytes, as it does over any other byte stream.
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

#[cfg(test)]
mod tests {
	use super::*;
	use crate::serving::{Listener, TcpProfile, Transport, onion::KeyStore};

	struct NoKeys;
	impl KeyStore for NoKeys {
		async fn read_key(&mut self) -> Result<Option<Vec<u8>>, String> {
			Ok(None)
		}
		async fn save_key(&mut self, _: Vec<u8>) -> Result<(), String> {
			Err("a tcp listener saves no key".into())
		}
	}

	#[tokio::test]
	async fn every_tcp_profile_is_forwarded_to_at_its_socket() {
		let host = glowcap::Host::from_seed([41; 32]).unwrap();
		tokio::task::LocalSet::new()
			.run_until(async {
				for profile in [TcpProfile::Plain, TcpProfile::Keyed, TcpProfile::Noise] {
					let transport = Transport::Tcp {
						profile,
						bind: "127.0.0.1".into(),
						port: 0,
						announce: None,
					};
					let (listener, _) = Listener::open(&transport, &host, &mut NoKeys).await.unwrap();
					let Some(Endpoint::Tcp { host, port }) = bound(&transport, &listener) else {
						panic!("a {profile:?} tcp listener announced no local endpoint");
					};
					assert_eq!(host, "127.0.0.1");
					assert_ne!(port, 0);
					listener.close().await.unwrap();
				}
			})
			.await;
	}
}
