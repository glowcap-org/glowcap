//! The iroh netlayer sidecar (ADR-0055).
//!
//! This staticlib wraps one iroh endpoint behind the narrow blocking C ABI
//! declared in `include/pancake_iroh_sidecar.h`, emitting
//! `libpancake_iroh_sidecar.a`. The Zig resident
//! (`src/net_adapter/iroh.zig`) is the only consumer. Shape decisions:
//!
//! * Each endpoint owns its own tokio runtime behind the opaque handle, so a
//!   caller needs no async runtime of its own; every C call blocks the calling
//!   thread by running `block_on` against that runtime. The runtime's thread
//!   bill is explicit and bounded: two worker threads named `pancake-iroh`,
//!   enough for iroh's internal driver tasks while the caller's own threads do
//!   the blocking.
//! * The caller chooses the endpoint's reachability when it is created, and
//!   nothing is on by default: `REACH_DIRECT` binds relay-less and lookup-less
//!   (dial by id plus explicit address hints), `REACH_DISCOVERY` adds the
//!   number-0 relays and DNS/pkarr discovery so a peer is dialable by id alone
//!   over the public internet, `REACH_DISCOVERY_NO_RELAY` keeps discovery but
//!   drops relays, and `REACH_LOCAL_DISCOVERY` is an in-process address book for
//!   tests and same-process embeddings. Enabling relays or a discovery service
//!   is always the host's explicit decision, never a hidden default.
//! * One bidirectional QUIC stream carries the whole OCapN session. QUIC bi
//!   streams are lazy — the acceptor cannot see the stream until the dialer
//!   writes — which OCapN guarantees, because the dialer sends `op:start-session`
//!   first.
//! * No panic crosses the FFI boundary: every entry point runs under
//!   `catch_unwind` and maps a panic to the function's error return.

use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::str::FromStr;
use std::sync::{Mutex, OnceLock};

use iroh::address_lookup::memory::MemoryLookup;
use iroh::endpoint::{presets, Connection, RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};

/// The ALPN both pancake peers negotiate (ADR-0055).
const ALPN: &[u8] = b"ocapn/pancake/1";

/// Reachability postures, chosen explicitly by the caller — there is no
/// default. A pancake peer never enables relays or a discovery service as a
/// hidden implementation detail; the host decides, in the open, how this
/// endpoint becomes reachable. These values mirror
/// `PANCAKE_IROH_REACH_*` in `include/pancake_iroh_sidecar.h` and the
/// `Reachability` enum the Zig resident exposes.
const REACH_DIRECT: u32 = 0;
const REACH_DISCOVERY: u32 = 1;
const REACH_DISCOVERY_NO_RELAY: u32 = 2;
const REACH_LOCAL_DISCOVERY: u32 = 3;

/// The process-shared address book backing `REACH_LOCAL_DISCOVERY`. Every
/// endpoint bound in that mode publishes its own `EndpointAddr` here and
/// resolves partners from it, so a dial by endpoint id alone — no relay, no
/// DNS, no caller-supplied address hints — succeeds inside one process. This is
/// the deterministic, infrastructure-free discovery path: it carries the
/// `iroh-interop` proof and serves same-process embeddings, never the public
/// internet (that is `REACH_DISCOVERY`).
static LOCAL_BOOK: OnceLock<MemoryLookup> = OnceLock::new();

fn local_book() -> &'static MemoryLookup {
    LOCAL_BOOK.get_or_init(MemoryLookup::new)
}

/// The endpoint's directly dialable socket addresses, with wildcard bindings
/// reported in their loopback form so the set is dialable on the local host.
fn dialable_addrs(ep: &Endpoint) -> BTreeSet<SocketAddr> {
    let mut addrs: BTreeSet<SocketAddr> = BTreeSet::new();
    for addr in ep.bound_sockets() {
        let dialable = match addr.ip() {
            IpAddr::V4(ip) if ip.is_unspecified() => {
                SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), addr.port())
            }
            IpAddr::V6(ip) if ip.is_unspecified() => {
                SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), addr.port())
            }
            _ => addr,
        };
        addrs.insert(dialable);
    }
    for addr in ep.addr().ip_addrs() {
        addrs.insert(*addr);
    }
    addrs
}

