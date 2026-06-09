//! Connection: the application surface over tokio (the `async` feature).
//!
//! This is what an application holds. It composes a peer, a vat, and the tokio
//! I/O driver into one object, so a consumer never stitches those three together
//! by hand. The verbs — [`connect`], [`Connection::fetch`]/[`Connection::publish`],
//! [`Connection::spawn`], [`Connection::send`], [`Connection::serve`],
//! [`Connection::close`] — are the whole common surface.
//!
//! The pancake [`Peer`](crate::Peer) is a single-owner, `!Send` state machine, so
//! a `Connection` owns it on one background task and the handle talks to that task
//! over channels. The handle is therefore `!Send` too — create and use it on one
//! task, inside a `LocalSet` (or `#[tokio::main(flavor = "current_thread")]`). This
//! is the honest shape for a `!Send` resource: it is not hidden, and the channel
//! plumbing lives here so an application never writes it.

use std::cell::Cell;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, ToSocketAddrs};
use tokio::sync::{mpsc, oneshot};

use crate::actors::{Behavior, Ref as VatRef, Vat};
use crate::{Argument, Error, Peer, Reference, Resolution, Result};

const BOOTSTRAP_POSITION: u64 = 0;
const FIRST_SPAWN_POSITION: u64 = 32;

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

type Reply<T> = oneshot::Sender<std::result::Result<T, String>>;

enum Cmd {
    Spawn { position: u64, behavior: Behavior },
    Publish { name: String, behavior: Behavior, reply: Reply<u64> },
    Fetch { name: String, reply: Reply<Reference> },
    Send { target: VatRef, verb: String, args: Vec<Argument>, reply: Reply<Argument> },
    Tell { target: Reference, verb: String, args: Vec<Argument> },
    Close,
}

/// A live connection to one OCapN partner — the one object an application holds.
/// `!Send` by construction (it owns a `!Send` peer on a background task); use it
/// on a single task inside a `LocalSet`.
pub struct Connection {
    cmd_tx: mpsc::UnboundedSender<Cmd>,
    next_spawn: Cell<u64>,
    driver: Cell<Option<tokio::task::JoinHandle<()>>>,
}

impl Connection {
    /// Dial `addr` and return a ready connection, spawning its driver task.
    /// Must be called inside a `LocalSet` (the peer is `!Send`).
    pub async fn connect<A: ToSocketAddrs>(addr: A) -> Result<Connection> {
        let stream = TcpStream::connect(addr).await.map_err(|_| Error::from_code(-9))?;
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let driver = tokio::task::spawn_local(async move {
            let _ = drive(stream, cmd_rx).await;
        });
        Ok(Connection {
            cmd_tx,
            next_spawn: Cell::new(FIRST_SPAWN_POSITION),
            driver: Cell::new(Some(driver)),
        })
    }

    /// Spawn a local actor and return a capability to it. Pass the returned `Ref`
    /// as a `send` argument to hand a partner a callback.
    pub fn spawn(
        &self,
        behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
    ) -> Ref {
        let position = self.next_spawn.get();
        self.next_spawn.set(position + 1);
        let _ = self.cmd_tx.send(Cmd::Spawn { position, behavior: Box::new(behavior) });
        Ref { reference: Reference::Near { id: position, promise: false } }
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
            .map_err(|_| Error::from_code(-9))?;
        let position = rx.await.map_err(|_| Error::from_code(-9))?.map_err(Error::broken)?;
        Ok(Ref { reference: Reference::Near { id: position, promise: false } })
    }

