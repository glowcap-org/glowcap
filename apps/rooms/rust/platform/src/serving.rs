//! What every host-side peer stands on to be reached: the transport it listens
//! over, the options that choose it, and serving one accepted partner to its
//! end. A peer composes these. None of them knows what the peer answers, so
//! the session peer, the archive peer, and the next one share exactly one
//! listener, one option grammar, and one account of a partner leaving.
use glowcap::{ErrorKind, Locator, PendingWork, Session, iroh, tcp};
use rooms_application::server::operations::listeners::{self, Transport as Profile};
use std::{fmt, time::Duration};
pub mod onion;
pub use onion::Config as OnionConfig;
pub mod endpoint;
mod opening;
pub mod relay;
pub use opening::{BindError, OpenError};

/// iroh's idle timeout for a peer's listener and its dial endpoint alike.
pub const IROH_IDLE_TIMEOUT_MS: u64 = 8_000;

/// Accepted connections a peer serves at once. Beyond this it stops accepting
/// until one ends, so a flood parks in the kernel backlog rather than in the
/// process.
pub const CONNECTION_LIMIT: usize = 128;

/// How long a peer waits after the listener refused an accept for a passing
/// reason, descriptors exhausted say, before it asks again. Long enough that a
/// refusal that persists is a slow loop and not a hot one.
pub const ACCEPT_RETRY: Duration = Duration::from_millis(250);

/// The wait after a refused accept, for a listener to back off on its own
/// while the peer keeps serving everyone already in. A refusal sets the
/// deadline. `wait` sleeps toward it and clears it. `ready` says whether the
/// listener may accept again. Cancelling a wait keeps its deadline.
#[derive(Default)]
pub struct Retry(Option<tokio::time::Instant>);
impl Retry {
	pub fn ready(&self) -> bool {
		self.0.is_none()
	}
	pub fn refused(&mut self) {
		self.0 = Some(tokio::time::Instant::now() + ACCEPT_RETRY);
	}
	pub async fn wait(&mut self) {
		match self.0 {
			Some(at) => tokio::time::sleep_until(at).await,
			None => std::future::pending().await,
		}
		self.0 = None;
	}
}

/// How a peer is reached: one of the listener profiles the seat table
/// names, with the options that profile takes.
pub enum Transport {
	/// The three tcp-socket profiles, told apart by `profile`.
	Tcp {
		profile: TcpProfile,
		bind: String,
		port: u16,
		announce: Option<String>,
	},
	Iroh(iroh::Reachability),
	/// The two relay-registered profiles, told apart by `profile`.
	Relay {
		profile: relay::Profile,
		address: relay::Address,
	},
	Onion(onion::Config),
}

/// Which tcp profile a tcp listener speaks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TcpProfile {
	/// Cleartext, dialed by address.
	Plain,
	/// Cleartext, dialed by key designator.
	Keyed,
	/// Noise_XK sealed, dialed by key designator.
	Noise,
}

/// What a seat-table row is to this platform: the listener family it opens
/// and, for a tcp or relay row, the profile inside it. `of` and `seat` are
/// the one mapping between the table and the typed profiles, and every
/// opener reads the table through it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
	Tcp(TcpProfile),
	Iroh,
	Relay(relay::Profile),
	Onion,
}

impl Family {
	pub fn of(profile: Profile) -> Self {
		match profile {
			Profile::Tcp => Self::Tcp(TcpProfile::Plain),
			Profile::KeyedTcp => Self::Tcp(TcpProfile::Keyed),
			Profile::NoiseTcp => Self::Tcp(TcpProfile::Noise),
			Profile::Iroh => Self::Iroh,
			Profile::KeyedRelay => Self::Relay(relay::Profile::Keyed),
			Profile::NoiseRelay => Self::Relay(relay::Profile::Noise),
			Profile::Onion => Self::Onion,
		}
	}
	pub fn seat(self) -> Profile {
		match self {
			Self::Tcp(TcpProfile::Plain) => Profile::Tcp,
			Self::Tcp(TcpProfile::Keyed) => Profile::KeyedTcp,
			Self::Tcp(TcpProfile::Noise) => Profile::NoiseTcp,
			Self::Iroh => Profile::Iroh,
			Self::Relay(relay::Profile::Keyed) => Profile::KeyedRelay,
			Self::Relay(relay::Profile::Noise) => Profile::NoiseRelay,
			Self::Onion => Profile::Onion,
		}
	}
}

