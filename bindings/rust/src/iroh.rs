//! iroh transport for the async surface (the `iroh` feature).
//!
//! iroh's encrypted-QUIC netlayer links the Rust sidecar, which ADR-0055 keeps
//! out of `libpancake`; it ships as its own optional superset library,
//! `libpancake_iroh`, built with `zig build iroh-abi` (needs cargo). The
//! `iroh` cargo feature links that library and exposes a dialer/listener here.
//!
//! The frame unit is identical to TCP's — one codec-self-delimited CapTP
//! message — so the [`Connection`](crate::Connection) driver is unchanged: it
//! drives the same sans-io peer over a byte stream. [`IrohStream`] is that byte
//! stream, bridging the blocking sidecar FFI (`pancake_iroh_conn_read_frame` /
//! `pancake_iroh_conn_write_frame`) into [`AsyncRead`]/[`AsyncWrite`]. A reader
//! thread parks on the blocking read and feeds whole frames to the driver task
//! over a channel; a writer thread drains queued frames to the wire. The two
//! directions run on their own threads — exactly what Deno's nonblocking FFI
//! does — so neither blocks the current-thread runtime the `Connection` lives
//! on.

use core::ffi::c_uint;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::mpsc;

use crate::sys::{PancakeFrame, PancakeManagedFrame};
use crate::{check, sys, Error, Result};

mod ffi {
    use core::ffi::{c_int, c_uchar, c_uint};

    use crate::sys::{PancakeFrame, PancakeManagedFrame};

    #[repr(C)]
    pub struct PancakeIrohNetlayer {
        _private: [u8; 0],
    }
    #[repr(C)]
    pub struct PancakeIrohConn {
        _private: [u8; 0],
    }

    extern "C" {
        pub fn pancake_iroh_netlayer_new(
            secret_seed: *const c_uchar,
            secret_seed_len: usize,
            reachability: c_uint,
            out_netlayer: *mut *mut PancakeIrohNetlayer,
        ) -> c_int;
        pub fn pancake_iroh_netlayer_close(netlayer: *mut PancakeIrohNetlayer);
        pub fn pancake_iroh_netlayer_release(netlayer: *mut PancakeIrohNetlayer);
        pub fn pancake_iroh_netlayer_node_id(
            netlayer: *mut PancakeIrohNetlayer,
            out: *mut c_uchar,
            cap: usize,
            out_len: *mut usize,
        ) -> c_int;
        pub fn pancake_iroh_netlayer_direct_addrs(
            netlayer: *mut PancakeIrohNetlayer,
            out: *mut c_uchar,
            cap: usize,
            out_len: *mut usize,
        ) -> c_int;
        pub fn pancake_iroh_netlayer_connect(
            netlayer: *mut PancakeIrohNetlayer,
            node_id: *const c_uchar,
            node_id_len: usize,
            addr_hints: *const c_uchar,
            addr_hints_len: usize,
            codec: c_uint,
            max_frame_bytes: usize,
            out_conn: *mut *mut PancakeIrohConn,
        ) -> c_int;
        pub fn pancake_iroh_netlayer_accept(
            netlayer: *mut PancakeIrohNetlayer,
            codec: c_uint,
            max_frame_bytes: usize,
            out_conn: *mut *mut PancakeIrohConn,
        ) -> c_int;
        pub fn pancake_iroh_conn_read_frame(conn: *mut PancakeIrohConn, out_frame: *mut PancakeManagedFrame) -> c_int;
        pub fn pancake_iroh_conn_write_frame(conn: *mut PancakeIrohConn, frame: *const PancakeFrame) -> c_int;
        pub fn pancake_iroh_conn_release(conn: *mut PancakeIrohConn);
    }
}

use ffi::{PancakeIrohConn, PancakeIrohNetlayer};

const MAX_FRAME_BYTES: usize = 4096;

/// How an iroh endpoint becomes reachable — the mandatory posture every dialer
/// and listener chooses, in the open. There is no default: a pancake peer never
/// turns on relays or a discovery service as a hidden implementation detail, so
/// the caller always names one.
///
/// - `Direct`: relay-less, lookup-less — dial by id plus explicit address hints
///   (loopback/LAN). The rooms demo's posture: its URIs carry direct-addresses.
/// - `Discovery`: number-0 relays + DNS/pkarr discovery — dialable by id alone
///   over the internet, with hole-punching and NAT traversal.
/// - `DiscoveryNoRelay`: DNS/pkarr discovery without relays.
/// - `LocalDiscovery`: in-process shared address book — resolves by id alone
///   with no relay, DNS, or hints. For tests and same-process embeddings.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Reachability {
    Direct = 0,
    Discovery = 1,
    DiscoveryNoRelay = 2,
    LocalDiscovery = 3,
}

