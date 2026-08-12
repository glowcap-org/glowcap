//! The listen / accept surface: [`Server`], [`KeyedTcpServer`], and the
//! top-level [`listen`] / [`listen_keyed_tcp`] hosters.
//!
//! Every application listener binds through the driver archive
//! (ADR-0112), including caller-supplied Hosts: a quiescent Host transfers to
//! the loop before its first network operation. The loop owns sockets,
//! admission, pumping, and session release. [`LoopListener`] is the one
//! binding owner of a generic driver listener; TCP and iroh public servers add
//! only their transport-specific metadata around it.

use std::cell::Cell;
use std::rc::Rc;
use tokio::net::ToSocketAddrs;

use crate::abi_constants::HINT_DIRECT_ADDRESSES;
use crate::host::Host;
use crate::session::{io_err, Session};
use crate::Result;

/// A listening server, the host-side counterpart of [`crate::connect`]. Call
/// [`Server::accept`] for each partner; every accepted [`Session`] shares the
/// server's one [`Host`] (its retained identity and handoff router), so
/// the server is one Host serving many partners.
///
/// A bare [`listen`] rides the driver archive (ADR-0112), and its Host
/// owns the loop: `server.host().close()` (or the last accepted session
/// dropping the Host) closes the listener and every loop-minted session with
/// it. On the byte-fed admission tier, dropping the server stops accepting
/// while live sessions are unaffected.
pub struct Server {
	listener: LoopListener,
	local_addr: std::net::SocketAddr,
}

/// A native-loop `noise-tcp` server. Its durable public key is the locator
/// designator, and every accepted channel is sealed before CapTP opens.
pub struct NoiseTcpServer {
	server: Server,
	designator: String,
	direct_address: String,
}

impl NoiseTcpServer {
	pub async fn accept(&self) -> Result<Session> {
		self.server.accept().await
	}

	pub fn local_addr(&self) -> Result<std::net::SocketAddr> {
		self.server.local_addr()
	}

	pub fn host(&self) -> Host {
		self.server.host()
	}

	/// The durable public key this server proves.
	pub fn designator(&self) -> &str {
		&self.designator
	}

	/// The complete dialable `noise-tcp` peer locator.
	pub fn uri(&self) -> Result<String> {
		let (host, port) = crate::uri::designator_host_port(&self.direct_address)?;
		Ok(crate::uri::noise_tcp_locator(&self.designator, &host, port))
	}
}

/// The binding's single owner for a native driver's generic listener handle.
/// Closing it seals admission and releases accepted sessions not yet yielded;
/// sessions already returned to the application remain owned by their Host.
pub(crate) struct LoopListener {
	pub(crate) lp: Rc<crate::driver_loop::LoopShared>,
	listener: u64,
	host: Host,
	closed: Cell<bool>,
}

impl LoopListener {
	pub(crate) fn new(lp: Rc<crate::driver_loop::LoopShared>, listener: u64, host: Host) -> Self {
		Self {
			lp,
			listener,
			host,
			closed: Cell::new(false),
		}
	}

	pub(crate) fn host(&self) -> Host {
		self.host.clone()
	}

	#[cfg(feature = "iroh")]
	pub(crate) fn locator(&self) -> Result<crate::uri::Locator> {
		if self.closed.get() {
			return Err(crate::Error::from_code(crate::sys::ERR_CLOSED));
		}
		self.lp.listener_locator(self.listener)
	}

	pub(crate) async fn accept(&self) -> Result<Session> {
		if self.closed.get() {
			return Err(crate::Error::from_code(crate::sys::ERR_CLOSED));
		}
		let session = self.lp.accept(self.listener).await?;
		crate::driver_loop::loop_session(&self.lp, session, false)
	}