/// Publish this endpoint's id and direct addresses into the process-shared
/// address book so a `REACH_LOCAL_DISCOVERY` partner can dial it by id alone.
fn publish_local(ep: &Endpoint) {
    let mut addr = EndpointAddr::new(ep.id());
    for sock in dialable_addrs(ep) {
        addr = addr.with_ip_addr(sock);
    }
    local_book().add_endpoint_info(addr);
}

/// Opaque endpoint handle: the iroh endpoint plus the tokio runtime it runs on.
pub struct PancakeIrohEndpoint {
    rt: tokio::runtime::Runtime,
    ep: Endpoint,
}

/// Opaque connection handle: one QUIC connection carrying one bidirectional
/// stream. `send` and `recv` are independently locked so the two directions
/// never serialize against each other.
pub struct PancakeIrohConn {
    rt: tokio::runtime::Handle,
    conn: Connection,
    send: Mutex<SendStream>,
    recv: Mutex<RecvStream>,
}

/// Create an endpoint. `secret_seed32` is either null (generate a fresh random
/// endpoint key) or a pointer to 32 bytes of Ed25519 secret key material.
/// `reachability` selects how this endpoint becomes reachable and is mandatory —
/// one of `PANCAKE_IROH_REACH_*`, with no implicit default. An unknown value
/// returns null. Returns an owned handle (release with
/// `pancake_iroh_sidecar_endpoint_free`) or null on failure. Blocks until the
/// UDP sockets are bound.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_new(
    secret_seed32: *const u8,
    reachability: u32,
) -> *mut PancakeIrohEndpoint {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("pancake-iroh")
            .enable_all()
            .build()
            .ok()?;
        // The reachability posture is the whole choice here: `Minimal` binds
        // relay-less and lookup-less, `N0` adds the number-0 relays and DNS/pkarr
        // discovery, `N0DisableRelay` keeps discovery but drops relays, and the
        // local book is an in-process address exchange. The caller picked one.
        let mut builder = match reachability {
            REACH_DIRECT => Endpoint::builder(presets::Minimal),
            REACH_DISCOVERY => Endpoint::builder(presets::N0),
            REACH_DISCOVERY_NO_RELAY => Endpoint::builder(presets::N0DisableRelay),
            REACH_LOCAL_DISCOVERY => {
                Endpoint::builder(presets::Minimal).address_lookup(local_book().clone())
            }
            _ => return None,
        };
        builder = builder.alpns(vec![ALPN.to_vec()]);
        if !secret_seed32.is_null() {
            let mut seed = [0u8; 32];
            // Safety: the contract requires 32 readable bytes when non-null.
            seed.copy_from_slice(unsafe { std::slice::from_raw_parts(secret_seed32, 32) });
            builder = builder.secret_key(SecretKey::from(seed));
        }
        let ep = rt.block_on(builder.bind()).ok()?;
        if reachability == REACH_LOCAL_DISCOVERY {
            publish_local(&ep);
        }
        Some(Box::into_raw(Box::new(PancakeIrohEndpoint { rt, ep })))
    }));
    match result {
        Ok(Some(handle)) => handle,
        _ => std::ptr::null_mut(),
    }
}

/// Write a UTF-8 string into a caller buffer. Returns the byte count written,
/// or -1 when the buffer is too small.
fn write_str(s: &str, out: *mut u8, out_cap: usize) -> isize {
    let bytes = s.as_bytes();
    if bytes.len() > out_cap {
        return -1;
    }
    // Safety: the contract requires `out_cap` writable bytes at `out`.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
    bytes.len() as isize
}

/// Write the endpoint's id — its Ed25519 public key, the dialable designator —
/// into `out` as lowercase hex (64 bytes; iroh's canonical string form, which
/// its parser accepts alongside base32). Returns the byte count written, or -1
/// when `out_cap` is too small. Borrows the handle; writes no terminator.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_node_id(
    ep: *const PancakeIrohEndpoint,
    out: *mut u8,
    out_cap: usize,
) -> isize {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let ep = unsafe { &*ep };
        write_str(&ep.ep.id().to_string(), out, out_cap)
    }));
    result.unwrap_or(-1)
}