/// A bound iroh QUIC endpoint plus the sidecar runtime driving it — the iroh
/// sibling of [`Netlayer`](crate::Netlayer). Dial with [`IrohNetlayer::connect`]
/// or host with [`IrohServer`]. Released on drop, after every connection minted
/// from it is released.
pub struct IrohNetlayer {
    raw: *mut PancakeIrohNetlayer,
}

impl IrohNetlayer {
    /// Bind an iroh endpoint with a fresh random Ed25519 key and the caller's
    /// chosen [`Reachability`] — the mandatory posture deciding whether the
    /// endpoint uses relays or a discovery service. There is no default.
    pub fn new(reachability: Reachability) -> Result<IrohNetlayer> {
        let mut raw: *mut PancakeIrohNetlayer = core::ptr::null_mut();
        check(unsafe { ffi::pancake_iroh_netlayer_new(core::ptr::null(), 0, reachability as c_uint, &mut raw) })?;
        Ok(IrohNetlayer { raw })
    }

    /// This endpoint's id — its Ed25519 public key as lowercase hex, the dialable
    /// designator and the URI host.
    pub fn node_id(&self) -> Result<String> {
        let mut buf = [0u8; 64];
        let mut len: usize = 0;
        check(unsafe { ffi::pancake_iroh_netlayer_node_id(self.raw, buf.as_mut_ptr(), buf.len(), &mut len) })?;
        Ok(String::from_utf8_lossy(&buf[..len]).into_owned())
    }

    /// This endpoint's comma-separated direct socket addresses — the hint string a
    /// partner passes to dial it relay-less.
    pub fn direct_addresses(&self) -> Result<String> {
        // The endpoint with no direct addresses writes zero bytes; a buffer too
        // small is ERR_INVALID_ARGUMENT, so grow until it fits.
        let mut cap = 256usize;
        loop {
            let mut buf = vec![0u8; cap];
            let mut len: usize = 0;
            let code = unsafe { ffi::pancake_iroh_netlayer_direct_addrs(self.raw, buf.as_mut_ptr(), buf.len(), &mut len) };
            if code == sys::ERR_INVALID_ARGUMENT && cap < 64 * 1024 {
                cap *= 4;
                continue;
            }
            check(code)?;
            return Ok(String::from_utf8_lossy(&buf[..len]).into_owned());
        }
    }

    /// Close the endpoint without releasing the handle: a blocked accept returns
    /// an error and later dials fail. Idempotent — the shutdown lever a dropped
    /// dialer pulls so its reader thread, parked in a blocking read, wakes.
    pub fn close(&self) {
        unsafe { ffi::pancake_iroh_netlayer_close(self.raw) };
    }

    /// Dial a partner by endpoint id and direct-address hints, completing the
    /// blocking QUIC handshake on a blocking-pool thread, and return the byte
    /// stream that carries the OCapN session. The returned stream owns this
    /// netlayer's lifetime (an ephemeral dialing endpoint released with the
    /// connection).
    pub async fn connect_owned(self, node_id: &str, direct_addresses: &str) -> Result<IrohStream> {
        let raw = self.raw as usize;
        let nid = node_id.to_string();
        let hints = direct_addresses.to_string();
        let conn = tokio::task::spawn_blocking(move || dial(raw as *mut PancakeIrohNetlayer, &nid, &hints))
            .await
            .map_err(|_| Error::from_code(sys::ERR_IO))??;
        Ok(IrohStream::new(conn as *mut PancakeIrohConn, Some(self)))
    }
}

// The raw handle is single-owner like a peer; an `IrohNetlayer` value is moved
// between the dialing task and the blocking dial (as a usize) and owned by one
// task thereafter, never aliased, so it is safe to move across threads.
unsafe impl Send for IrohNetlayer {}

impl Drop for IrohNetlayer {
    fn drop(&mut self) {
        unsafe { ffi::pancake_iroh_netlayer_release(self.raw) };
    }
}

// Blocking dial, run on a blocking-pool thread. Returns the connection pointer as
// a usize so the `spawn_blocking` join value stays `Send`.
fn dial(netlayer: *mut PancakeIrohNetlayer, node_id: &str, hints: &str) -> Result<usize> {
    let mut conn: *mut PancakeIrohConn = core::ptr::null_mut();
    check(unsafe {
        ffi::pancake_iroh_netlayer_connect(
            netlayer,
            node_id.as_ptr(),
            node_id.len(),
            hints.as_ptr(),
            hints.len(),
            sys::CODEC_SYRUP,
            MAX_FRAME_BYTES,
            &mut conn,
        )
    })?;
    Ok(conn as usize)
}