	pub(crate) fn close(&self) -> Result<()> {
		if self.closed.replace(true) {
			return Ok(());
		}
		if let Err(err) = self.lp.close_listener(self.listener) {
			self.closed.set(false);
			return Err(err);
		}
		self.lp.discard_accepts(self.listener);
		Ok(())
	}
}

impl Drop for LoopListener {
	fn drop(&mut self) {
		let _ = self.close();
	}
}

/// Listener advertisement policy. `advertised_host` is required for a
/// wildcard bind; admission limits belong to the native driver.
#[derive(Clone, Debug)]
pub struct ListenOptions {
	pub advertised_host: Option<String>,
}

impl Default for ListenOptions {
	fn default() -> Self {
		Self {
			advertised_host: None,
		}
	}
}

impl Server {
	/// Accept the next partner as a ready [`Session`], sharing this server's
	/// [`Host`]. The keyed handshake completes before this resolves; a partner
	/// that fails it — a rude probe that connects and hangs up, or a stray port
	/// scan — is that session's failure, never the listener's, so the accept
	/// skips it and keeps serving. Must be called inside a `LocalSet` (the
	/// handle graph is `!Send`).
	///
	/// The native driver owns bounded admission and advances independent
	/// handshakes without binding listener progress to application `accept`.
	pub async fn accept(&self) -> Result<Session> {
		self.listener.accept().await
	}

	/// The bound local address, read the port off it when you bound port 0.
	pub fn local_addr(&self) -> Result<std::net::SocketAddr> {
		Ok(self.local_addr)
	}

	/// This server's [`Host`], one retained identity and session directory
	/// across every accepted session. Pass it to
	/// [`crate::connect`] as `Some(server.host())` so a capability fetched on a dialed
	/// session and returned to an accepted one shares one Host (the gifter
	/// half of a three-party handoff), and publish a Host-giftable on it with
	/// [`Host::publish_giftable`].
	pub fn host(&self) -> Host {
		self.listener.host()
	}

	/// Stop admitting partners. Sessions already returned by [`Server::accept`]
	/// remain live; close them individually or close the shared [`Host`].
	pub fn close(&self) -> Result<()> {
		self.listener.close()
	}
}

/// Bind `addr` and return a [`Server`] to [`accept`](Server::accept) partners
/// on, the host-side counterpart of [`crate::connect`]. The server is one Host with a
/// fresh retained identity shared across every accepted session. This is the
/// native loop route (ADR-0112): the loop owns the socket, the accept
/// admission, and the pumping.
pub async fn listen<A: ToSocketAddrs>(addr: A) -> Result<Server> {
	listen_loop(addr, None).await
}

/// [`listen`] with an explicit address to sign and advertise. Required when
/// the socket binds a wildcard address, because bind policy is not reachability.
pub async fn listen_advertised<A: ToSocketAddrs>(addr: A, advertised_host: &str) -> Result<Server> {
	listen_loop(addr, Some(advertised_host)).await
}