    /// Fetch a partner's published capability by `name`. Requires
    /// [`serve`](Connection::serve) to be running so the resolution arrives.
    pub async fn fetch(&self, name: &str) -> Result<Ref> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(Cmd::Fetch { name: name.to_string(), reply: tx })
            .map_err(|_| Error::from_code(-9))?;
        let reference = rx.await.map_err(|_| Error::from_code(-9))?.map_err(Error::broken)?;
        Ok(Ref { reference })
    }

    /// Call `verb(args)` on the capability `target` and await the reply. `args`
    /// may contain capabilities via `Into<Argument>`. Errors if the partner
    /// breaks the call.
    pub async fn send(&self, target: &Ref, verb: &str, args: &[Argument]) -> Result<Argument> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(Cmd::Send {
                target: VatRef::Far(target.reference.clone()),
                verb: verb.to_string(),
                args: args.to_vec(),
                reply: tx,
            })
            .map_err(|_| Error::from_code(-9))?;
        match rx.await {
            Ok(Ok(value)) => Ok(value),
            // The partner broke the call; carry its reason, not just a code.
            Ok(Err(message)) => Err(Error::broken(message)),
            Err(_) => Err(Error::from_code(-9)),
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
            .map_err(|_| Error::from_code(-9))
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

async fn drive(mut stream: TcpStream, mut cmd_rx: mpsc::UnboundedReceiver<Cmd>) -> Result<()> {
    let mut peer = Peer::new_negotiating()?;
    let mut inbox: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 16 * 1024];

    // Establish the OCapN session before serving any command: the driver task
    // runs this first, so a `fetch`/`send` queued by the handle waits in the
    // channel until the keyed handshake has opened the session.
    handshake(&mut peer, &mut stream, &mut inbox, &mut chunk).await?;

    let mut vat = Vat::over(&mut peer);
    loop {
        tokio::select! {
            biased;
            maybe = cmd_rx.recv() => {
                match maybe {
                    None | Some(Cmd::Close) => break,
                    Some(cmd) => handle(&mut vat, &mut stream, cmd).await?,
                }
            }
            read = stream.read(&mut chunk) => {
                let n = read.map_err(|_| Error::from_code(-9))?;
                if n == 0 { break; }
                inbox.extend_from_slice(&chunk[..n]);
                {
                    let peer = vat.peer().expect("a peer-bound vat");
                    while let Some(consumed) = peer.recv_stream(&inbox)? {
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
                flush(&mut vat, &mut stream).await?;
            }
        }
    }
    Ok(())
}

async fn handle(vat: &mut Vat<'_>, stream: &mut TcpStream, cmd: Cmd) -> Result<()> {
    match cmd {
        Cmd::Spawn { position, behavior } => {
            vat.publish(position, behavior)?;
        }
        Cmd::Publish { name, behavior, reply } => {
            let allocated = vat.peer().expect("a peer-bound vat").register_bootstrap_cap(name.as_bytes());
            match allocated {
                Ok(position) => {
                    vat.publish(position, behavior)?;
                    let _ = reply.send(Ok(position));
                }
                Err(e) => {
                    let _ = reply.send(Err(format!("{e:?}")));
                }
            }
        }
        Cmd::Fetch { name, reply } => {
            vat.peer().expect("a peer-bound vat").register_import(BOOTSTRAP_POSITION)?;
            let vow = vat.send(
                &VatRef::Far(Reference::far(BOOTSTRAP_POSITION)),
                "fetch",
                &[Argument::Bytes(name.into_bytes())],
            )?;
            vat.on(vow, move |resolution| {
                let out = match resolution {
                    Resolution::Fulfill(Argument::Reference(reference)) => Ok(reference),
                    Resolution::Fulfill(_) => Err("fetch did not resolve to a capability".to_string()),
                    Resolution::Break(message) => Err(message),
                };
                let _ = reply.send(out);
            });
            flush(vat, stream).await?;
        }
        Cmd::Send { target, verb, args, reply } => {
            let vow = vat.send(&target, &verb, &args)?;
            vat.on(vow, move |resolution| {
                let out = match resolution {
                    Resolution::Fulfill(value) => Ok(value),
                    Resolution::Break(message) => Err(message),
                };
                let _ = reply.send(out);
            });
            flush(vat, stream).await?;
        }
        Cmd::Tell { target, verb, args } => {
            // A fire-and-forget deliver: prepend the verb symbol, request no
            // answer, and flush. The partner's actor runs but sends no reply.
            let mut payload = Vec::with_capacity(args.len() + 1);
            payload.push(Argument::Symbol(verb));
            payload.extend(args);
            vat.peer().expect("a peer-bound vat").send_deliver(&target, &payload, None)?;
            flush(vat, stream).await?;
        }
        Cmd::Close => {}
    }
    Ok(())
}

async fn flush(vat: &mut Vat<'_>, stream: &mut TcpStream) -> Result<()> {
    pump_outbound(vat.peer().expect("a peer-bound vat"), stream).await
}

// Encode pending outbound work and write every queued frame, then flush.
async fn pump_outbound(peer: &mut Peer, stream: &mut TcpStream) -> Result<()> {
    peer.step()?;
    while let Some(frame) = peer.take_outbound() {
        stream.write_all(&frame).await.map_err(|_| Error::from_code(-9))?;
    }
    stream.flush().await.map_err(|_| Error::from_code(-9))?;
    Ok(())
}

// Complete the keyed `op:start-session` handshake: sign a `tcp` locator naming
// our own local address with a per-connection random session seed (entropy at
// the I/O boundary, never in the sans-io core), flush it, and read until the
// partner's start-session opens the session. Leftover inbound bytes stay in
// `inbox` for the main loop. The exchange is symmetric — both ends send first,
// then read — so two pancake peers (or pancake and Goblins) converge.
async fn handshake(
    peer: &mut Peer,
    stream: &mut TcpStream,
    inbox: &mut Vec<u8>,
    chunk: &mut [u8],
) -> Result<()> {
    let designator = stream
        .local_addr()
        .map(|a| a.to_string())
        .unwrap_or_else(|_| "127.0.0.1:0".to_string());
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).map_err(|_| Error::from_code(-6))?;
    peer.start_session_keyed(&seed, "tcp", &designator, true)?;
    pump_outbound(peer, stream).await?;
    while !peer.session_is_open() {
        let n = stream.read(chunk).await.map_err(|_| Error::from_code(-9))?;
        if n == 0 {
            return Err(Error::from_code(-8)); // closed during the handshake
        }
        inbox.extend_from_slice(&chunk[..n]);
        while let Some(consumed) = peer.recv_stream(inbox)? {
            inbox.drain(..consumed);
        }
        while peer.poll()?.is_some() {} // drain handshake-artifact events
        pump_outbound(peer, stream).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AsyncConnection, Event};
    use tokio::net::TcpListener;
    use tokio::task::LocalSet;

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

                // Server: a raw peer that publishes a bootstrap cap. The engine
                // auto-answers the `fetch`; the server breaks the `do` call that
                // follows, with a reason the client must read back.
                let server = tokio::task::spawn_local(async move {
                    let (stream, _) = listener.accept().await.unwrap();
                    let mut peer = Peer::new_negotiating().unwrap();
                    peer.register_bootstrap_cap(b"svc").unwrap();
                    // Responder half of the keyed handshake (a fixed seed is fine
                    // in a test): the client's `Connection::connect` handshakes,
                    // so the server must too or it would refuse the start-session.
                    peer.start_session_keyed(&[7u8; 32], "tcp", "127.0.0.1:2", true).unwrap();
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
}
