//! A peer becomes reachable only after its listener's restoration state is
//! safe. Failed startup closes the acquired listener before returning.
use super::{Listener, Transport, TransportError, iroh_config, onion::KeyStore};
use glowcap::{Host, ListenerIdentity, Locator, iroh, tcp};
use std::fmt;

#[derive(Debug)]
pub enum OpenError {
	Transport(TransportError),
	Bind(BindError),
	Restoration(String),
	Cleanup {
		primary: Box<Self>,
		cleanup: TransportError,
	},
}
impl From<glowcap::Error> for OpenError {
	fn from(error: glowcap::Error) -> Self {
		Self::Transport(Box::new(error))
	}
}
impl fmt::Display for OpenError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Transport(error) => error.fmt(f),
			Self::Bind(error) => error.fmt(f),
			Self::Restoration(reason) => write!(f, "onion service restoration failed: {reason}"),
			Self::Cleanup { primary, cleanup } => write!(f, "{primary}; closing the listener also failed: {cleanup}"),
		}
	}
}
impl std::error::Error for OpenError {}

/// The actual bind owns exclusion. Retain its address and failure together.
/// Diagnostic wording must never turn a different I/O failure into a collision.
#[derive(Debug)]
pub struct BindError {
	host: String,
	port: u16,
	cause: TransportError,
}
impl BindError {
	pub fn new(host: &str, port: u16, cause: glowcap::Error) -> Self {
		Self {
			host: host.into(),
			port,
			cause: Box::new(cause),
		}
	}
}
impl fmt::Display for BindError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		write!(f, "cannot listen on {}:{}: ", self.host, self.port)?;
		// This translates the host driver's diagnostic for display only;
		// admission and recovery continue to use the original failure.
		if self.cause.kind() == glowcap::ErrorKind::Io && self.cause.message() == Some("listener failed: AddressInUse")
		{
			f.write_str("address is already in use")
		} else {
			self.cause.fmt(f)
		}
	}
}
impl std::error::Error for BindError {
	fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
		Some(self.cause.as_ref())
	}
}

impl Listener {
	pub async fn open(
		transport: &Transport,
		host: &Host,
		keys: &mut impl KeyStore,
	) -> Result<(Self, Locator), OpenError> {
		let mut saved = None;
		let listener = match transport {
			Transport::Tcp { bind, port, announce } => Self::Tcp(
				tcp::listen(
					bind,
					*port,
					tcp::ListenOptions {
						identity: ListenerIdentity::Host(host.clone()),
						advertised_host: announce.clone(),
						..Default::default()
					},
				)
				.await
				.map_err(|error| OpenError::Bind(BindError::new(bind, *port, error)))?,
			),
			Transport::Iroh(reachability) => Self::Iroh(
				iroh::listen(
					iroh_config(*reachability),
					iroh::ListenOptions {
						identity: ListenerIdentity::Host(host.clone()),
					},
				)
				.await?,
			),
			Transport::Onion(config) => {
				saved = keys.read_key().await.map_err(OpenError::Restoration)?;
				if let Some(key) = &saved {
					super::onion::validate(key).map_err(OpenError::Restoration)?;
				}
				let forward = if let Some(path) = &config.forward {
					path.to_str()
						.ok_or_else(|| OpenError::Restoration("onion forward path is not Unicode".into()))?
						.to_owned()
				} else if config.port == 0 {
					String::new()
				} else {
					format!("127.0.0.1:{}", config.port)
				};
				let mut asked = glowcap::onion::Config::dial_only(&config.socks)
					.with_control(&config.control, glowcap::onion::Auth::None)
					.with_forward(&forward);
				asked.service_key = saved.as_deref().unwrap_or_default();
				Self::Onion(
					glowcap::onion::listen(
						asked,
						glowcap::onion::ListenOptions {
							identity: ListenerIdentity::Host(host.clone()),
						},
					)
					.await?,
				)
			}
		};
		let ready = async {
			let locator = match &listener {
				Self::Tcp(server) => server.locator()?,
				Self::Iroh(server) => {
					if matches!(transport, Transport::Iroh(iroh::Reachability::Discovery)) {
						iroh::locator(server.node_id(), None)
					} else {
						server.locator()?
					}
				}
				Self::Onion(server) => {
					let key = server.service_key();
					match &saved {
						Some(saved) if !key.is_empty() && saved.as_slice() != key => {
							return Err(OpenError::Restoration(
								"Tor returned a different service key; the saved key was preserved".into(),
							));
						}
						// Tor returns no PrivateKey when it accepted a saved one.
						// That saved key remains the restoration authority.
						Some(_) => {}
						None => {
							super::onion::validate(key).map_err(OpenError::Restoration)?;
							keys.save_key(key.to_vec()).await.map_err(OpenError::Restoration)?;
						}
					}
					server.locator()?
				}
				Self::Relay(_) => unreachable!("relay listeners are runtime operations"),
			};
			Ok(locator)
		}
		.await;
		match ready {
			Ok(locator) => Ok((listener, locator)),
			Err(primary) => match listener.close().await {
				Ok(()) => Err(primary),
				Err(cleanup) => Err(OpenError::Cleanup {
					primary: Box::new(primary),
					cleanup,
				}),
			},
		}
	}
}