/// Bind the driver archive's listener (ADR-0112): one loop owning the
/// socket, the accept admission, and every accepted session's pumping, with
/// the public [`Host`] adopted over the loop's own.
async fn listen_loop<A: ToSocketAddrs>(addr: A, advertised_host: Option<&str>) -> Result<Server> {
	let bind = tokio::net::lookup_host(addr)
		.await
		.map_err(io_err)?
		.next()
		.ok_or_else(|| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				"listen address resolved to nothing",
			))
		})?;
	let lp = crate::driver_loop::LoopShared::open(
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
	)?;
	let opened = async {
		crate::tcp::ensure_loop_provider(&lp)?;
		let listener = lp.listen(
			crate::abi_constants::TRANSPORT_TCP,
			&crate::uri::socket_addr_designator(&bind.ip().to_string(), bind.port()),
		)?;
		let locator = lp.listener_locator(listener)?;
		let bound = locator.designator;
		let local_addr: std::net::SocketAddr = bound.parse().map_err(|_| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				format!("the listener reported an unparsable designator {bound:?}"),
			))
		})?;
		// The loop's listen already advertises the bound locator; what remains
		// is this binding's own policy: refuse an undialable wildcard unless
		// an advertised host names the real route, and record the designator
		// this Host's dials sign as their own dialable address (the gifter
		// side of a handoff) — the same bind the byte-fed listen performs.
		let designator = match advertised_host {
			Some(advertised) => {
				let bare = advertised
					.strip_prefix('[')
					.and_then(|value| value.strip_suffix(']'))
					.unwrap_or(advertised);
				let wildcard = bare
					.parse::<std::net::IpAddr>()
					.is_ok_and(|address| address.is_unspecified());
				if wildcard {
					return Err(io_err(std::io::Error::new(
						std::io::ErrorKind::InvalidInput,
						"a wildcard bind has no dialable address; provide an advertised host",
					)));
				}
				crate::uri::socket_addr_designator(bare, local_addr.port())
			}
			None => {
				if local_addr.ip().is_unspecified() {
					return Err(io_err(std::io::Error::new(
						std::io::ErrorKind::InvalidInput,
						"a wildcard bind has no dialable address; provide an advertised host",
					)));
				}
				bound.clone()
			}
		};
		if designator != bound {
			let locator_uri = crate::uri::format_peer_locator(
				crate::abi_constants::TRANSPORT_TCP,
				&designator,
				"",
			)?;
			lp.advertise_listener(listener, &locator_uri)?;
		}
		lp.select_listener(listener)?;
		let host = lp.wrapper_host()?;
		lp.start()?;
		Ok(Server {
			listener: LoopListener::new(Rc::clone(&lp), listener, Host::from_shared(host)),
			local_addr,
		})
	}
	.await;
	if opened.is_err() {
		lp.close();
	}
	opened
}

/// Bind a sealed `noise-tcp` listener. Reuse the optional 32-byte identity
/// seed across restarts to keep the same key designator; each process still
/// draws a fresh session-key root.
pub async fn listen_noise_tcp(
	bind_host: &str,
	port: u16,
	seed: Option<[u8; 32]>,
) -> Result<NoiseTcpServer> {
	listen_noise_tcp_advertised(bind_host, port, seed, None).await
}

/// [`listen_noise_tcp`] with an explicit dialable host for a wildcard bind.
pub async fn listen_noise_tcp_advertised(
	bind_host: &str,
	port: u16,
	seed: Option<[u8; 32]>,
	advertised_host: Option<&str>,
) -> Result<NoiseTcpServer> {
	let bind = tokio::net::lookup_host((bind_host, port))
		.await
		.map_err(io_err)?
		.next()
		.ok_or_else(|| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				"listen address resolved to nothing",
			))
		})?;
	let lp = crate::driver_loop::LoopShared::open_with_durable_seed(
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
		seed,
	)?;
	let opened = async {
		crate::tcp::ensure_loop_provider(&lp)?;
		let listener = lp.listen(
			crate::abi_constants::TRANSPORT_NOISE_TCP,
			&crate::uri::socket_addr_designator(&bind.ip().to_string(), bind.port()),
		)?;
		let locator = lp.listener_locator(listener)?;
		let bound_direct = locator
			.string_hint(HINT_DIRECT_ADDRESSES)?
			.map(str::to_owned)
			.ok_or_else(|| {
				io_err(std::io::Error::new(
					std::io::ErrorKind::InvalidData,
					"the noise-tcp listener locator has no direct-addresses hint",
				))
			})?;
		let designator = locator.designator;
		let local_addr: std::net::SocketAddr = bound_direct.parse().map_err(|_| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				format!("the listener reported an unparsable direct address {bound_direct:?}"),
			))
		})?;
		let has_advertised_host = advertised_host.is_some();
		let direct_address = match advertised_host {
			Some(advertised) => crate::uri::socket_addr_designator(advertised, local_addr.port()),
			None => {
				if local_addr.ip().is_unspecified() {
					return Err(io_err(std::io::Error::new(
						std::io::ErrorKind::InvalidInput,
						"a wildcard bind has no dialable address; provide an advertised host",
					)));
				}
				bound_direct
			}
		};
		if has_advertised_host {
			let locator_uri = crate::uri::format_peer_locator(
				crate::abi_constants::TRANSPORT_NOISE_TCP,
				&designator,
				&direct_address,
			)?;
			lp.advertise_listener(listener, &locator_uri)?;
		}
		lp.select_listener(listener)?;
		let host = lp.wrapper_host()?;
		lp.start()?;
		Ok(NoiseTcpServer {
			server: Server {
				listener: LoopListener::new(Rc::clone(&lp), listener, Host::from_shared(host)),
				local_addr,
			},
			designator,
			direct_address,
		})
	}
	.await;
	if opened.is_err() {
		lp.close();
	}
	opened
}

