//! Connection: the application surface over tokio (the `async` feature).
//!
//! This is what an application holds. It composes a peer, a vat, and the tokio
//! I/O driver into one object, so a consumer never stitches those three together
//! by hand. The verbs — [`connect`] to dial, [`listen`]/[`Server::accept`] to
//! host, [`Connection::fetch`]/[`Connection::publish`], [`Connection::spawn`],
//! [`Connection::send`], [`Connection::serve`], [`Connection::close`] — are the
//! whole common surface.
//!
//! The pancake [`Peer`](crate::Peer) is a single-owner, `!Send` state machine, so
//! a `Connection` owns it on one background task and the handle talks to that task
//! over channels. The handle is therefore `!Send` too — create and use it on one
//! task, inside a `LocalSet` (or `#[tokio::main(flavor = "current_thread")]`). This
//! is the honest shape for a `!Send` resource: it is not hidden, and the channel
//! plumbing lives here so an application never writes it.

use std::cell::Cell;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite};
use tokio::net::{TcpListener, TcpStream, ToSocketAddrs};
use tokio::sync::{mpsc, oneshot};

use crate::actors::{Behavior, Promise, Ref as VatRef, Vat};
use crate::wire;
use crate::{sys, Argument, Error, Peer, Reference, Resolution, Result};

/// A capability — a reference to an object you can `send` to, wherever it lives.
///
/// You get a `Ref` from [`Connection::spawn`] (a local actor you host),
/// [`Connection::fetch`] (a capability a partner published), or a capability a
/// partner handed back from a `send` (lift it with `Ref::try_from(&arg)`). Pass
/// one as a `send` argument via `Into<Argument>` (`(&cap).into()`) and it
/// marshals to the right wire reference; you never build `near`/`far` references
/// by hand.
#[derive(Debug, Clone)]
pub struct Ref {
    reference: Reference,
}

impl Ref {
    /// The underlying wire reference (for the rare power-user path).
    pub fn reference(&self) -> Reference {
        self.reference.clone()
    }
}

impl From<&Ref> for Argument {
    fn from(r: &Ref) -> Argument {
        Argument::Reference(r.reference.clone())
    }
}

impl From<Ref> for Argument {
    fn from(r: Ref) -> Argument {
        Argument::Reference(r.reference)
    }
}

impl TryFrom<&Argument> for Ref {
    type Error = ();

    /// Lift a capability returned by a `send` (an `Argument::Reference`) back into
    /// a `Ref` you can `send` to — e.g. a capability a coordinator granted you.
    fn try_from(arg: &Argument) -> std::result::Result<Ref, ()> {
        match arg {
            Argument::Reference(reference) => Ok(Ref { reference: reference.clone() }),
            _ => Err(()),
        }
    }
}

// A command's reply carries the typed [`Error`] end to end: a partner break is
// `Error::broken` with the reason, and a local refusal (e.g. an inadmissible
// send target) keeps its own session/codec code instead of being laundered
// into a transport error.
type Reply<T> = oneshot::Sender<Result<T>>;

enum Cmd {
    Spawn { behavior: Behavior, reply: Reply<u64> },
    Publish { name: String, behavior: Behavior, reply: Reply<u64> },
    Fetch { name: String, reply: Reply<Reference> },
    Send { target: Reference, verb: String, args: Vec<Argument>, reply: Reply<Argument> },
    Tell { target: Reference, verb: String, args: Vec<Argument> },
    Close,
}

/// A live connection to one OCapN partner — the one object an application holds.
/// `!Send` by construction (it owns a `!Send` peer on a background task); use it
/// on a single task inside a `LocalSet`.
pub struct Connection {
    cmd_tx: mpsc::UnboundedSender<Cmd>,
    driver: Cell<Option<tokio::task::JoinHandle<()>>>,
}

impl Connection {
    /// Dial `addr` and return a ready connection, spawning its driver task.
    /// Must be called inside a `LocalSet` (the peer is `!Send`).
    pub async fn connect<A: ToSocketAddrs>(addr: A) -> Result<Connection> {
        let stream = TcpStream::connect(addr).await.map_err(|_| Error::from_code(sys::ERR_IO))?;
        let designator = stream.local_addr().map(|a| a.to_string()).unwrap_or_else(|_| "127.0.0.1:0".to_string());
        Ok(Connection::over(stream, "tcp", designator))
    }

