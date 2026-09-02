//! The TCP-provider listen / accept surface: one [`Server`] across the `tcp`,
//! `keyed-tcp`, and `noise-tcp` profiles.
//!
//! Every application listener binds through the driver archive
//! (ADR-0112), including caller-supplied Hosts: a quiescent Host transfers to
//! the loop before its first network operation. The loop owns sockets,
//! admission, pumping, and session release. [`LoopListener`] is the one
//! binding owner of a generic driver listener. The driver's locator is the
//! server's sole metadata authority; profile-specific constructors do not mint
//! parallel server types or cache another rendering of it.

#[cfg(feature = "tcp")]
use crate::abi_constants::{HINT_DIRECT_ADDRESSES, TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_TCP, TRANSPORT_TCP};
#[cfg(feature = "tcp")]
use crate::host::Host;
#[cfg(feature = "tcp")]
use crate::server::LoopListener;
#[cfg(feature = "tcp")]
use crate::session::Session;
#[cfg(feature = "tcp")]
use crate::session_shared::io_err;
#[cfg(all(test, feature = "tcp"))]
use crate::ConnectOptions;
#[cfg(feature = "tcp")]
use crate::{ListenerIdentity, Result};
#[cfg(feature = "tcp")]
use std::rc::Rc;

/// A listening server, the host-side counterpart of [`crate::Runtime::connect`]. Call
/// [`Server::accept`] for each partner; every accepted [`Session`] shares the
/// server's one [`Host`] (its retained identity and handoff router), so
/// the server is one Host serving many partners.
///
/// A bare [`crate::tcp::listen`] rides the driver archive (ADR-0112), and its Host
/// owns the loop: `server.host().close(crate::PendingWork::Cancel).await` (or the last accepted session
/// dropping the Host) closes the listener and every loop-minted session with
/// it. On the byte-fed admission tier, dropping the server stops accepting
/// while live sessions are unaffected.
#[cfg(feature = "tcp")]
pub struct Server {
	listener: LoopListener,
}

/// Plain-TCP listener options. `advertised_host` is required for a wildcard
/// bind; `host` shares an existing capability identity and session directory.
#[cfg(feature = "tcp")]
#[derive(Default)]
pub struct ListenOptions {
	pub advertised_host: Option<String>,
	pub identity: ListenerIdentity,
	pub config: crate::tcp::Config,
}

/// Keyed and Noise TCP listener options. The identity is a sum rather than two
/// optional fields, so conflicting seed and Host authority is unrepresentable.
#[cfg(feature = "tcp")]
pub struct KeyedListenOptions {
	pub advertised_host: Option<String>,
	pub identity: ListenerIdentity,
	pub config: crate::tcp::Config,
}

#[cfg(feature = "tcp")]
impl Default for KeyedListenOptions {
	fn default() -> Self {
		Self {
			advertised_host: None,
			identity: ListenerIdentity::Fresh,
			config: crate::tcp::Config::default(),
		}
	}
}

#[cfg(feature = "tcp")]
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

	/// The canonical locator advertised by this server.
	pub fn locator(&self) -> Result<crate::Locator> {
		self.listener.locator()
	}

	/// The canonical `ocapn://` URI advertised by this server.
	pub fn uri(&self) -> Result<String> {
		crate::uri::format_locator_uri(&self.locator()?)
	}

	/// The bound port. This remains the physical listener's port when an
	/// advertised host replaces a wildcard bind address.
	pub fn port(&self) -> Result<u16> {
		let locator = self.locator()?;
		let direct = direct_address(&locator)?;
		Ok(crate::uri::designator_host_port(direct)?.1)
	}

	/// This server's [`Host`], one retained identity and session directory
	/// across every accepted session. Pass it to
	/// [`crate::RuntimeConfig::adopt_host`](crate::RuntimeConfig::adopt_host) so a capability fetched on a dialed
	/// session and returned to an accepted one shares one Host (the gifter
	/// half of a three-party handoff), and publish a Host-giftable on it with
	/// [`Host::publish_giftable`].
	pub fn host(&self) -> Host {
		self.listener.host()
	}

	/// Stop admitting partners. Sessions already returned by [`Server::accept`]
	/// remain live; close them individually or close the shared [`Host`].
	pub async fn close(&self) -> Result<()> {
		self.listener.close().await
	}
}