/// [`listen`] with explicit advertisement policy.
pub async fn listen_with_options<A: ToSocketAddrs>(
	addr: A,
	options: ListenOptions,
) -> Result<Server> {
	listen_with_host_options(addr, Host::new_host(), options).await
}

/// [`listen`] on a caller-supplied Host — how a server shares one identity and
/// live-session directory with sessions it dials (the gifter half of a
/// three-party handoff), or speaks a non-default codec ([`Host::with_codec`]).
pub async fn listen_with_host<A: ToSocketAddrs>(addr: A, host: Host) -> Result<Server> {
	listen_with_host_options(addr, host, ListenOptions::default()).await
}

/// [`listen_with_host`] with an explicit dialable address for a wildcard bind.
pub async fn listen_with_host_advertised<A: ToSocketAddrs>(
	addr: A,
	host: Host,
	advertised_host: &str,
) -> Result<Server> {
	listen_with_host_options(
		addr,
		host,
		ListenOptions {
			advertised_host: Some(advertised_host.to_string()),
			..ListenOptions::default()
		},
	)
	.await
}

/// [`listen_with_host`] with explicit advertisement policy.
pub async fn listen_with_host_options<A: ToSocketAddrs>(
	addr: A,
	host: Host,
	options: ListenOptions,
) -> Result<Server> {
	let bind = tokio::net::lookup_host(addr)
		.await
		.map_err(io_err)?
		.next()
		.ok_or_else(|| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				"listen address resolved to nothing",
			))
		})?;
	let shared = host.shared();
	let lp = shared.ensure_driver_loop(
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
	)?;
	crate::tcp::ensure_loop_provider(&lp)?;
	let listener = lp.listen(
		crate::abi_constants::TRANSPORT_TCP,
		&crate::uri::socket_addr_designator(&bind.ip().to_string(), bind.port()),
	)?;
	let opened = (|| {
		let locator = lp.listener_locator(listener)?;
		let bound = locator.designator;
		let local_addr: std::net::SocketAddr = bound.parse().map_err(|_| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				format!("the listener reported an unparsable designator {bound:?}"),
			))
		})?;
		let advertised = match options.advertised_host.as_deref() {
			Some(value) => crate::uri::socket_addr_designator(value, local_addr.port()),
			None if local_addr.ip().is_unspecified() => {
				return Err(io_err(std::io::Error::new(
					std::io::ErrorKind::InvalidInput,
					"a wildcard bind has no dialable address; provide an advertised host",
				)))
			}
			None => bound.clone(),
		};
		if advertised != bound {
			let locator_uri = crate::uri::format_peer_locator(
				crate::abi_constants::TRANSPORT_TCP,
				&advertised,
				"",
			)?;
			lp.advertise_listener(listener, &locator_uri)?;
		}
		lp.select_listener(listener)?;
		Ok(Server {
			listener: LoopListener::new(Rc::clone(&lp), listener, host),
			local_addr,
		})
	})();
	if opened.is_err() {
		let _ = lp.close_listener(listener);
	}
	opened
}