    /// Wrap an already-connected stream, spawning the driver task that completes
    /// the keyed handshake and then serves commands. The exchange is symmetric —
    /// both ends send `op:start-session` first, then read — so the same driver
    /// serves a dialed and an accepted stream. Generic over the stream so the
    /// identical driver carries the peer over TCP or over the iroh sidecar bridge
    /// ([`crate::iroh::IrohStream`]); `transport`/`designator` are what this side
    /// signs into its keyed `op:start-session` location (`tcp` + `host:port`, or
    /// `iroh` + the endpoint-id locator).
    fn over<S>(stream: S, transport: &str, designator: String) -> Connection
    where
        S: AsyncRead + AsyncWrite + Unpin + 'static,
    {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let transport = transport.to_string();
        let driver = tokio::task::spawn_local(async move {
            let _ = drive(stream, &transport, &designator, cmd_rx).await;
        });
        Connection {
            cmd_tx,
            driver: Cell::new(Some(driver)),
        }
    }

    /// Spawn a local actor and return a capability to it. Pass the returned `Ref`
    /// as a `send` argument to hand a partner a callback. The position comes from
    /// the session's one export allocator (on the driver task, hence the await),
    /// so it can never alias a bootstrap or resolver export.
    pub async fn spawn(
        &self,
        behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
    ) -> Result<Ref> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(Cmd::Spawn { behavior: Box::new(behavior), reply: tx })
            .map_err(|_| Error::from_code(sys::ERR_IO))?;
        let position = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
        Ok(Ref { reference: Reference::Near { id: position, promise: false } })
    }

    /// Publish an actor so a partner can [`fetch`](Connection::fetch) it by `name`
    /// (a swiss-number). Returns a capability to it.
    pub async fn publish(
        &self,
        name: &str,
        behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
    ) -> Result<Ref> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(Cmd::Publish { name: name.to_string(), behavior: Box::new(behavior), reply: tx })
            .map_err(|_| Error::from_code(sys::ERR_IO))?;
        let position = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
        Ok(Ref { reference: Reference::Near { id: position, promise: false } })
    }

    /// Fetch a partner's published capability by `name`. Requires
    /// [`serve`](Connection::serve) to be running so the resolution arrives.
    pub async fn fetch(&self, name: &str) -> Result<Ref> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(Cmd::Fetch { name: name.to_string(), reply: tx })
            .map_err(|_| Error::from_code(sys::ERR_IO))?;
        let reference = rx.await.map_err(|_| Error::from_code(sys::ERR_IO))??;
        Ok(Ref { reference })
    }

    /// Call `verb(args)` on the capability `target` and await the reply. `args`
    /// may contain capabilities via `Into<Argument>`. Errors if the partner
    /// breaks the call.
    pub async fn send(&self, target: &Ref, verb: &str, args: &[Argument]) -> Result<Argument> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(Cmd::Send {
                target: target.reference.clone(),
                verb: verb.to_string(),
                args: args.to_vec(),
                reply: tx,
            })
            .map_err(|_| Error::from_code(sys::ERR_IO))?;
        match rx.await {
            // The driver replied: the value, or the typed reason — a partner
            // break carries `ERR_BROKEN` with the partner's words; a local
            // refusal keeps its own code.
            Ok(out) => out,
            Err(_) => Err(Error::from_code(sys::ERR_IO)),
        }
    }

    /// Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and
    /// no reply comes back, so a notification or broadcast costs one deliver
    /// rather than a deliver plus a reply.
    pub fn tell(&self, target: &Ref, verb: &str, args: &[Argument]) -> Result<()> {
        self.cmd_tx
            .send(Cmd::Tell {
                target: target.reference.clone(),
                verb: verb.to_string(),
                args: args.to_vec(),
            })
            .map_err(|_| Error::from_code(sys::ERR_IO))
    }

    /// Run the inbound event loop in the background (it already runs from
    /// `connect`); the returned future completes when the connection closes.
    /// Calling it without awaiting is fine — the driver runs regardless.
    pub fn serve(&self) -> impl std::future::Future<Output = ()> {
        let handle = self.driver.take();
        async move {
            if let Some(h) = handle {
                let _ = h.await;
            }
        }
    }

    /// Close the connection; a running [`serve`](Connection::serve) completes.
    pub fn close(&self) {
        let _ = self.cmd_tx.send(Cmd::Close);
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        let _ = self.cmd_tx.send(Cmd::Close);
    }
}

