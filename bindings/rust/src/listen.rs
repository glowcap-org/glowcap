//! The listen / accept surface (binding spine Pass 3d): [`Server`],
//! [`KeyedTcpServer`], and the top-level [`listen`] / [`listen_keyed_tcp`]
//! hosters. Session owns mint/handshake (`establish_accepted`); this module
//! owns the listening socket, accept loop, and self-designator bind. iroh
//! hosting lives in [`crate::iroh`], not here.

use tokio::net::{TcpListener, ToSocketAddrs};

use crate::host::Host;
use crate::session::{io_err, Session};
use crate::Result;

/// A listening server, the host-side counterpart of [`crate::connect`]. Call
/// [`Server::accept`] for each partner; every accepted [`Session`] shares the
/// server's one [`Host`] (its retained identity and gift registry), so
/// the server is one Host serving many partners. Dropping the server stops
/// accepting; live sessions are unaffected.
pub struct Server {
	listener: TcpListener,
	host: Host,
}

impl Server {
	/// Accept the next partner as a ready [`Session`], sharing this server's
	/// [`Host`]. The keyed handshake completes before this resolves; a
	/// partner that fails it — a rude probe that connects and hangs up, or a
	/// stray port scan — is that session's failure, never the listener's, so
	/// the accept skips it and keeps serving. Must be called inside a `LocalSet`
	/// (the handle graph is `!Send`).
	pub async fn accept(&self) -> Result<Session> {
		loop {
			let (stream, _) = self.listener.accept().await.map_err(io_err)?;
			let designator = match stream.local_addr() {
				Ok(addr) => crate::uri::socket_addr_designator(&addr.ip().to_string(), addr.port()),
				Err(_) => crate::uri::socket_addr_designator("127.0.0.1", 0),
			};
			match Session::establish_accepted(
				self.host.shared(),
				crate::abi_constants::TRANSPORT_TCP,
				&designator,
				stream,
				"",
			)
			.await
			{
				Ok(conn) => return Ok(conn),
				Err(_) => continue,
			}
		}
	}

	/// The bound local address, read the port off it when you bound port 0.
	pub fn local_addr(&self) -> Result<std::net::SocketAddr> {
		self.listener.local_addr().map_err(io_err)
	}

	/// This server's [`Host`], one retained identity and gift registry
	/// across every accepted session. Pass it to
	/// [`crate::connect`] as `Some(server.host())` so a capability fetched on a dialed
	/// session and returned to an accepted one shares one Host (the gifter
	/// half of a three-party handoff), and publish a Host-giftable on it with
	/// [`Host::publish_giftable`].
	pub fn host(&self) -> Host {
		self.host.clone()
	}
}

/// Bind `addr` and return a [`Server`] to [`accept`](Server::accept) partners
/// on, the host-side counterpart of [`crate::connect`]. The server is one Host with a
/// fresh retained identity shared across every accepted session.
pub async fn listen<A: ToSocketAddrs>(addr: A) -> Result<Server> {
	listen_with_host(addr, Host::new_host()).await
}

/// [`listen`] on a caller-supplied Host — how a server shares one identity and
/// gift registry with sessions it dials (the gifter half of a three-party
/// handoff), or speaks a non-default codec ([`Host::with_codec`]).
pub async fn listen_with_host<A: ToSocketAddrs>(addr: A, host: Host) -> Result<Server> {
	let listener = TcpListener::bind(addr).await.map_err(io_err)?;
	// This Host also dials (the gifter side of a handoff), and its dials sign
	// the listener's own address so a partner's crossed-hellos table can
	// recognize it.
	if let Ok(local) = listener.local_addr() {
		let designator = crate::uri::socket_addr_designator(&local.ip().to_string(), local.port());
		let _ = host.shared().set_self_designator(&designator);
	}
	Ok(Server { listener, host })
}