/// A keyed-tcp listening server: TCP sockets under a durable key designator
/// (ADR-0075). The Host's Ed25519 identity seed *is* the locator designator.
/// CapTP session signing keys are separate: [`Host`] appends a fresh
/// per-process session-key root when constructing the native host (ADR-0097).
/// Build one with [`listen_keyed_tcp`].
pub struct KeyedTcpServer {
	server: Server,
	designator: String,
	advertised_host: String,
}

impl KeyedTcpServer {
	/// Accept the next partner as a ready [`Session`], signing this Host's
	/// key designator with the bound address riding the `direct-addresses` hint.
	/// The native loop's handshake budget applies; a
	/// partner that fails it or overruns the bound is skipped while the listener
	/// keeps serving.
	pub async fn accept(&self) -> Result<Session> {
		self.server.accept().await
	}

	/// The bound local address; read the port off it when you bound port 0.
	pub fn local_addr(&self) -> Result<std::net::SocketAddr> {
		self.server.local_addr()
	}

	/// This server's Host — one retained identity and handoff router across every
	/// accepted session. The identity seed is the keyed-tcp designator.
	pub fn host(&self) -> Host {
		self.server.host()
	}

	/// The key designator this server signs (64 lowercase hex digits).
	pub fn designator(&self) -> &str {
		&self.designator
	}

	/// The `ocapn://<key>.keyed-tcp?direct-addresses=<bound>` URI a partner dials.
	pub fn uri(&self) -> Result<String> {
		let addr = self.server.local_addr()?;
		Ok(crate::uri::keyed_tcp_locator(
			&self.designator,
			&self.advertised_host,
			addr.port(),
		))
	}
}

/// Bind `bind_host`:`port` as a keyed-tcp listener whose designator is the public
/// half of `seed` (or a fresh random seed when `None`). The Host identity seed
/// *is* the locator designator — pass the same seed after a restart to keep
/// that designator stable (ADR-0075). CapTP session signing keys come from a
/// fresh per-process root the Host draws at construction (ADR-0097).
pub async fn listen_keyed_tcp(
	bind_host: &str,
	port: u16,
	seed: Option<[u8; 32]>,
) -> Result<KeyedTcpServer> {
	listen_keyed_tcp_loop(bind_host, port, seed, None).await
}

/// [`listen_keyed_tcp`] with an explicit dialable host for a wildcard bind.
pub async fn listen_keyed_tcp_advertised(
	bind_host: &str,
	port: u16,
	seed: Option<[u8; 32]>,
	advertised_host: Option<&str>,
) -> Result<KeyedTcpServer> {
	listen_keyed_tcp_loop(bind_host, port, seed, advertised_host).await
}