/// Dial `addr` and return a ready connection — the module-level shorthand for
/// [`Connection::connect`].
pub async fn connect<A: ToSocketAddrs>(addr: A) -> Result<Connection> {
    Connection::connect(addr).await
}

/// A listening server — the host-side counterpart of [`connect`]. Call
/// [`Server::accept`] for each partner; every accepted [`Connection`] gets its
/// own peer, vat, and driver task. Dropping the server stops accepting; live
/// connections are unaffected.
pub struct Server {
    listener: TcpListener,
}

impl Server {
    /// Accept the next partner as a ready [`Connection`]. The keyed handshake
    /// runs first on the connection's driver task, so commands issued on the
    /// returned handle wait until the session is open. Must be called inside a
    /// `LocalSet` (the peer is `!Send`).
    pub async fn accept(&self) -> Result<Connection> {
        let (stream, _) = self.listener.accept().await.map_err(|_| Error::from_code(sys::ERR_IO))?;
        let designator = stream.local_addr().map(|a| a.to_string()).unwrap_or_else(|_| "127.0.0.1:0".to_string());
        Ok(Connection::over(stream, "tcp", designator))
    }

    /// The bound local address — read the port off it when you bound port 0.
    pub fn local_addr(&self) -> Result<std::net::SocketAddr> {
        self.listener.local_addr().map_err(|_| Error::from_code(sys::ERR_IO))
    }
}

/// Bind `addr` and return a [`Server`] to [`accept`](Server::accept) partners
/// on — the host-side counterpart of [`connect`].
pub async fn listen<A: ToSocketAddrs>(addr: A) -> Result<Server> {
    let listener = TcpListener::bind(addr).await.map_err(|_| Error::from_code(sys::ERR_IO))?;
    Ok(Server { listener })
}

// ── iroh transport (the `iroh` feature) ──────────────────────────────────────
// The same Connection surface over iroh's encrypted QUIC: `connect_iroh` dials a
// partner by endpoint id + direct-address hints (or its published `ocapn://` URI),
// and `IrohServer` hosts. The driver is unchanged — `Connection::over` carries the
// peer over the iroh byte-stream bridge exactly as over a `TcpStream`; only the
// signed locator differs (`iroh` + endpoint id, never `tcp` + host:port).

#[cfg(feature = "iroh")]
impl Connection {
    /// Dial an iroh partner by endpoint id and direct-address hints, complete the
    /// keyed OCapN handshake over the encrypted-QUIC transport, and return a ready
    /// connection — the iroh sibling of [`connect`]. The local endpoint is
    /// ephemeral (a fresh key), created with the caller's chosen `reachability`
    /// (the mandatory posture, no default), and released with the connection.
    /// Needs the iroh ABI library (`zig build iroh-abi`).
    pub async fn connect_iroh(
        node_id: &str,
        direct_addresses: &str,
        reachability: crate::iroh::Reachability,
    ) -> Result<Connection> {
        let stream = crate::iroh::IrohStream::connect(node_id, direct_addresses, reachability).await?;
        // A dialer signs an empty designator (its identity is the session key),
        // matching the Zig driver and the other bindings.
        Ok(Connection::over(stream, "iroh", String::new()))
    }
}

/// A listening iroh endpoint — the iroh sibling of [`Server`]. Call
/// [`IrohServer::accept`] for each partner; read [`IrohServer::uri`] for the
/// dialable address to hand a client. Needs the iroh ABI library.
#[cfg(feature = "iroh")]
pub struct IrohServer {
    inner: crate::iroh::IrohServer,
}