// One iroh connection pointer, released exactly once — when the last holder (the
// reader and writer threads) drops its `Arc`. Releasing only after both threads
// have left their loops means no thread is inside a sidecar call when the
// connection is freed.
struct ConnPtr(*mut PancakeIrohConn);

// Safe to share across the reader and writer threads: the sidecar permits a
// concurrent read and write on one connection (Deno drives it exactly this way
// over its nonblocking FFI threadpool), and the pointer itself is never mutated.
unsafe impl Send for ConnPtr {}
unsafe impl Sync for ConnPtr {}

impl Drop for ConnPtr {
    fn drop(&mut self) {
        unsafe { ffi::pancake_iroh_conn_release(self.0) };
    }
}

/// A byte stream over one iroh QUIC connection: the iroh sibling of a
/// `TcpStream` for the [`Connection`](crate::Connection) driver. Whole frames
/// arrive from a reader thread parked on the blocking sidecar read and are
/// surfaced as bytes (the peer re-frames them); queued frames are drained to the
/// wire by a writer thread. Dropping it tears the connection down: it closes the
/// dialer's ephemeral endpoint (waking the reader) and releases the connection
/// once both threads exit.
pub struct IrohStream {
    inbound: mpsc::UnboundedReceiver<Vec<u8>>,
    // A frame larger than the read buffer: bytes already framed but not yet
    // copied to a caller's buffer.
    leftover: Vec<u8>,
    leftover_at: usize,
    outbound: mpsc::UnboundedSender<Vec<u8>>,
    // Bytes a `poll_write` accumulated, flushed to the writer thread as one
    // sidecar write on `poll_flush`.
    wbuf: Vec<u8>,
    // The first writer-thread error code, surfaced to the next write/flush.
    write_err: Arc<AtomicI32>,
    // The dialer's ephemeral endpoint, closed on drop to wake the reader.
    owned_netlayer: Option<IrohNetlayer>,
}

impl IrohStream {
    fn new(conn: *mut PancakeIrohConn, owned_netlayer: Option<IrohNetlayer>) -> IrohStream {
        let conn = Arc::new(ConnPtr(conn));
        let (in_tx, in_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let write_err = Arc::new(AtomicI32::new(sys::OK));

        // Reader: park on the blocking read; feed each whole frame to the driver.
        let reader_conn = Arc::clone(&conn);
        std::thread::spawn(move || loop {
            let mut frame: PancakeManagedFrame = unsafe { core::mem::zeroed() };
            let code = unsafe { ffi::pancake_iroh_conn_read_frame(reader_conn.0, &mut frame) };
            if code != sys::OK {
                break; // clean EOF, a QUIC fault, or the endpoint closed under us
            }
            let bytes = unsafe { core::slice::from_raw_parts(frame.bytes, frame.len) }.to_vec();
            unsafe { sys::pancake_managed_frame_release(&mut frame) };
            if in_tx.send(bytes).is_err() {
                break; // the stream was dropped
            }
        });

        // Writer: drain queued frames to the wire, one sidecar write each.
        let writer_conn = Arc::clone(&conn);
        let writer_err = Arc::clone(&write_err);
        std::thread::spawn(move || {
            while let Some(bytes) = out_rx.blocking_recv() {
                let frame = PancakeFrame {
                    bytes: bytes.as_ptr(),
                    len: bytes.len(),
                    shape: sys::FRAME_SHAPE_BYTE,
                };
                let code = unsafe { ffi::pancake_iroh_conn_write_frame(writer_conn.0, &frame) };
                if code != sys::OK {
                    writer_err.store(code, Ordering::Relaxed);
                    break;
                }
            }
        });

        IrohStream {
            inbound: in_rx,
            leftover: Vec::new(),
            leftover_at: 0,
            outbound: out_tx,
            wbuf: Vec::new(),
            write_err,
            owned_netlayer,
        }
    }

    /// Dial an iroh partner by endpoint id and direct-address hints, returning the
    /// byte stream the [`Connection`](crate::Connection) driver carries the
    /// session over. The local endpoint is ephemeral, created with the caller's
    /// chosen [`Reachability`] (no default), and released with the stream.
    pub async fn connect(node_id: &str, direct_addresses: &str, reachability: Reachability) -> Result<IrohStream> {
        let netlayer = IrohNetlayer::new(reachability)?;
        netlayer.connect_owned(node_id, direct_addresses).await
    }
}

impl Drop for IrohStream {
    fn drop(&mut self) {
        // Wake a reader parked in a blocking read by closing the dialer's own
        // endpoint; an accepted stream has no owned endpoint (the server owns it),
        // so its reader exits when the partner or the server closes.
        if let Some(netlayer) = &self.owned_netlayer {
            netlayer.close();
        }
    }
}

impl AsyncRead for IrohStream {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let me = self.get_mut();
        if me.leftover_at < me.leftover.len() {
            let n = (me.leftover.len() - me.leftover_at).min(buf.remaining());
            buf.put_slice(&me.leftover[me.leftover_at..me.leftover_at + n]);
            me.leftover_at += n;
            if me.leftover_at == me.leftover.len() {
                me.leftover.clear();
                me.leftover_at = 0;
            }
            return Poll::Ready(Ok(()));
        }
        match me.inbound.poll_recv(cx) {
            Poll::Ready(Some(frame)) => {
                let n = frame.len().min(buf.remaining());
                buf.put_slice(&frame[..n]);
                if n < frame.len() {
                    me.leftover = frame;
                    me.leftover_at = n;
                }
                Poll::Ready(Ok(()))
            }
            Poll::Ready(None) => Poll::Ready(Ok(())), // clean EOF: zero bytes filled
            Poll::Pending => Poll::Pending,
        }
    }
}