/// Bind the driver archive's keyed-tcp listener. The loop's durable seed
/// is the keyed identity, while its second seed half remains fresh per process.
async fn listen_keyed_tcp_loop(
	bind_host: &str,
	port: u16,
	seed: Option<[u8; 32]>,
	advertised_host: Option<&str>,
) -> Result<KeyedTcpServer> {
	let bind = tokio::net::lookup_host((bind_host, port))
		.await
		.map_err(io_err)?
		.next()
		.ok_or_else(|| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				"listen address resolved to nothing",
			))
		})?;
	let lp = crate::driver_loop::LoopShared::open_with_durable_seed(
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
		seed,
	)?;
	let opened = async {
		crate::tcp::ensure_loop_provider(&lp)?;
		let listener = lp.listen(
			crate::abi_constants::TRANSPORT_KEYED_TCP,
			&crate::uri::socket_addr_designator(&bind.ip().to_string(), bind.port()),
		)?;
		let locator = lp.listener_locator(listener)?;
		let bound_direct = locator
			.string_hint(HINT_DIRECT_ADDRESSES)?
			.map(str::to_owned)
			.ok_or_else(|| {
				io_err(std::io::Error::new(
					std::io::ErrorKind::InvalidData,
					"the keyed-tcp listener locator has no direct-addresses hint",
				))
			})?;
		let designator = locator.designator;
		let local_addr: std::net::SocketAddr = bound_direct.parse().map_err(|_| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				format!("the listener reported an unparsable direct address {bound_direct:?}"),
			))
		})?;
		let has_advertised_host = advertised_host.is_some();
		let direct_address = match advertised_host {
			Some(advertised) => crate::uri::socket_addr_designator(advertised, local_addr.port()),
			None => {
				if local_addr.ip().is_unspecified() {
					return Err(io_err(std::io::Error::new(
						std::io::ErrorKind::InvalidInput,
						"a wildcard bind has no dialable address; provide an advertised host",
					)));
				}
				bound_direct
			}
		};
		let (advertised_host, _) = crate::uri::designator_host_port(&direct_address)?;
		if has_advertised_host {
			let locator_uri = crate::uri::format_peer_locator(
				crate::abi_constants::TRANSPORT_KEYED_TCP,
				&designator,
				&direct_address,
			)?;
			lp.advertise_listener(listener, &locator_uri)?;
		}
		lp.select_listener(listener)?;
		let host = lp.wrapper_host()?;
		lp.start()?;
		Ok(KeyedTcpServer {
			server: Server {
				listener: LoopListener::new(Rc::clone(&lp), listener, Host::from_shared(host)),
				local_addr,
			},
			designator,
			advertised_host,
		})
	}
	.await;
	if opened.is_err() {
		lp.close();
	}
	opened
}