#[cfg(feature = "iroh")]
impl IrohServer {
    /// This endpoint's id — the keyed locator designator and the URI host.
    pub fn node_id(&self) -> &str {
        self.inner.node_id()
    }

    /// This endpoint's comma-separated direct-address hints.
    pub fn direct_addresses(&self) -> Result<String> {
        self.inner.direct_addresses()
    }

    /// The `ocapn://<nodeid>.iroh?direct-addresses=…` URI a partner dials.
    pub fn uri(&self) -> Result<String> {
        self.inner.uri()
    }

    /// Accept the next partner as a ready [`Connection`], completing the responder
    /// handshake and signing this endpoint's id as the locator designator.
    pub async fn accept(&self) -> Result<Connection> {
        let node_id = self.inner.node_id().to_string();
        let stream = self.inner.accept().await?;
        Ok(Connection::over(stream, "iroh", node_id))
    }

    /// Stop accepting and release the endpoint.
    pub fn close(&self) {
        self.inner.close();
    }
}

/// Bind an iroh endpoint and return an [`IrohServer`] to accept partners on — the
/// iroh sibling of [`listen`]. `reachability` is the mandatory posture (no
/// default). Needs the iroh ABI library (`zig build iroh-abi`).
#[cfg(feature = "iroh")]
pub fn listen_iroh(reachability: crate::iroh::Reachability) -> Result<IrohServer> {
    Ok(IrohServer { inner: crate::iroh::IrohServer::bind(reachability)? })
}

/// Dial an iroh partner by endpoint id and direct-address hints — the module-level
/// shorthand for [`Connection::connect_iroh`]. `reachability` is the mandatory
/// posture (no default).
#[cfg(feature = "iroh")]
pub async fn connect_iroh(
    node_id: &str,
    direct_addresses: &str,
    reachability: crate::iroh::Reachability,
) -> Result<Connection> {
    Connection::connect_iroh(node_id, direct_addresses, reachability).await
}

/// Dial a partner from its published `ocapn://` URI, dispatching on the
/// locator's transport: `iroh` dials the endpoint id with its `direct-addresses`
/// hints under the caller's chosen `reachability`, `tcp` dials the `host:port`
/// designator (reachability does not apply). The transport-agnostic entry point
/// — parse once through the core grammar, which picks the netlayer. The iroh
/// posture is mandatory (no default), so this build requires it.
#[cfg(feature = "iroh")]
pub async fn connect_uri(uri: &str, reachability: crate::iroh::Reachability) -> Result<Connection> {
    let loc = crate::uri::parse_locator(uri)?;
    match loc.transport.as_str() {
        "iroh" => {
            let addrs = loc.hints.get("direct-addresses").map(String::as_str).unwrap_or("");
            Connection::connect_iroh(&loc.designator, addrs, reachability).await
        }
        "tcp" => Connection::connect(loc.designator.as_str()).await,
        other => Err(crate::Error::with_detail(
            crate::sys::ERR_INVALID_ARGUMENT,
            format!("connect_uri: unsupported transport \"{other}\""),
        )),
    }
}

/// Dial a partner from its published `ocapn://` URI — the transport-agnostic
/// entry point. Without the iroh transport only `tcp` is dialable; an `iroh`
/// locator errors with the rebuild hint.
#[cfg(all(feature = "async", not(feature = "iroh")))]
pub async fn connect_uri(uri: &str) -> Result<Connection> {
    let loc = crate::uri::parse_locator(uri)?;
    match loc.transport.as_str() {
        "tcp" => Connection::connect(loc.designator.as_str()).await,
        other => Err(crate::Error::with_detail(
            crate::sys::ERR_INVALID_ARGUMENT,
            format!("connect_uri: unsupported transport \"{other}\" (rebuild with the iroh feature to dial iroh)"),
        )),
    }
}

/// Dial an iroh partner from its published `ocapn://<nodeid>.iroh?…` URI — a thin
/// wrapper over the transport-dispatching [`connect_uri`]. `reachability` is the
/// mandatory posture (no default).
#[cfg(feature = "iroh")]
pub async fn connect_iroh_uri(uri: &str, reachability: crate::iroh::Reachability) -> Result<Connection> {
    connect_uri(uri, reachability).await
}