/// A keyed-tcp listening server: TCP sockets under a durable key designator
/// (ADR-0075). The Host's Ed25519 identity *is* the locator designator and the
/// session signing key — one seed, not a second minted identity. Build one with
/// [`listen_keyed_tcp`].
pub struct KeyedTcpServer {
	listener: TcpListener,
	host: Host,
	designator: String,
}

impl KeyedTcpServer {
	/// Accept the next partner as a ready [`Session`], signing this Host's
	/// key designator with the bound address riding the `direct-addresses` hint.
	pub async fn accept(&self) -> Result<Session> {
		loop {
			let (stream, _) = self.listener.accept().await.map_err(io_err)?;
			let hint = match stream.local_addr() {
				Ok(addr) => crate::uri::socket_addr_designator(&addr.ip().to_string(), addr.port()),
				Err(_) => crate::uri::socket_addr_designator("127.0.0.1", 0),
			};
			match Session::establish_accepted(
				self.host.shared(),
				crate::abi_constants::TRANSPORT_KEYED_TCP,
				&self.designator,
				stream,
				&hint,
			)
			.await
			{
				Ok(conn) => return Ok(conn),
				Err(_) => continue,
			}
		}
	}

	/// The bound local address; read the port off it when you bound port 0.
	pub fn local_addr(&self) -> Result<std::net::SocketAddr> {
		self.listener.local_addr().map_err(io_err)
	}

	/// This server's Host — one retained identity and gift registry across every
	/// accepted session. The identity seed is the keyed-tcp designator.
	pub fn host(&self) -> Host {
		self.host.clone()
	}

	/// The key designator this server signs (64 lowercase hex digits).
	pub fn designator(&self) -> &str {
		&self.designator
	}

	/// The `ocapn://<key>.keyed-tcp?direct-addresses=<bound>` URI a partner dials.
	pub fn uri(&self) -> Result<String> {
		let addr = self.local_addr()?;
		Ok(crate::uri::keyed_tcp_locator(
			&self.designator,
			&addr.ip().to_string(),
			addr.port(),
		))
	}
}

/// Bind `bind_host`:`port` as a keyed-tcp listener whose designator is the public
/// half of `seed` (or a fresh random seed when `None`). The Host identity, the
/// locator designator, and the session signing key are one value — pass the
/// same seed after a restart to keep the designator stable (ADR-0075).
pub async fn listen_keyed_tcp(
	bind_host: &str,
	port: u16,
	seed: Option<[u8; 32]>,
) -> Result<KeyedTcpServer> {
	let host = match seed {
		Some(s) => Host::from_seed(s)?,
		None => Host::new_host(),
	};
	let designator = host.designator()?;
	let listener = TcpListener::bind((bind_host, port)).await.map_err(io_err)?;
	host.shared().set_self_designator(&designator)?;
	Ok(KeyedTcpServer {
		listener,
		host,
		designator,
	})
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::connect;
	use crate::Argument;
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
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |verb, args| {
						if verb != "greet" {
							return Err(format!("no such method: {verb}"));
						}
						let who = match args.first() {
							Some(Argument::String(s)) => s.as_str(),
							_ => "?",
						};
						Ok(Argument::String(format!("hello {who}")))
					})
					.await
					.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = connect(
					&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
					None,
					None,
				)
				.await
				.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let reply = conn
					.send(&cap, "greet", &[Argument::String("pancake".into())])
					.await
					.unwrap();
				assert_eq!(reply, Argument::String("hello pancake".into()));
				conn.close();
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
					let conn = server.accept().await.unwrap();
					conn.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
						.await
						.unwrap();
					ready_tx.send(()).unwrap();
					conn.serve().await;
				});

				let conn = connect(
					&crate::tcp_locator(&addr.ip().to_string(), addr.port()),
					None,
					None,
				)
				.await
				.unwrap();
				ready_rx.await.unwrap();
				let cap = conn.fetch("svc").await.unwrap();
				let reply = conn.send(&cap, "ping", &[]).await.unwrap();
				assert_eq!(reply, Argument::Symbol("alive".into()));
				conn.close();
				host.await.unwrap();
			})
			.await;
	}
}
