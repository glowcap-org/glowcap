//! The iroh sidecar's C ABI as Zig sees it: opaque endpoint and connection
//! handles, the extern structs mirrored field for field from
//! `transports/iroh/include/glowcap_iroh_sidecar.h`, and the imported verbs.

const foundation = @import("foundation");

const crypto = foundation.crypto;

// ── The sidecar C ABI (transports/iroh/include/glowcap_iroh_sidecar.h) ──────

pub const CEndpoint = opaque {};
pub const CConn = opaque {};

/// The sidecar's endpoint config, field-for-field with its `#[repr(C)]`
/// counterpart. Passed by pointer so a new endpoint knob is a field here rather
/// than a wider signature every caller has to agree on.
pub const CEndpointConfig = extern struct {
    reachability: u32,
    connect_timeout_ms: u64,
    idle_timeout_ms: u64,
    worker_threads: u32,
};

pub extern fn glowcap_iroh_sidecar_endpoint_new(secret_seed32: ?*const [32]u8, config: *const CEndpointConfig) ?*CEndpoint;
pub extern fn glowcap_iroh_sidecar_endpoint_node_id(ep: *const CEndpoint, out: [*]u8, out_cap: usize) isize;
pub extern fn glowcap_iroh_sidecar_endpoint_direct_addrs(ep: *const CEndpoint, out: [*]u8, out_cap: usize) isize;
pub extern fn glowcap_iroh_sidecar_connect_blocking(ep: *CEndpoint, node_id: [*]const u8, node_id_len: usize, addr_hints: [*]const u8, addr_hints_len: usize, out_code: *i32, out_text: ?[*]u8, out_text_cap: usize, out_text_len: ?*usize) ?*CConn;
pub extern fn glowcap_iroh_sidecar_accept_timeout(ep: *CEndpoint, timeout_ms: i32, out_code: *i32) ?*CConn;
pub extern fn glowcap_iroh_sidecar_conn_remote_node_id(conn: *const CConn, out_key32: [*]u8) i32;
pub extern fn glowcap_iroh_sidecar_conn_read(conn: *CConn, buf: [*]u8, len: usize) isize;
pub extern fn glowcap_iroh_sidecar_conn_write(conn: *CConn, buf: [*]const u8, len: usize) isize;
pub extern fn glowcap_iroh_sidecar_conn_flush(conn: *CConn) i32;
pub extern fn glowcap_iroh_sidecar_conn_close(conn: *CConn) void;
pub extern fn glowcap_iroh_sidecar_conn_free(conn: *CConn) void;
pub extern fn glowcap_iroh_sidecar_endpoint_close(ep: *CEndpoint) void;
pub extern fn glowcap_iroh_sidecar_endpoint_free(ep: *CEndpoint) i32;

// The event-driven scale superset (ADR-0019): one readiness fd per endpoint, a
// drained ready-queue, and non-blocking frame I/O, the `Backend` below adapts
// them to `completion.Loop`.
pub extern fn glowcap_iroh_sidecar_endpoint_readiness_fd(ep: *const CEndpoint) i32;
pub extern fn glowcap_iroh_sidecar_endpoint_drain_ready(ep: *const CEndpoint, out: [*]ReadyEvent, out_cap: usize) isize;
pub extern fn glowcap_iroh_sidecar_endpoint_start_connect(ep: *CEndpoint, request_id: usize, node_id: [*]const u8, node_id_len: usize, addr_hints: [*]const u8, addr_hints_len: usize) i32;
pub extern fn glowcap_iroh_sidecar_endpoint_finish_connect(ep: *CEndpoint, request_id: usize, out_conn: *?*CConn, out_text: ?[*]u8, out_text_cap: usize, out_text_len: ?*usize) i32;
pub extern fn glowcap_iroh_sidecar_endpoint_cancel_connect(ep: *CEndpoint, request_id: usize) i32;
pub extern fn glowcap_iroh_sidecar_endpoint_set_nonblocking_accept(ep: *CEndpoint) i32;
pub extern fn glowcap_iroh_sidecar_endpoint_admission(ep: *CEndpoint, enabled: u8) i32;
pub extern fn glowcap_iroh_sidecar_endpoint_try_accept(ep: *CEndpoint) ?*CConn;
pub extern fn glowcap_iroh_sidecar_conn_set_nonblocking(ep: *CEndpoint, conn: *CConn) i32;
pub extern fn glowcap_iroh_sidecar_conn_id(conn: *const CConn) usize;
pub extern fn glowcap_iroh_sidecar_conn_try_read(conn: *CConn, buf: [*]u8, len: usize) isize;
pub extern fn glowcap_iroh_sidecar_conn_try_write(conn: *CConn, buf: [*]const u8, len: usize) isize;

/// `conn_try_read` / `conn_try_write` return this when the operation cannot make
/// progress without blocking. Distinct from 0 (clean end of stream) and -1
/// (error). Mirrors `GLOWCAP_IROH_WOULD_BLOCK` in the sidecar header.
pub const would_block: isize = -2;

/// Bound on the text the sidecar keeps for one failed dial, mirroring
/// `GLOWCAP_IROH_SIDECAR_DIAL_TEXT_BYTES`. A `DialText` is exactly this
/// large, so the resident never receives a truncated copy.
pub const dial_text_bytes: usize = 256;

/// The sidecar's account of one failed dial, iroh's own text beside the code
/// the resident classifies: which relay refused, which address stayed silent,
/// the QUIC close reason. Caller-owned, fixed-size control-plane storage that
/// lives on the stack of the one call that projects it, filled by
/// `Resident.dialRawConn` and `Resident.loopFinishConnect`, and cut by the
/// sidecar at the last whole UTF-8 sequence that fits. Empty when the code is
/// the whole fact.
pub const DialText = struct {
    bytes: [dial_text_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const DialText) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Readiness event bits packed into `ReadyEvent.events`, mirroring the sidecar
/// header's `GLOWCAP_IROH_EV_*`. A drained record may carry several at once.
pub const ev_readable: u32 = 1;
pub const ev_writable: u32 = 2;
pub const ev_closed: u32 = 4;
pub const ev_accept: u32 = 8;
pub const ev_connect: u32 = 16;

/// One drained readiness record: the subject that became ready (the stable
/// `loopConnId` identity for connection records, a caller request id for
/// `ev_connect`, 0 for `ev_accept`) and the `ev_*` bitset. This is the
/// `extern struct` counterpart of the sidecar's `GlowcapIrohReadyEvent` and
/// the header's `glowcap_iroh_sidecar_ready_event`. The three layouts are
/// kept in lockstep.
pub const ReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

/// The key QUIC verified for the far end of `conn` during the TLS handshake,
/// or null when the sidecar could not read it. Every path that speaks the
/// transport proof of ADR-0028, the blocking accept and dial, the completion
/// backend, and the loop surface a language binding drives, reads it here, so
/// one function decides what "the connection proved" means for iroh.
pub fn connRemoteKey(conn: *const CConn) ?crypto.PeerKey {
    var remote: [crypto.peer_key_bytes]u8 = undefined;
    if (glowcap_iroh_sidecar_conn_remote_node_id(conn, &remote) != 0) return null;
    return crypto.PeerKey.fromBytes(remote);
}