async fn drive<S>(
    mut stream: S,
    transport: &str,
    designator: &str,
    mut cmd_rx: mpsc::UnboundedReceiver<Cmd>,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut peer = Peer::new()?;
    let mut inbox: Vec<u8> = Vec::new();
    let mut chunk = [0u8; wire::READ_CHUNK];

    // Establish the OCapN session before serving any command: the driver task
    // runs this first, so a `fetch`/`send` queued by the handle waits in the
    // channel until the keyed handshake has opened the session.
    wire::handshake(&mut peer, &mut stream, transport, designator, &mut inbox, &mut chunk).await?;

    let mut vat = Vat::over(&mut peer);
    let served = serve_loop(&mut vat, &mut stream, &mut cmd_rx, &mut inbox, &mut chunk).await;
    // The wire is gone — cleanly or by a transport fault: break every send still
    // awaiting a reply so it settles as a break with the reason, matching the
    // other bindings, rather than leaving its oneshot to drop into a bare
    // transport error. This runs on every exit path out of the loop.
    vat.break_far_vows("connection closed");
    served
}

// The driver task's main loop. Only a genuine wire fault (a failed read, write,
// or peer-fatal inbound frame) ends it; a failed command settles its own
// oneshot inside `handle` and the loop keeps serving.
async fn serve_loop<S>(
    vat: &mut Vat<'_>,
    stream: &mut S,
    cmd_rx: &mut mpsc::UnboundedReceiver<Cmd>,
    inbox: &mut Vec<u8>,
    chunk: &mut [u8],
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    loop {
        tokio::select! {
            biased;
            maybe = cmd_rx.recv() => {
                match maybe {
                    None | Some(Cmd::Close) => return Ok(()),
                    Some(cmd) => handle(vat, stream, cmd).await?,
                }
            }
            read = stream.read(&mut *chunk) => {
                let n = read.map_err(wire::io_err)?;
                if n == 0 { return Ok(()); }
                inbox.extend_from_slice(&chunk[..n]);
                {
                    let peer = vat.peer().expect("a peer-bound vat");
                    while let Some(consumed) = peer.recv_stream(inbox)? {
                        inbox.drain(..consumed);
                    }
                }
                loop {
                    let event = vat.peer().expect("a peer-bound vat").poll()?;
                    match event {
                        Some(event) => { vat.serve(&event).ok(); }
                        None => break,
                    }
                }
                flush(vat, stream).await?;
            }
        }
    }
}