impl AsyncWrite for IrohStream {
    fn poll_write(self: Pin<&mut Self>, _cx: &mut Context<'_>, src: &[u8]) -> Poll<io::Result<usize>> {
        let me = self.get_mut();
        let code = me.write_err.load(Ordering::Relaxed);
        if code != sys::OK {
            return Poll::Ready(Err(io::Error::new(io::ErrorKind::Other, format!("iroh write failed (code {code})"))));
        }
        me.wbuf.extend_from_slice(src);
        Poll::Ready(Ok(src.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let me = self.get_mut();
        if !me.wbuf.is_empty() {
            let buf = core::mem::take(&mut me.wbuf);
            if me.outbound.send(buf).is_err() {
                return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "iroh writer thread gone")));
            }
        }
        let code = me.write_err.load(Ordering::Relaxed);
        if code != sys::OK {
            return Poll::Ready(Err(io::Error::new(io::ErrorKind::Other, format!("iroh write failed (code {code})"))));
        }
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.poll_flush(cx)
    }
}

/// A listening iroh endpoint — the iroh sibling of [`Server`](crate::Server).
/// [`IrohServer::accept`] yields one accepted [`IrohStream`] (and its dialer's
/// signed endpoint id) per partner; read [`IrohServer::uri`] for the dialable
/// address to hand a client.
pub struct IrohServer {
    netlayer: IrohNetlayer,
    node_id: String,
}

impl IrohServer {
    /// Bind an iroh endpoint with a fresh random Ed25519 key and the caller's
    /// chosen [`Reachability`] — the mandatory posture, no default.
    pub fn bind(reachability: Reachability) -> Result<IrohServer> {
        let netlayer = IrohNetlayer::new(reachability)?;
        let node_id = netlayer.node_id()?;
        Ok(IrohServer { netlayer, node_id })
    }

    /// This endpoint's id — the keyed locator designator and the URI host.
    pub fn node_id(&self) -> &str {
        &self.node_id
    }

    /// This endpoint's comma-separated direct-address hints.
    pub fn direct_addresses(&self) -> Result<String> {
        self.netlayer.direct_addresses()
    }

    /// The `ocapn://<nodeid>.iroh?direct-addresses=…` URI a partner dials,
    /// rendered through the core locator grammar.
    pub fn uri(&self) -> Result<String> {
        let mut hints = std::collections::BTreeMap::new();
        let addrs = self.direct_addresses()?;
        if !addrs.is_empty() {
            hints.insert("direct-addresses".to_string(), addrs);
        }
        crate::uri::format_peer_uri("iroh", &self.node_id, &hints)
    }

    /// Block (on a blocking-pool thread) until a partner dials, returning the
    /// accepted byte stream. The accepted stream's connection is released when it
    /// drops; this server's endpoint stays open for the next accept.
    pub async fn accept(&self) -> Result<IrohStream> {
        let nl = self.netlayer.raw as usize;
        let conn = tokio::task::spawn_blocking(move || accept_raw(nl as *mut PancakeIrohNetlayer))
            .await
            .map_err(|_| Error::from_code(sys::ERR_IO))??;
        Ok(IrohStream::new(conn as *mut PancakeIrohConn, None))
    }

    /// Stop accepting and release the endpoint.
    pub fn close(&self) {
        self.netlayer.close();
    }
}

fn accept_raw(netlayer: *mut PancakeIrohNetlayer) -> Result<usize> {
    let mut conn: *mut PancakeIrohConn = core::ptr::null_mut();
    check(unsafe { ffi::pancake_iroh_netlayer_accept(netlayer, sys::CODEC_SYRUP, MAX_FRAME_BYTES, &mut conn) })?;
    Ok(conn as usize)
}