#[cfg(feature = "tcp")]
pub(crate) async fn listen(bind_host: &str, port: u16, options: ListenOptions) -> Result<Server> {
	let host = options.identity.into_host()?;
	listen_tcp_profile(
		bind_host,
		port,
		TRANSPORT_TCP,
		host,
		options.advertised_host,
		options.config,
	)
	.await
}

#[cfg(feature = "tcp")]
pub(crate) async fn listen_keyed(
	bind_host: &str,
	port: u16,
	transport: &'static str,
	options: KeyedListenOptions,
) -> Result<Server> {
	let host = options.identity.into_host()?;
	listen_tcp_profile(
		bind_host,
		port,
		transport,
		host,
		options.advertised_host,
		options.config,
	)
	.await
}

#[cfg(feature = "tcp")]
fn direct_address(locator: &crate::Locator) -> Result<&str> {
	match locator.transport.as_str() {
		TRANSPORT_TCP => Ok(&locator.designator),
		TRANSPORT_KEYED_TCP | TRANSPORT_NOISE_TCP => locator.string_hint(HINT_DIRECT_ADDRESSES)?.ok_or_else(|| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidData,
				format!(
					"the {} listener locator has no {HINT_DIRECT_ADDRESSES} hint",
					locator.transport
				),
			))
		}),
		transport => Err(io_err(std::io::Error::new(
			std::io::ErrorKind::InvalidData,
			format!("the TCP provider returned an unexpected {transport:?} locator"),
		))),
	}
}

#[cfg(feature = "tcp")]
fn advertised_direct_address(host: &str, port: u16) -> Result<String> {
	let bare = host
		.strip_prefix('[')
		.and_then(|value| value.strip_suffix(']'))
		.unwrap_or(host);
	if bare
		.parse::<std::net::IpAddr>()
		.is_ok_and(|address| address.is_unspecified())
	{
		return Err(io_err(std::io::Error::new(
			std::io::ErrorKind::InvalidInput,
			"an advertised host must be dialable",
		)));
	}
	Ok(crate::tcp::address_designator(bare, port))
}

#[cfg(feature = "tcp")]
async fn listen_tcp_profile(
	bind_host: &str,
	port: u16,
	transport: &'static str,
	host: Host,
	advertised_host: Option<String>,
	config: crate::tcp::Config,
) -> Result<Server> {
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
		crate::abi_constants::DRIVER_DEFAULT_HANDSHAKE_MS,
		crate::abi_constants::DRIVER_DEFAULT_SETTLE_MS,
	)?;
	crate::tcp::ensure_loop_provider(&lp, config)?;
	let listener = lp
		.listen(
			transport,
			&crate::tcp::address_designator(&bind.ip().to_string(), bind.port()),
		)
		.await?;
	let opened = (|| {
		let locator = lp.listener_locator(listener)?;
		let bound_direct = direct_address(&locator)?.to_owned();
		let bound: std::net::SocketAddr = bound_direct.parse().map_err(|_| {
			io_err(std::io::Error::new(
				std::io::ErrorKind::InvalidData,
				format!("the listener reported an unparsable direct address {bound_direct:?}"),
			))
		})?;
		let advertised_direct = match advertised_host.as_deref() {
			Some(value) => advertised_direct_address(value, bound.port())?,
			None if bound.ip().is_unspecified() => {
				return Err(io_err(std::io::Error::new(
					std::io::ErrorKind::InvalidInput,
					"a wildcard bind has no dialable address; provide an advertised host",
				)))
			}
			None => bound_direct.clone(),
		};
		if advertised_direct != bound_direct {
			let (designator, direct_hint) = if transport == TRANSPORT_TCP {
				(advertised_direct.as_str(), "")
			} else {
				(locator.designator.as_str(), advertised_direct.as_str())
			};
			let locator_uri = crate::uri::format_peer_locator(transport, designator, direct_hint)?;
			lp.advertise_listener(listener, &locator_uri)?;
		}
		lp.select_listener(listener)?;
		Ok(Server {
			listener: LoopListener::new(Rc::clone(&lp), listener, host),
		})
	})();
	match opened {
		Ok(server) => Ok(server),
		Err(error) => Err(crate::retain_cleanup_failure(error, lp.close_listener(listener).await)),
	}
}