// Serve one command. An application-level failure (a refused publish, an
// inadmissible send target, a failed export allocation) replies its typed
// error on that command's own oneshot and leaves the driver alive; `?` is
// reserved for transport faults, which end the loop so `drive` can break the
// remaining vows.
async fn handle<S>(vat: &mut Vat<'_>, stream: &mut S, cmd: Cmd) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    match cmd {
        Cmd::Spawn { behavior, reply } => {
            let allocated = vat.peer().expect("a peer-bound vat").next_export();
            let out = allocated.and_then(|position| vat.publish(position, behavior).map(|_| position));
            let _ = reply.send(out);
        }
        Cmd::Publish { name, behavior, reply } => {
            let allocated = vat.peer().expect("a peer-bound vat").register_bootstrap_cap(name.as_bytes());
            let out = allocated.and_then(|position| vat.publish(position, behavior).map(|_| position));
            let _ = reply.send(out);
        }
        Cmd::Fetch { name, reply } => {
            // The canonical fetch lives in the library: one call registers the
            // bootstrap import, allocates the answer, and queues the deliver.
            let sent = vat
                .peer()
                .expect("a peer-bound vat")
                .send_bootstrap_fetch(name.as_bytes())
                .map(Promise::Far);
            match sent {
                Ok(vow) => {
                    vat.on(vow, move |resolution| {
                        let out = match resolution {
                            Resolution::Fulfill(Argument::Reference(reference)) => Ok(reference),
                            // The partner fulfilled with a non-capability: a
                            // typed broken failure carrying the fetched name,
                            // distinct from a transport fault.
                            Resolution::Fulfill(_) => {
                                Err(Error::broken(format!("fetch {name:?} did not resolve to a capability")))
                            }
                            Resolution::Break(message) => Err(Error::broken(message)),
                        };
                        let _ = reply.send(out);
                    });
                    flush(vat, stream).await?;
                }
                Err(e) => {
                    let _ = reply.send(Err(e));
                }
            }
        }
        Cmd::Send { target, verb, args, reply } => {
            // Route a self-spawned target to its local actor; a partner's ref
            // stays far. A local send queues a turn that the driver runs
            // in-process (firing the listener), so it resolves without a wire
            // round-trip.
            let vref = vat.resolve_target(&target);
            let is_local = matches!(vref, VatRef::Local(_));
            match vat.send(&vref, &verb, &args) {
                Ok(vow) => {
                    vat.on(vow, move |resolution| {
                        let out = match resolution {
                            Resolution::Fulfill(value) => Ok(value),
                            Resolution::Break(message) => Err(Error::broken(message)),
                        };
                        let _ = reply.send(out);
                    });
                    if is_local {
                        vat.drive();
                    } else {
                        flush(vat, stream).await?;
                    }
                }
                Err(e) => {
                    let _ = reply.send(Err(e));
                }
            }
        }
        Cmd::Tell { target, verb, args } => {
            let vref = vat.resolve_target(&target);
            if let VatRef::Local(_) = vref {
                // A self-spawned target: run the turn in-process, no reply.
                let _ = vat.send(&vref, &verb, &args);
                vat.drive();
            } else {
                // A far fire-and-forget deliver: prepend the verb symbol (skipped
                // when empty, matching `Vat::send` and the other bindings — a
                // positional tell must not put a stray empty symbol on the wire),
                // request no answer, and flush. The partner's actor runs but
                // sends no reply. A refused deliver has no reply to land on —
                // that is the fire-and-forget contract — so a typed refusal is
                // dropped here rather than allowed to kill the driver.
                let mut payload = Vec::with_capacity(args.len() + 1);
                if !verb.is_empty() {
                    payload.push(Argument::Symbol(verb));
                }
                payload.extend(args);
                if vat.peer().expect("a peer-bound vat").send_deliver(&target, &payload, None).is_ok() {
                    flush(vat, stream).await?;
                }
            }
        }
        Cmd::Close => {}
    }
    Ok(())
}