/// [`listen_keyed_tcp`] with explicit advertisement policy.
pub async fn listen_keyed_tcp_with_options(
	bind_host: &str,
	port: u16,
	seed: Option<[u8; 32]>,
	options: ListenOptions,
) -> Result<KeyedTcpServer> {
	let host = match seed {
		Some(s) => Host::from_seed(s)?,
		None => Host::new_host(),
	};
	let bind = tokio::net::lookup_host((bind_host, port))
		.await
		.map_err(io_err)?
		.next()
		.ok_or_else(|| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				"listen address resolved to nothing",
			))
		})?;
	let shared = host.shared();
	let lp = shared.ensure_driver_loop(
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
	)?;
	let listener = lp.listen(
		crate::abi_constants::TRANSPORT_KEYED_TCP,
		&crate::uri::socket_addr_designator(&bind.ip().to_string(), bind.port()),
	)?;
	let opened = (|| {
		let locator = lp.listener_locator(listener)?;
		let bound_direct = locator
			.string_hint(HINT_DIRECT_ADDRESSES)?
			.map(str::to_owned)
			.ok_or_else(|| {
				io_err(std::io::Error::new(
					std::io::ErrorKind::InvalidData,
					"the keyed-tcp listener locator has no direct-addresses hint",
				))
			})?;
		let designator = locator.designator;
		let local_addr: std::net::SocketAddr = bound_direct.parse().map_err(|_| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidInput,
				format!("the listener reported an unparsable direct address {bound_direct:?}"),
			))
		})?;
		let direct_address = match options.advertised_host.as_deref() {
			Some(value) => crate::uri::socket_addr_designator(value, local_addr.port()),
			None if local_addr.ip().is_unspecified() => {
				return Err(io_err(std::io::Error::new(
					std::io::ErrorKind::InvalidInput,
					"a wildcard bind has no dialable address; provide an advertised host",
				)))
			}
			None => bound_direct,
		};
		if options.advertised_host.is_some() {
			let locator_uri = crate::uri::format_peer_locator(
				crate::abi_constants::TRANSPORT_KEYED_TCP,
				&designator,
				&direct_address,
			)?;
			lp.advertise_listener(listener, &locator_uri)?;
		}
		lp.select_listener(listener)?;
		let (advertised_host, _) = crate::uri::designator_host_port(&direct_address)?;
		Ok(KeyedTcpServer {
			server: Server {
				listener: LoopListener::new(Rc::clone(&lp), listener, host),
				local_addr,
			},
			designator,
			advertised_host,
		})
	})();
	if opened.is_err() {
		let _ = lp.close_listener(listener);
	}
	opened
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::connect;
	use crate::{Argument, Host};
	use std::time::Duration;
	use tokio::sync::oneshot;
	use tokio::task::LocalSet;

	// `listen` hosts the same surface `connect` dials: a server accepts a
	// pancake dialer, publishes a capability on the accepted session, and the
	// dialer fetches and calls it, both ends riding the high-level Session,
	// nothing stitched by hand on either side.
	#[tokio::test]
	async fn listen_accepts_a_pancake_dialer_end_to_end() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				// The client must not fetch before the service is published, so
				// the host signals readiness over a oneshot.
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let session = server.accept().await.unwrap();
					session
						.publish("svc", |verb, args| {
							if verb != "greet" {
								return Err(format!("no such method: {verb}"));
							}
							let who = match args.first() {
								Some(Argument::String(s)) => s.as_str(),
								_ => "?",
							};
							Ok(Argument::String(format!("hello {who}")))
						})
						.unwrap();
					ready_tx.send(()).unwrap();
					session.serve().await;
				});

				let session = connect(
					&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
					None,
					None,
				)
				.await
				.unwrap();
				let advertised = session.partner_identity().unwrap();
				let expected_locator =
					crate::parse_locator(&crate::tcp_locator(&addr.ip().to_string(), addr.port()))
						.unwrap();
				let expected = crate::encode_peer_locator(&expected_locator).unwrap();
				assert_eq!(advertised.locator_record, expected);
				ready_rx.await.unwrap();
				let cap = session.fetch("svc").await.unwrap();
				let reply = session
					.send(&cap, "greet", &[Argument::String("pancake".into())])
					.await
					.unwrap();
				assert_eq!(reply, Argument::String("hello pancake".into()));
				session.close();
				host.await.unwrap();
			})
			.await;
	}

	// A rude TCP probe — connect, say nothing, hang up — is that connection's
	// failure, not the listener's: `accept` skips it internally and serves the
	// next, real client. Without that isolation one port scan takes a
	// long-lived server down.
	#[tokio::test]
	async fn a_rude_probe_cannot_close_the_listener() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let addr = server.local_addr().unwrap();

				// The probe: open a socket and immediately hang up, before the
				// host even accepts.
				let probe = tokio::net::TcpStream::connect(addr).await.unwrap();
				drop(probe);

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					// accept() consumes the probe internally (its handshake dies)
					// and returns the real client.
					let session = server.accept().await.unwrap();
					session
						.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
						.unwrap();
					ready_tx.send(()).unwrap();
					session.serve().await;
				});

				let session = connect(
					&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
					None,
					None,
				)
				.await
				.unwrap();
				ready_rx.await.unwrap();
				let cap = session.fetch("svc").await.unwrap();
				let reply = session.send(&cap, "ping", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("alive".into()));
				session.close();
				host.await.unwrap();
			})
			.await;
	}

	#[tokio::test]
	async fn listener_admission_bypasses_a_silent_peer_and_advertises_explicit_reachability() {
		let local = LocalSet::new();
		local
			.run_until(async {
				assert!(listen("0.0.0.0:0").await.is_err());

				let server = listen_with_options(
					"0.0.0.0:0",
					ListenOptions {
						advertised_host: Some("127.0.0.1".into()),
					},
				)
				.await
				.unwrap();
				let port = server.local_addr().unwrap().port();
				let silent = tokio::net::TcpStream::connect(("127.0.0.1", port))
					.await
					.unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let session = server.accept().await.unwrap();
					session
						.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
						.unwrap();
					ready_tx.send(()).unwrap();
					session.serve().await;
				});

				let session = tokio::time::timeout(
					Duration::from_secs(2),
					connect(&crate::tcp_locator("127.0.0.1", port), None, None),
				)
				.await
				.expect("a silent peer must not park the real handshake")
				.unwrap();
				ready_rx.await.unwrap();
				let identity = session.partner_identity().unwrap();
				assert_eq!(
					identity.designator,
					crate::uri::socket_addr_designator("127.0.0.1", port)
				);
				let cap = session.fetch("svc").await.unwrap();
				assert_eq!(
					session.send(&cap, "ping", &[]).await.unwrap(),
					Argument::Symbol("alive".into())
				);
				session.close();
				drop(silent);
				host.await.unwrap();
			})
			.await;
	}

	#[tokio::test]
	async fn closing_the_host_stops_listener_admission() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				server.host().close_async().await.unwrap();

				let result = tokio::time::timeout(Duration::from_secs(1), server.accept())
					.await
					.expect("Host close must wake a listener accept");
				assert!(
					result.is_err(),
					"a closed Host cannot admit another session"
				);
			})
			.await;
	}

	#[tokio::test]
	async fn closing_the_listener_preserves_a_yielded_session() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = Rc::new(listen("127.0.0.1:0").await.unwrap());
				let addr = server.local_addr().unwrap();
				let accepting = Rc::clone(&server);
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let session = accepting.accept().await.unwrap();
					session
						.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
						.unwrap();
					ready_tx.send(()).unwrap();
					session.serve().await;
				});

				let client = connect(
					&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
					None,
					None,
				)
				.await
				.unwrap();
				ready_rx.await.unwrap();
				server.close().unwrap();
				assert!(server.accept().await.is_err());

				let cap = client.fetch("svc").await.unwrap();
				assert_eq!(
					client.send(&cap, "ping", &[]).await.unwrap(),
					Argument::Symbol("alive".into())
				);
				client.close();
				host.await.unwrap();
			})
			.await;
	}

	#[tokio::test]
	async fn closing_a_supplied_listener_keeps_its_host_live() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let host = Host::from_seed([0x41; 32]).unwrap();
				let server = listen_with_host("127.0.0.1:0", host.clone()).await.unwrap();
				server.close().unwrap();

				// A second bind proves the first listener released only its native
				// listener handle. The supplied Host and its adopted loop remain the
				// authority for subsequent listeners.
				let sibling = listen_with_host("127.0.0.1:0", host.clone()).await.unwrap();
				sibling.close().unwrap();
				host.close_async().await.unwrap();
			})
			.await;
	}

	#[cfg(feature = "iroh")]
	#[tokio::test]
	async fn closing_iroh_listener_keeps_sibling_tcp_listener_usable() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let host = Host::from_seed([0x42; 32]).unwrap();
				let iroh = crate::listen_iroh_with_host(
					crate::IrohConfig::new(crate::Reachability::LocalDiscovery),
					host.clone(),
				)
				.await
				.unwrap();
				let tcp = Rc::new(listen_with_host("127.0.0.1:0", host.clone()).await.unwrap());
				let addr = tcp.local_addr().unwrap();
				let accepting = Rc::clone(&tcp);
				let accept_task = tokio::task::spawn_local(async move { accepting.accept().await });

				// Closing the sidecar-backed listener must not close the shared loop
				// or its unrelated TCP listener.
				iroh.close().unwrap();
				let client = connect(
					&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
					None,
					None,
				)
				.await
				.unwrap();
				let accepted = tokio::time::timeout(Duration::from_secs(2), accept_task)
					.await
					.expect("the sibling TCP listener must remain live")
					.unwrap()
					.unwrap();

				client.close();
				accepted.close();
				tcp.close().unwrap();
				host.close_async().await.unwrap();
			})
			.await;
	}
}
