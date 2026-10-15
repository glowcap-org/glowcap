//! The peer's transport composition: one listener the browser attaches to, and
//! the dial providers its intended directories and direct partners need.
use super::{config::Transport, error::Error};
use glowcap::{
	Host, ListenerIdentity, Locator, PendingWork, Runtime, RuntimeConfig, Session, iroh, tcp,
	webrtc::{self, IceServer, SignalingAuthority},
};
use rooms_platform::serving::{Listener, iroh_config};
use std::{collections::BTreeSet, rc::Rc};

/// The provider families a locator can name. A family is one provider package
/// in the binding. Every symbol it serves is dialed through the same package.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Family {
	Tcp,
	Iroh,
	Relay,
	Onion,
	/// Browser members that advertise WebRTC. A dial signals through the
	/// directory that introduced the member, and a member's offer arrives
	/// through a directory this peer is a named member of.
	Webrtc,
}

/// What the peer must be able to dial. Declared by deployment before
/// restoration, independent of persisted capabilities. A relay URL adds
/// the relay family for browser members reachable only by rendezvous.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Needs {
	families: BTreeSet<Family>,
	relay_url: Option<String>,
	relay_alias_url: Option<String>,
	ice_servers: Vec<IceServer>,
}

impl Needs {
	pub fn configured(
		transports: &[String],
		relay_url: Option<String>,
		relay_alias_url: Option<String>,
		ice_servers: Vec<IceServer>,
	) -> Result<Self, Error> {
		if relay_alias_url.is_some() && relay_url.is_none() {
			return Err(Error::invalid(
				"a relay alias requires a relay URL reaching the same registry",
			));
		}
		let mut families = BTreeSet::new();
		for transport in transports {
			let family = match transport.as_str() {
				"tcp" => Family::Tcp,
				"iroh" => Family::Iroh,
				"onion" => Family::Onion,
				"webrtc" => Family::Webrtc,
				_ => return Err(Error::invalid("unknown configured dial transport")),
			};
			families.insert(family);
		}
		if relay_url.is_some() {
			families.insert(Family::Relay);
		}
		Ok(Self {
			families,
			relay_url,
			relay_alias_url,
			ice_servers,
		})
	}
	pub fn dials(&self, family: Family) -> bool {
		self.families.contains(&family)
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
///
/// The WebRTC family takes the signaling authority the peer composed over its
/// directories. It is `Some` exactly when the needs include that family. That
/// family listens as well as dials, through one provider on the Host's loop:
/// the peer then registers its WebRTC locator with its directories, with the
/// listener's locator as the fallback a peer without WebRTC dials.
pub struct Transports {
	listener: Listener,
	locator: Locator,
	webrtc: Option<Rc<webrtc::Server>>,
	registered: Locator,
	dial: Rc<Runtime>,
}

impl Transports {
	pub(crate) async fn open(
		host: &Host,
		transport: &Transport,
		needs: &Needs,
		keys: &mut impl rooms_platform::serving::onion::KeyStore,
		signaling: Option<Rc<dyn SignalingAuthority>>,
	) -> Result<Self, Error> {
		let (listener, locator) = Listener::open(transport, host, keys).await?;
		let answering = match Self::answering(host, needs, signaling, &locator).await {
			Ok(answering) => answering,
			Err(error) => return Err(error.retain_result(listener.close().await.map_err(Error::from))),
		};
		let (webrtc, registered) = match answering {
			Some((server, registered)) => (Some(Rc::new(server)), registered),
			None => (None, locator.clone()),
		};
		let dial = match Self::dial_runtime(host, installed(&listener), needs).await {
			Ok(runtime) => Rc::new(runtime),
			Err(error) => {
				let listener = listener.close().await.map_err(Error::from);
				let webrtc = match &webrtc {
					Some(server) => server.close().await.map_err(Error::from),
					None => Ok(()),
				};
				return Err(error.retain_result(Error::fold(listener, webrtc)));
			}
		};
		Ok(Self {
			listener,
			locator,
			webrtc,
			registered,
			dial,
		})
	}
	/// Listen for WebRTC on the Host when the needs include it. The locator to
	/// register names it first, with `fallback` as the alternative. The Host's
	/// loop advertises each listener's own locator.
	async fn answering(
		host: &Host,
		needs: &Needs,
		signaling: Option<Rc<dyn SignalingAuthority>>,
		fallback: &Locator,
	) -> Result<Option<(webrtc::Server, Locator)>, Error> {
		if !needs.dials(Family::Webrtc) {
			return Ok(None);
		}
		let signaling = signaling.ok_or_else(|| Error::invalid("webrtc needs the peer's signaling authority"))?;
		let config = webrtc::Config {
			ice_servers: needs.ice_servers.clone(),
			include_loopback_candidates: false,
		};
		let options = webrtc::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
		};
		let server = webrtc::listen(signaling, config, options).await?;
		let registered = glowcap::format_locator_uri(fallback).and_then(|fallback| {
			Ok(server
				.locator()?
				.with_hint(glowcap::HINT_ALT_LOCATORS, glowcap::HintValue::String(fallback)))
		});
		match registered {
			Ok(registered) => Ok(Some((server, registered))),
			Err(error) => Err(Error::from(error).retain_result(server.close().await.map_err(Error::from))),
		}
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
					let mut config = glowcap::relay::Config::dial_only(url);
					if let Some(alias) = needs.relay_alias_url.as_deref() {
						config = config.with_relay_alias(alias);
					}
					glowcap::relay::provider(config)
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
				// The WebRTC listener installed its provider on the Host's loop.
				Family::Webrtc => continue,
			});
		}
		Ok(Runtime::open(RuntimeConfig::providers(providers).adopt_host(host)).await?)
	}
	/// The listener's own locator, which the peer's links name.
	pub fn locator(&self) -> &Locator {
		&self.locator
	}
	/// The locator the peer registers with its directories: the WebRTC one
	/// first when the peer answers WebRTC.
	pub fn registered(&self) -> &Locator {
		&self.registered
	}
	/// The WebRTC listener, when the peer answers WebRTC.
	pub fn webrtc(&self) -> Option<Rc<webrtc::Server>> {
		self.webrtc.clone()
	}
	/// The next partner from either listener.
	pub async fn accept(&self) -> Result<Session, rooms_platform::serving::TransportError> {
		match &self.webrtc {
			Some(webrtc) => tokio::select! {
				accepted = self.listener.accept() => accepted,
				accepted = webrtc.accept() => Ok(accepted?),
			},
			None => self.listener.accept().await,
		}
	}
	pub(super) fn runtime(&self) -> Rc<Runtime> {
		self.dial.clone()
	}
	/// Stop accepting, then retire the dial runtime and, with it, the Host.
	pub async fn close(self) -> Result<(), Error> {
		let listener = self.listener.close().await.map_err(Error::from);
		let webrtc = match &self.webrtc {
			Some(server) => server.close().await.map_err(Error::from),
			None => Ok(()),
		};
		let runtime = self.dial.close(PendingWork::Cancel).await.map_err(Error::from);
		Error::fold(Error::fold(listener, webrtc), runtime)
	}
}