async fn flush<S>(vat: &mut Vat<'_>, stream: &mut S) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    wire::pump_outbound(vat.peer().expect("a peer-bound vat"), stream).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AsyncConnection, Event};
    use tokio::task::LocalSet;

    // `listen` hosts the same surface `connect` dials: a server accepts a
    // pancake dialer, publishes a capability on the accepted connection, and the
    // dialer fetches and calls it — both ends riding the high-level Connection,
    // no peer or vat stitched by hand on either side.
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

                let conn = Connection::connect(addr).await.unwrap();
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

    // A broken `send` carries the partner's reason, not just a code: the partner
    // publishes a cap, the client fetches and calls it, and the partner breaks
    // the call with a reason the client must read back off the error.
    #[tokio::test]
    async fn send_surfaces_the_partner_break_reason() {
        let local = LocalSet::new();
        local
            .run_until(async {
                let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
                let addr = listener.local_addr().unwrap();

                // Server: a default negotiating peer that publishes a bootstrap
                // cap. The engine auto-answers the `fetch`; the server breaks
                // the `do` call that follows, with a reason the client must read
                // back.
                let server = tokio::task::spawn_local(async move {
                    let (stream, _) = listener.accept().await.unwrap();
                    let mut peer = Peer::new().unwrap();
                    peer.register_bootstrap_cap(b"svc").unwrap();
                    // Responder half of the keyed handshake (a fixed seed is fine
                    // in a test): the client's `Connection::connect` handshakes,
                    // so the server must too or it would refuse the start-session.
                    peer.start_session(&[7u8; 32], "tcp", "127.0.0.1:2", true).unwrap();
                    let mut conn = AsyncConnection::from_stream(peer, stream);
                    while !conn.peer().session_is_open() {
                        if conn.next_event().await.unwrap().is_none() {
                            panic!("server connection closed during the handshake");
                        }
                    }
                    while let Some(event) = conn.next_event().await.unwrap() {
                        if let Event::Deliver { args, answer: Some(answer), .. } = &event {
                            let verb = match args.first() {
                                Some(Argument::Symbol(s)) => s.as_str(),
                                _ => "",
                            };
                            if verb == "do" {
                                conn.send_resolve(*answer, &Resolution::Break("nope: revoked".into()))
                                    .await
                                    .unwrap();
                                break;
                            }
                        }
                    }
                });

                let conn = Connection::connect(addr).await.unwrap();
                let _serve = conn.serve();
                let cap = conn.fetch("svc").await.unwrap();
                let err = conn.send(&cap, "do", &[]).await.unwrap_err();
                assert_eq!(err.message().as_deref(), Some("nope: revoked"));
                // A break is PANCAKE_ERR_BROKEN, not a transport or value error.
                assert_eq!(err.code(), crate::sys::ERR_BROKEN);
                conn.close();
                server.await.unwrap();
            })
            .await;
    }

    // A failed command settles its own oneshot with the typed refusal and
    // leaves the driver task alive: a send to a never-granted far import is
    // refused with its session code (not laundered into IO -9, not a dead
    // channel), and the same connection then fetches and calls the published
    // capability — proving the driver survived to serve the next command.
    #[tokio::test]
    async fn a_failed_command_replies_typed_and_the_connection_survives() {
        let local = LocalSet::new();
        local
            .run_until(async {
                let server = listen("127.0.0.1:0").await.unwrap();
                let addr = server.local_addr().unwrap();
                let (ready_tx, ready_rx) = oneshot::channel::<()>();
                let host = tokio::task::spawn_local(async move {
                    let conn = server.accept().await.unwrap();
                    conn.publish("svc", |verb, _args| {
                        if verb != "ping" {
                            return Err(format!("no such method: {verb}"));
                        }
                        Ok(Argument::String("pong".into()))
                    })
                    .await
                    .unwrap();
                    ready_tx.send(()).unwrap();
                    conn.serve().await;
                });

                let conn = Connection::connect(addr).await.unwrap();
                ready_rx.await.unwrap();

                // An inadmissible target: import 999 was never granted by the
                // partner, so the session refuses the deliver locally.
                let bogus = Ref::try_from(&Argument::Reference(Reference::far(999))).unwrap();
                let err = conn.send(&bogus, "ping", &[]).await.unwrap_err();
                assert_eq!(err.code(), crate::sys::ERR_SESSION);

                // The driver survived the refusal: the next commands still work.
                let cap = conn.fetch("svc").await.unwrap();
                let reply = conn.send(&cap, "ping", &[]).await.unwrap();
                assert_eq!(reply, Argument::String("pong".into()));
                conn.close();
                host.await.unwrap();
            })
            .await;
    }

    // A `send` to a `Ref` this same connection spawned resolves in-process, not
    // over the wire: the server hosts no such export, so a wire route would never
    // reply. The client never starts a serve loop — the local turn drives and the
    // reply comes straight back.
    #[tokio::test]
    async fn send_to_a_self_spawned_actor_resolves_in_process() {
        let local = LocalSet::new();
        local
            .run_until(async {
                let server = listen("127.0.0.1:0").await.unwrap();
                let addr = server.local_addr().unwrap();
                let host = tokio::task::spawn_local(async move {
                    let conn = server.accept().await.unwrap();
                    conn.serve().await; // ends when the client closes
                });

                let conn = Connection::connect(addr).await.unwrap();
                let me = conn
                    .spawn(|verb, args| {
                        if verb != "greet" {
                            return Err(format!("no such method: {verb}"));
                        }
                        let who = match args.first() {
                            Some(Argument::String(s)) => s.as_str(),
                            _ => "?",
                        };
                        Ok(Argument::String(format!("hi {who}")))
                    })
                    .await
                    .unwrap();
                let reply = conn
                    .send(&me, "greet", &[Argument::String("self".into())])
                    .await
                    .unwrap();
                assert_eq!(reply, Argument::String("hi self".into()));
                conn.close();
                host.await.unwrap();
            })
            .await;
    }
}