impl Transport {
	/// Read the transport from named options. `named` answers an option from
	/// the argument list, and an absent one is read from the environment at
	/// the variable `variable` names for this peer. The facts a deployment
	/// shares across its peers stand in under one name each, whatever the
	/// peer: the relay at `GLOWCAP_ROOMS_RELAY_URL` and
	/// `GLOWCAP_ROOMS_RELAY_PUBLIC_URL`, and the running Tor at
	/// `GLOWCAP_ONION_SOCKS` and `GLOWCAP_ONION_CONTROL`. `peer` names the
	/// program in a refusal. TCP defaults to `127.0.0.1:0`. A wildcard bind
	/// needs an announced host, because the listener's own address is not one
	/// anybody can dial. A relay profile needs the relay it registers at.
	pub fn parse(
		named: impl Fn(&str) -> Option<String>,
		env: impl Fn(&str) -> Option<String>,
		variable: impl Fn(&str) -> String,
		peer: &str,
	) -> Result<Self, String> {
		let value = |key: &str| {
			named(key).or_else(|| {
				env(&variable(key))
					.map(|s| s.trim().to_owned())
					.filter(|s| !s.is_empty())
			})
		};
		let shared = |key: &str, global: &str| named(key).or_else(|| env(global));
		let name = value("transport").unwrap_or_else(|| "iroh".into());
		let profile = Profile::parse(&name).ok_or_else(|| {
			format!(
				"{peer} transport must be one of {}",
				listeners::TRANSPORTS.map(Profile::name).join(", ")
			)
		})?;
		match Family::of(profile) {
			Family::Iroh => Ok(Self::Iroh(
				match value("reachability").as_deref().unwrap_or("discovery") {
					"discovery" => iroh::Reachability::Discovery,
					"direct" => iroh::Reachability::Direct,
					_ => return Err(format!("{peer} reachability must be discovery or direct")),
				},
			)),
			Family::Tcp(profile) => {
				let bind = value("bind").unwrap_or_else(|| "127.0.0.1".into());
				let announce = value("announce-host");
				let port = value("port")
					.unwrap_or_else(|| "0".into())
					.parse::<u16>()
					.map_err(|_| format!("{peer} TCP port must be an integer from 0 through 65535"))?;
				if (bind == "0.0.0.0" || bind == "::" || bind == "[::]") && announce.is_none() {
					return Err(format!("{peer} wildcard bind needs --announce-host=<dialable-host>"));
				}
				Ok(Self::Tcp {
					profile,
					bind,
					port,
					announce,
				})
			}
			Family::Relay(profile) => {
				let address = relay::Address::configured(
					shared("relay", "GLOWCAP_ROOMS_RELAY_URL"),
					shared("relay-public", "GLOWCAP_ROOMS_RELAY_PUBLIC_URL"),
				)
				.map_err(|refusal| format!("{peer} {}", refusal.detail()))?
				.ok_or_else(|| {
					format!(
						"{peer} {name} transport registers at a relay: name its WebSocket URL with --relay=<ws-url> or GLOWCAP_ROOMS_RELAY_URL"
					)
				})?;
				Ok(Self::Relay { profile, address })
			}
			Family::Onion => onion::Config::parse(value, shared, peer).map(Self::Onion),
		}
	}
	/// The option names `parse` reads.
	pub const OPTIONS: &'static [&'static str] = &[
		"transport",
		"reachability",
		"bind",
		"port",
		"announce-host",
		"relay",
		"relay-public",
		"onion-socks",
		"onion-control",
		"onion-forward",
	];
	/// The seat-table row this listener stands in.
	pub fn profile(&self) -> Profile {
		match self {
			Self::Tcp { profile, .. } => Family::Tcp(*profile),
			Self::Iroh(_) => Family::Iroh,
			Self::Relay { profile, .. } => Family::Relay(*profile),
			Self::Onion(_) => Family::Onion,
		}
		.seat()
	}
	/// What an operator is told the peer listens over.
	pub fn describe(&self) -> &'static str {
		match self.profile() {
			Profile::Tcp => "tcp (cleartext)",
			Profile::KeyedTcp => "keyed-tcp (cleartext, dialed by key)",
			Profile::NoiseTcp => "noise-tcp (Noise_XK sealed)",
			Profile::Iroh => "iroh (encrypted QUIC)",
			Profile::KeyedRelay => "keyed-relay (cleartext through a relay)",
			Profile::NoiseRelay => "noise-relay (Noise_XK sealed through a relay)",
			Profile::Onion => "onion (Tor hidden service)",
		}
	}
}

/// The string a listener's locator is announced as: a plain tcp seat by its
/// bare address, the way the announce line names it; every other transport
/// by its complete locator, because the key, not the address, is the name
/// a peer dials.
pub fn announced(locator: &Locator) -> Result<String, TransportError> {
	if locator.transport == glowcap::TRANSPORT_TCP {
		return Ok(locator.designator.clone());
	}
	Ok(glowcap::format_locator_uri(locator)?)
}

pub fn iroh_config(reachability: iroh::Reachability) -> iroh::Config {
	let mut config = iroh::Config::new(reachability);
	config.idle_timeout_ms = Some(IROH_IDLE_TIMEOUT_MS);
	config
}

/// The listener a peer is reached through, installed on the Host's own loop.
pub enum Listener {
	/// The three tcp-socket profiles share one server type.
	Tcp(tcp::Server),
	Iroh(iroh::Server),
	/// The two relay-registered profiles share one server type.
	Relay(glowcap::relay::Server),
	Onion(glowcap::onion::Server),
}