#[cfg(all(test, feature = "tcp"))]
mod tests {
	use super::*;
	use crate::{Argument, Host};
	use std::time::Duration;
	use tokio::sync::oneshot;
	use tokio::task::LocalSet;

	async fn connect(locator: &crate::Locator, options: ConnectOptions<'_>) -> Result<Session> {
		let runtime = crate::Runtime::open(crate::RuntimeConfig::providers([crate::tcp::provider(
			Default::default(),
		)]))
		.await?;
		runtime.connect(locator, options).await
	}

	async fn listen(address: &str) -> Result<Server> {
		let (host, port) = crate::designator_host_port(address)?;
		super::listen(&host, port, ListenOptions::default()).await
	}

	async fn listen_with_host(address: &str, host: Host) -> Result<Server> {
		let (bind_host, port) = crate::designator_host_port(address)?;
		super::listen(
			&bind_host,
			port,
			ListenOptions {
				identity: ListenerIdentity::Host(host),
				..ListenOptions::default()
			},
		)
		.await
	}

	// `listen` hosts the same surface `connect` dials: a server accepts a
	// glowcap dialer, publishes a capability on the accepted session, and the
	// dialer fetches and calls it, both ends riding the high-level Session,
	// nothing stitched by hand on either side.
	#[tokio::test]
	async fn listen_accepts_a_glowcap_dialer_end_to_end() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = listen("127.0.0.1:0").await.unwrap();
				let uri = server.uri().unwrap();

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
					session.serve().await.unwrap();
				});

				let locator = crate::parse_locator(&uri).unwrap();
				let session = connect(&locator, ConnectOptions::default()).await.unwrap();
				assert_eq!(session.transport_name().unwrap(), "tcp");
				let profile = session.profile().unwrap();
				assert_eq!(profile.captp_version, crate::CaptpVersion::V1_0);
				assert_eq!(profile.codec, crate::Codec::Syrup);
				assert_eq!(
					profile.features.bits(),
					crate::FeatureSet::FULL.bits() & !crate::FeatureSet::MULTI_LOCATION.bits()
				);
				let advertised = session.partner_identity().unwrap();
				let expected = crate::encode_peer_locator(&locator).unwrap();
				assert_eq!(advertised.locator_record, expected);
				ready_rx.await.unwrap();
				let cap = session.fetch("svc").await.unwrap();
				let reply = session
					.send(&cap, "greet", &[Argument::String("glowcap".into())])
					.await
					.unwrap();
				assert_eq!(reply, Argument::String("hello glowcap".into()));
				session.close(crate::PendingWork::Cancel).await.unwrap();
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
				let port = server.port().unwrap();

				// The probe: open a socket and immediately hang up, before the
				// host even accepts.
				let probe = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
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
					session.serve().await.unwrap();
				});

				let session = connect(&crate::tcp::locator("127.0.0.1", port), ConnectOptions::default())
					.await
					.unwrap();
				ready_rx.await.unwrap();
				let cap = session.fetch("svc").await.unwrap();
				let reply = session.send(&cap, "ping", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("alive".into()));
				session.close(crate::PendingWork::Cancel).await.unwrap();
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

				let server = super::listen(
					"0.0.0.0",
					0,
					ListenOptions {
						advertised_host: Some("127.0.0.1".into()),
						..ListenOptions::default()
					},
				)
				.await
				.unwrap();
				let port = server.port().unwrap();
				let silent = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();

				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let session = server.accept().await.unwrap();
					session
						.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
						.unwrap();
					ready_tx.send(()).unwrap();
					session.serve().await.unwrap();
				});

				let session = tokio::time::timeout(
					Duration::from_secs(2),
					connect(&crate::tcp::locator("127.0.0.1", port), ConnectOptions::default()),
				)
				.await
				.expect("a silent peer must not park the real handshake")
				.unwrap();
				ready_rx.await.unwrap();
				let identity = session.partner_identity().unwrap();
				assert_eq!(identity.designator, crate::tcp::address_designator("127.0.0.1", port));
				let cap = session.fetch("svc").await.unwrap();
				assert_eq!(
					session.send(&cap, "ping", &[]).await.unwrap(),
					Argument::Symbol("alive".into())
				);
				session.close(crate::PendingWork::Cancel).await.unwrap();
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
				server.host().close(crate::PendingWork::Cancel).await.unwrap();

				let result = tokio::time::timeout(Duration::from_secs(1), server.accept())
					.await
					.expect("Host close must wake a listener accept");
				assert!(result.is_err(), "a closed Host cannot admit another session");
			})
			.await;
	}

	#[tokio::test]
	async fn closing_the_listener_preserves_a_yielded_session() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let server = Rc::new(listen("127.0.0.1:0").await.unwrap());
				let uri = server.uri().unwrap();
				let accepting = Rc::clone(&server);
				let (ready_tx, ready_rx) = oneshot::channel::<()>();
				let host = tokio::task::spawn_local(async move {
					let session = accepting.accept().await.unwrap();
					session
						.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
						.unwrap();
					ready_tx.send(()).unwrap();
					session.serve().await.unwrap();
				});

				let locator = crate::parse_locator(&uri).unwrap();
				let client = connect(&locator, ConnectOptions::default()).await.unwrap();
				ready_rx.await.unwrap();
				server.close().await.unwrap();
				assert!(server.accept().await.is_err());

				let cap = client.fetch("svc").await.unwrap();
				assert_eq!(
					client.send(&cap, "ping", &[]).await.unwrap(),
					Argument::Symbol("alive".into())
				);
				client.close(crate::PendingWork::Cancel).await.unwrap();
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
				server.close().await.unwrap();

				// A second bind proves the first listener released only its native
				// listener handle. The supplied Host and its adopted loop remain the
				// authority for subsequent listeners.
				let sibling = listen_with_host("127.0.0.1:0", host.clone()).await.unwrap();
				sibling.close().await.unwrap();
				host.close(crate::PendingWork::Cancel).await.unwrap();
			})
			.await;
	}

	#[tokio::test]
	async fn keyed_and_noise_listeners_adopt_the_supplied_host_and_share_server_metadata() {
		let local = LocalSet::new();
		local
			.run_until(async {
				let host = Host::from_seed([0x43; 32]).unwrap();
				for server in [
					super::listen_keyed(
						"127.0.0.1",
						0,
						TRANSPORT_KEYED_TCP,
						KeyedListenOptions {
							identity: ListenerIdentity::Host(host.clone()),
							..KeyedListenOptions::default()
						},
					)
					.await
					.unwrap(),
					super::listen_keyed(
						"127.0.0.1",
						0,
						TRANSPORT_NOISE_TCP,
						KeyedListenOptions {
							identity: ListenerIdentity::Host(host.clone()),
							..KeyedListenOptions::default()
						},
					)
					.await
					.unwrap(),
				] {
					assert!(Rc::ptr_eq(&server.host().shared(), &host.shared()));
					let locator = server.locator().unwrap();
					assert_eq!(crate::parse_locator(&server.uri().unwrap()).unwrap(), locator);
					assert_ne!(server.port().unwrap(), 0);
					server.close().await.unwrap();
				}
				host.close(crate::PendingWork::Cancel).await.unwrap();
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
				let iroh = crate::iroh::listen(
					crate::iroh::Config::new(crate::iroh::Reachability::LocalDiscovery),
					crate::iroh::ListenOptions {
						identity: crate::ListenerIdentity::Host(host.clone()),
					},
				)
				.await
				.unwrap();
				let tcp = Rc::new(listen_with_host("127.0.0.1:0", host.clone()).await.unwrap());
				let locator = tcp.locator().unwrap();
				let accepting = Rc::clone(&tcp);
				let accept_task = tokio::task::spawn_local(async move { accepting.accept().await });

				// Closing the sidecar-backed listener must not close the shared loop
				// or its unrelated TCP listener.
				iroh.close().await.unwrap();
				let client = connect(&locator, ConnectOptions::default()).await.unwrap();
				let accepted = tokio::time::timeout(Duration::from_secs(2), accept_task)
					.await
					.expect("the sibling TCP listener must remain live")
					.unwrap()
					.unwrap();

				client.close(crate::PendingWork::Cancel).await.unwrap();
				accepted.close(crate::PendingWork::Cancel).await.unwrap();
				tcp.close().await.unwrap();
				host.close(crate::PendingWork::Cancel).await.unwrap();
			})
			.await;
	}
}