/// Write the endpoint's directly dialable socket addresses into `out` as a
/// comma-separated UTF-8 list (e.g. `127.0.0.1:5000,[::1]:5001`). Bound
/// wildcard addresses are reported as their loopback form, so the list is
/// dialable on the local host; concretely discovered addresses are included
/// as-is. This is the hint string a partner passes to `pancake_iroh_sidecar_connect`.
/// Returns the byte count written, or -1 when `out_cap` is too small. Borrows
/// the handle; writes no terminator.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_direct_addrs(
    ep: *const PancakeIrohEndpoint,
    out: *mut u8,
    out_cap: usize,
) -> isize {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let ep = unsafe { &*ep };
        let joined = dialable_addrs(&ep.ep)
            .iter()
            .map(|a| a.to_string())
            .collect::<Vec<_>>()
            .join(",");
        write_str(&joined, out, out_cap)
    }));
    result.unwrap_or(-1)
}

/// Dial a remote endpoint by id, open the session's one bidirectional stream,
/// and return an owned connection handle (release with
/// `pancake_iroh_sidecar_conn_free`), or null on failure. `node_id` is the partner's id
/// string (hex or base32, as printed by `pancake_iroh_sidecar_endpoint_node_id`);
/// `addr_hints` is the partner's comma-separated direct-address list. It may be
/// empty: an endpoint bound with a discovery posture (`REACH_DISCOVERY`,
/// `REACH_DISCOVERY_NO_RELAY`, or `REACH_LOCAL_DISCOVERY`) resolves the partner
/// by id alone, while a `REACH_DIRECT` endpoint needs the hints to reach
/// anything. Blocks
/// until the QUIC connection is established. The stream is lazy: the caller
/// must write first (OCapN's dialer does, with `op:start-session`). The
/// endpoint must outlive every connection it minted.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_connect(
    ep: *mut PancakeIrohEndpoint,
    node_id: *const u8,
    node_id_len: usize,
    addr_hints: *const u8,
    addr_hints_len: usize,
) -> *mut PancakeIrohConn {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let ep = unsafe { &*ep };
        let id_str =
            std::str::from_utf8(unsafe { std::slice::from_raw_parts(node_id, node_id_len) })
                .ok()?;
        let id = EndpointId::from_str(id_str).ok()?;
        let mut addr = EndpointAddr::new(id);
        if addr_hints_len > 0 {
            let hints = std::str::from_utf8(unsafe {
                std::slice::from_raw_parts(addr_hints, addr_hints_len)
            })
            .ok()?;
            for hint in hints.split(',') {
                let hint = hint.trim();
                if hint.is_empty() {
                    continue;
                }
                let sock = SocketAddr::from_str(hint).ok()?;
                addr = addr.with_ip_addr(sock);
            }
        }
        let conn = ep.rt.block_on(ep.ep.connect(addr, ALPN)).ok()?;
        let (send, recv) = ep.rt.block_on(conn.open_bi()).ok()?;
        Some(Box::into_raw(Box::new(PancakeIrohConn {
            rt: ep.rt.handle().clone(),
            conn,
            send: Mutex::new(send),
            recv: Mutex::new(recv),
        })))
    }));
    match result {
        Ok(Some(handle)) => handle,
        _ => std::ptr::null_mut(),
    }
}

/// Block until a partner dials this endpoint, accept its connection and its
/// first bidirectional stream, and return an owned connection handle (release
/// with `pancake_iroh_sidecar_conn_free`), or null on failure or endpoint close.
/// Because QUIC bi streams are lazy, this returns only once the dialer has
/// written its first bytes (OCapN's `op:start-session`). The endpoint must
/// outlive every connection it minted.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_accept(ep: *mut PancakeIrohEndpoint) -> *mut PancakeIrohConn {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let ep = unsafe { &*ep };
        ep.rt.block_on(async {
            loop {
                let incoming = ep.ep.accept().await?;
                let Ok(accepting) = incoming.accept() else {
                    // Unsolicited or malformed datagrams are routine; keep
                    // accepting.
                    continue;
                };
                let Ok(conn) = accepting.await else {
                    continue;
                };
                let Ok((send, recv)) = conn.accept_bi().await else {
                    continue;
                };
                return Some(Box::into_raw(Box::new(PancakeIrohConn {
                    rt: ep.rt.handle().clone(),
                    conn,
                    send: Mutex::new(send),
                    recv: Mutex::new(recv),
                })));
            }
        })
    }));
    match result {
        Ok(Some(handle)) => handle,
        _ => std::ptr::null_mut(),
    }
}

