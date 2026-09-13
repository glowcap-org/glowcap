//! What every host-side peer stands on to be reached: the transport it listens
//! over, the options that choose it, and serving one accepted partner to its
//! end. A peer composes these; none of them knows what the peer answers, so
//! the session peer, the archive peer, and the next one share exactly one
//! listener, one option grammar, and one account of a partner leaving.
use glowcap::{ErrorKind, PendingWork, Session, iroh, tcp};
use std::{fmt, time::Duration};
pub mod onion;
pub use onion::Config as OnionConfig;
pub mod endpoint;
mod opening;
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
/// deadline; `wait` sleeps toward it and clears it; `ready` says whether the
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

/// How a peer is reached.
pub enum Transport {
	Tcp {
		bind: String,
		port: u16,
		announce: Option<String>,
	},
	Iroh(iroh::Reachability),
	Onion(onion::Config),
}

impl Transport {
	/// Read the transport from named options, `value` answering each option
	/// name from the argument list or the environment. `peer` names the
	/// program in a refusal. TCP defaults to `127.0.0.1:0`; a wildcard bind
	/// needs an announced host, because the listener's own address is not one
	/// anybody can dial.
	pub fn parse(
		value: impl Fn(&str) -> Option<String>,
		env: impl Fn(&str) -> Option<String>,
		peer: &str,
	) -> Result<Self, String> {
		match value("transport").as_deref().unwrap_or("iroh") {
			"iroh" => Ok(Self::Iroh(
				match value("reachability").as_deref().unwrap_or("discovery") {
					"discovery" => iroh::Reachability::Discovery,
					"direct" => iroh::Reachability::Direct,
					_ => return Err(format!("{peer} reachability must be discovery or direct")),
				},
			)),
			"tcp" => {
				let bind = value("bind").unwrap_or_else(|| "127.0.0.1".into());
				let announce = value("announce-host");
				let port = value("port")
					.unwrap_or_else(|| "0".into())
					.parse::<u16>()
					.map_err(|_| format!("{peer} TCP port must be an integer from 0 through 65535"))?;
				if (bind == "0.0.0.0" || bind == "::" || bind == "[::]") && announce.is_none() {
					return Err(format!("{peer} wildcard bind needs --announce-host=<dialable-host>"));
				}
				Ok(Self::Tcp { bind, port, announce })
			}
			"onion" => onion::Config::parse(value, env, peer).map(Self::Onion),
			_ => Err(format!("{peer} transport must be iroh, tcp or onion")),
		}
	}
	/// The option names `parse` reads.
	pub const OPTIONS: &'static [&'static str] = &[
		"transport",
		"reachability",
		"bind",
		"port",
		"announce-host",
		"onion-socks",
		"onion-control",
		"onion-forward",
	];
	/// What an operator is told the peer listens over.
	pub fn describe(&self) -> &'static str {
		match self {
			Self::Tcp { .. } => "tcp (cleartext)",
			Self::Iroh(_) => "iroh (encrypted QUIC)",
			Self::Onion(_) => "onion (Tor hidden service)",
		}
	}
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

/// Whether an accept failure ends listening. Only a closed listener does;
/// anything else is a passing refusal the peer asks again after
/// `ACCEPT_RETRY`, because one exhausted descriptor table is not a reason to
/// stop serving the partners already here.
pub fn accept_ended(error: &glowcap::Error) -> bool {
	error.kind() == ErrorKind::Closed
}

/// How an accepted partner's service ended when it did not simply end.
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

/// Serve one accepted partner to its end. A partner that simply left, its
/// session closed or its connection lost under it, is not an outcome anyone
/// needs to hear; anything else is the partner's business, returned so the
/// peer can report it, and never the peer's own failure.
pub async fn serve_partner(session: Session) -> Result<(), Ended> {
	let session = session.with_gc();
	let served = session.serve().await;
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
	/// The listener refused an accept for a passing reason; the peer asks again.
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