/// The binding's error, boxed: it is wide, and every return path here is a
/// refusal a peer folds into its own vocabulary.
pub type TransportError = Box<glowcap::Error>;

impl Listener {
	pub async fn accept(&self) -> Result<Session, TransportError> {
		Ok(match self {
			Self::Tcp(server) => server.accept().await?,
			Self::Iroh(server) => server.accept().await?,
			Self::Relay(server) => server.accept().await?,
			Self::Onion(server) => server.accept().await?,
		})
	}
	pub async fn close(&self) -> Result<(), TransportError> {
		match self {
			Self::Tcp(server) => server.close().await?,
			Self::Iroh(server) => server.close().await?,
			Self::Relay(server) => server.close().await?,
			Self::Onion(server) => server.close().await?,
		}
		Ok(())
	}
	/// Select this listener's locator as the Host's advertised location.
	pub fn select(&self) -> Result<(), TransportError> {
		match self {
			Self::Tcp(server) => server.select()?,
			Self::Iroh(server) => server.select()?,
			Self::Relay(server) => server.select()?,
			Self::Onion(server) => server.select()?,
		}
		Ok(())
	}
}

/// Whether an accept failure ends listening. Only a closed listener does.
/// Anything else is a passing refusal the peer asks again after
/// `ACCEPT_RETRY`, because one exhausted descriptor table is not a reason to
/// stop serving the partners already here.
pub fn accept_ended(error: &glowcap::Error) -> bool {
	error.kind() == ErrorKind::Closed
}

/// How an accepted partner's service ended when it did not end.
#[derive(Debug)]
pub struct Ended {
	/// Why serving stopped, when the partner did not merely leave.
	pub cause: Option<TransportError>,
	/// What closing the session left behind.
	pub cleanup: Option<TransportError>,
}

impl fmt::Display for Ended {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match (&self.cause, &self.cleanup) {
			(Some(cause), None) => write!(f, "{cause}"),
			(None, Some(cleanup)) => write!(f, "closing the session failed: {cleanup}"),
			(Some(cause), Some(cleanup)) => write!(f, "{cause}; closing the session also failed: {cleanup}"),
			(None, None) => f.write_str("ended"),
		}
	}
}

/// Serve one accepted partner to its end. A partner that left, its
/// session closed or its connection lost under it, is not an outcome anyone
/// needs to hear. Anything else is the partner's business, returned so the
/// peer can report it, and never the peer's own failure.
pub async fn serve_partner(session: Session) -> Result<(), Ended> {
	serve_partner_until(session, std::future::pending()).await
}

/// Stop an accepted partner while keeping the shared Host alive. Retire its
/// admitted calls before the application releases their source attachment.
pub async fn serve_partner_until(session: Session, halt: impl std::future::Future<Output = ()>) -> Result<(), Ended> {
	let served = tokio::select! {
		_ = halt => Ok(()),
		served = session.serve() => served,
	};
	let closed = session.close(PendingWork::Cancel).await;
	let cause = match served {
		Ok(()) => None,
		Err(error) if left(&error) => None,
		Err(error) => Some(Box::new(error)),
	};
	let cleanup = match closed {
		Ok(()) => None,
		Err(error) if left(&error) => None,
		Err(error) => Some(Box::new(error)),
	};
	match (cause, cleanup) {
		(None, None) => Ok(()),
		(cause, cleanup) => Err(Ended { cause, cleanup }),
	}
}

/// A session that ended because the partner went away: closed cleanly, lost by
/// iroh, or discovered gone when TCP tried to flush its final write. The same
/// is true from the dialing side when the peer it reached has stopped.
pub fn left(error: &glowcap::Error) -> bool {
	if error.secondary_error_count() != 0 {
		return false;
	}
	match error.kind() {
		ErrorKind::Closed => true,
		ErrorKind::Io => error
			.message()
			.is_some_and(|message| message.ends_with("ConnectionLost") || message.ends_with("WriteFailed")),
		_ => false,
	}
}

/// What a serving loop tells its operator about partners and accepts, which
/// have no caller left to answer and never end the peer.
#[derive(Debug)]
pub enum PartnerNotice {
	/// An accepted connection ended for a reason other than the partner leaving.
	Ended(Ended),
	/// A task serving one accepted connection did not run to completion.
	TaskFailed(tokio::task::JoinError),
	/// The listener refused an accept for a passing reason. The peer asks again.
	AcceptRefused(TransportError),
}

impl fmt::Display for PartnerNotice {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Ended(ended) => write!(f, "a peer connection ended: {ended}"),
			Self::TaskFailed(cause) => write!(f, "a peer connection task failed: {cause}"),
			Self::AcceptRefused(cause) => write!(f, "accepting a connection failed, trying again: {cause}"),
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_seat_row_round_trips_through_its_family() {
		for profile in listeners::TRANSPORTS {
			assert_eq!(Family::of(profile).seat(), profile);
		}
	}
}