/// Read up to `len` bytes from the stream into `buf`, blocking until at least
/// one byte arrives. Returns the byte count (> 0), 0 at clean end of stream
/// (the partner finished its send side or closed the connection cleanly), or
/// -1 on error. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_read(
    conn: *mut PancakeIrohConn,
    buf: *mut u8,
    len: usize,
) -> isize {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let conn = unsafe { &*conn };
        let dest = unsafe { std::slice::from_raw_parts_mut(buf, len) };
        let mut recv = match conn.recv.lock() {
            Ok(guard) => guard,
            Err(_) => return -1,
        };
        use iroh::endpoint::{ConnectionError, ReadError};
        match conn.rt.block_on(recv.read(dest)) {
            Ok(Some(n)) => n as isize,
            Ok(None) => 0,
            // A clean connection-level close is end-of-stream, not a fault.
            Err(ReadError::ConnectionLost(ConnectionError::ApplicationClosed(_)))
            | Err(ReadError::ConnectionLost(ConnectionError::LocallyClosed)) => 0,
            Err(_) => -1,
        }
    }));
    result.unwrap_or(-1)
}

/// Write all `len` bytes from `buf` to the stream, blocking until accepted by
/// the QUIC flow-control window. Returns `len`, or -1 on error. Borrows the
/// handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_write(
    conn: *mut PancakeIrohConn,
    buf: *const u8,
    len: usize,
) -> isize {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let conn = unsafe { &*conn };
        let src = unsafe { std::slice::from_raw_parts(buf, len) };
        let mut send = match conn.send.lock() {
            Ok(guard) => guard,
            Err(_) => return -1,
        };
        match conn.rt.block_on(send.write_all(src)) {
            Ok(()) => len as isize,
            Err(_) => -1,
        }
    }));
    result.unwrap_or(-1)
}

/// Report stream health after writes. QUIC transmits written bytes eagerly, so
/// there is no buffered data to push; this returns 0 while the connection is
/// alive and -1 once it is closed or lost. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_flush(conn: *mut PancakeIrohConn) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let conn = unsafe { &*conn };
        if conn.conn.close_reason().is_some() {
            -1
        } else {
            0
        }
    }));
    result.unwrap_or(-1)
}

/// Gracefully close the connection: finish the send stream (the partner's read
/// sees clean end of stream) and queue a QUIC close. Idempotent; safe to call
/// before `pancake_iroh_sidecar_conn_free`. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_close(conn: *mut PancakeIrohConn) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let conn = unsafe { &*conn };
        if let Ok(mut send) = conn.send.lock() {
            let _ = send.finish();
        }
        conn.conn.close(0u32.into(), b"");
    }));
}

/// Release a connection handle. Closes the connection if still open. Every
/// connection must be freed before its endpoint.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_free(conn: *mut PancakeIrohConn) {
    if conn.is_null() {
        return;
    }
    pancake_iroh_sidecar_conn_close(conn);
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Box::from_raw(conn) });
    }));
}

/// Close the endpoint without releasing its handle: a blocked
/// `pancake_iroh_sidecar_accept` returns null, subsequent dials fail, and queued
/// connection closes are delivered. Idempotent. Borrows the handle; the
/// handle stays valid until `pancake_iroh_sidecar_endpoint_free`.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_close(ep: *mut PancakeIrohEndpoint) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let ep = unsafe { &*ep };
        ep.rt.block_on(ep.ep.close());
    }));
}

/// Release an endpoint handle. Blocks while iroh delivers queued connection
/// closes, then shuts the runtime down. Free every connection minted from this
/// endpoint first.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_free(ep: *mut PancakeIrohEndpoint) {
    if ep.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { Box::from_raw(ep) };
        handle.rt.block_on(handle.ep.close());
        // Dropping the runtime outside an async context shuts it down cleanly.
        drop(handle);
    }));
}
