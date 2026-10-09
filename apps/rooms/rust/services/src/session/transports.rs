//! The peer's transport composition: one listener the browser attaches to, and
//! the dial providers its intended directories and direct partners need.
use super::{config::Transport, error::Error};
use glowcap::{Host, Locator, PendingWork, Runtime, RuntimeConfig, Session, iroh, tcp};
use rooms_platform::serving::{Listener, iroh_config};
use std::{collections::BTreeSet, rc::Rc};

/// The provider families a locator can name. A family is one provider package
/// in the binding; every symbol it serves is dialed through the same package.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Family {
	Tcp,
	Iroh,
	Relay,
	Onion,
}

/// What the peer must be able to dial. Declared by deployment before
/// restoration, independent of persisted capabilities. A relay URL adds
/// the relay family for browser members reachable only by rendezvous.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Needs {
	families: BTreeSet<Family>,
	relay_url: Option<String>,
}

impl Needs {
	pub fn configured(transports: &[String], relay_url: Option<String>) -> Result<Self, Error> {
		let mut families = BTreeSet::new();
		for transport in transports {
			let family = match transport.as_str() {
				"tcp" => Family::Tcp,
				"iroh" => Family::Iroh,
				"onion" => Family::Onion,
				_ => return Err(Error::invalid("unknown configured dial transport")),
			};
			families.insert(family);
		}
		if relay_url.is_some() {
			families.insert(Family::Relay);
		}
		Ok(Self { families, relay_url })
	}
}

/// The provider family the listener installed on the Host's loop.
fn installed(listener: &Listener) -> Family {
	match listener {
		Listener::Tcp(_) => Family::Tcp,
		Listener::Iroh(_) => Family::Iroh,
		Listener::Relay(_) => Family::Relay,
		Listener::Onion(_) => Family::Onion,
	}
}

/// The listener and the dial runtime over one Host.
///
/// Listening with `ListenerIdentity::Host` installs the listener's own provider
/// family on the Host's driver loop, and a provider name may be installed once.
/// The dial runtime adopting that same Host therefore adds exactly the families
/// the checkpoint needs that the listener did not already install. Nothing else
/// is opened: an iroh endpoint the session never dials through would still
/// reach relays and discovery, which a `check` run must not.
pub struct Transports {
	listener: Listener,
	locator: Locator,
	dial: Rc<Runtime>,
}

impl Transports {
	pub(crate) async fn open(
		host: &Host,
		transport: &Transport,
		needs: &Needs,
		keys: &mut impl rooms_platform::serving::onion::KeyStore,
	) -> Result<Self, Error> {
		let (listener, locator) = Listener::open(transport, host, keys).await?;
		let dial = match Self::dial_runtime(host, installed(&listener), needs).await {
			Ok(runtime) => Rc::new(runtime),
			Err(error) => return Err(error.retain_result(listener.close().await.map_err(Error::from))),
		};
		Ok(Self {
			listener,
			locator,
			dial,
		})
	}
	async fn dial_runtime(host: &Host, installed: Family, needs: &Needs) -> Result<Runtime, Error> {
		let mut providers = Vec::new();
		for family in needs.families.iter().filter(|family| **family != installed) {
			providers.push(match family {
				Family::Tcp => tcp::provider(Default::default()),
				Family::Iroh => iroh::provider(iroh_config(iroh::Reachability::Discovery)),
				Family::Relay => {
					let Some(url) = needs.relay_url.as_deref() else {
						// A relay-only directory with no relay URL is dialed
						// never; the directory row reports it when it tries.
						continue;
					};
					glowcap::relay::provider(glowcap::relay::Config::dial_only(url))
				}
				Family::Onion => {
					let socks = std::env::var("GLOWCAP_ONION_SOCKS")
						.ok()
						.filter(|s| !s.trim().is_empty())
						.ok_or_else(|| {
							Error::refused("onion directories need GLOWCAP_ONION_SOCKS naming a running Tor endpoint")
						})?;
					glowcap::onion::provider(glowcap::onion::Config::dial_only(&socks))
				}
			});
		}
		Ok(Runtime::open(RuntimeConfig::providers(providers).adopt_host(host)).await?)
	}
	pub fn locator(&self) -> &Locator {
		&self.locator
	}
	pub async fn accept(&self) -> Result<Session, rooms_platform::serving::TransportError> {
		self.listener.accept().await
	}
	pub(super) fn runtime(&self) -> Rc<Runtime> {
		self.dial.clone()
	}
	/// Stop accepting, then retire the dial runtime and, with it, the Host.
	pub async fn close(self) -> Result<(), Error> {
		let listener = self.listener.close().await.map_err(Error::from);
		let runtime = self.dial.close(PendingWork::Cancel).await.map_err(Error::from);
		Error::fold(listener, runtime)
	}
}
