//! Public raw-connection projection of iroh's event-driven readiness loop.
//!
//! This leaf translates the endpoint's stable readiness records and
//! nonblocking sidecar verbs into the C archive's exact result vocabulary. It
//! owns no endpoint or connection state; `ownership.zig` owns every payload and
//! teardown edge, while the caller continues to own framing.

const model = @import("model");
const net = @import("net");
const iroh = @import("iroh");
const c = @import("c_abi_shared");
const ownership = @import("ownership.zig");

const PancakeIrohNetlayer = ownership.PancakeIrohNetlayer;
const PancakeIrohConn = ownership.PancakeIrohConn;
const NetlayerPayload = ownership.NetlayerPayload;

const setLastError = c.setLastError;
const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_BUFFER_TOO_SMALL = c.PANCAKE_ERR_BUFFER_TOO_SMALL;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;

/// Readiness event bits, defined from the resident so the compiler holds the C
/// mirror and the sidecar values in lockstep. A record may carry several.
pub const PANCAKE_IROH_EV_READABLE: u32 = iroh.loop_ev_readable;
pub const PANCAKE_IROH_EV_WRITABLE: u32 = iroh.loop_ev_writable;
pub const PANCAKE_IROH_EV_CLOSED: u32 = iroh.loop_ev_closed;
pub const PANCAKE_IROH_EV_ACCEPT: u32 = iroh.loop_ev_accept;
pub const PANCAKE_IROH_EV_CONNECT: u32 = iroh.loop_ev_connect;

/// One readiness record handed to the host. `subject` is zero for accept, a
/// caller request id for connect completion, and otherwise the stable id
/// returned by `pancake_iroh_conn_id`.
pub const PancakeIrohReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

/// Close the connection and free the handle; do not use `conn` afterward.
/// A later readiness record may still carry its stable id; the host drops that
/// record because its own id-to-connection row is already gone. No call ever
/// parks on the connection, so this free cannot race a parked read.
pub export fn pancake_iroh_conn_release(conn: ?*PancakeIrohConn) void {
    const payload = ownership.connFromOpaque(conn) orelse return;
    ownership.destroyConn(payload);
}

/// Stable readiness identity for this connection. It is unique for the
/// netlayer's lifetime and is not derived from the handle allocation address.
pub export fn pancake_iroh_conn_id(conn: ?*PancakeIrohConn) usize {
    const payload = ownership.connFromOpaque(conn) orelse return 0;
    return payload.conn_id;
}

/// Write the far end's QUIC-verified endpoint id into `out` as lowercase hex,
/// and the byte count into `out_len`. This is the transport proof of ADR-0105:
/// the TLS handshake authenticated the key at the other end. It answers for an
/// accepted connection exactly as for a dialed one.
///
/// `cap` must be at least `PANCAKE_IROH_NODE_ID_BYTES`. A missing proof is an
/// I/O error, never success with a zero length, and `out_len` is untouched on
/// failure.
pub export fn pancake_iroh_conn_remote_node_id(
    conn: ?*PancakeIrohConn,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    c.lastErrorClear();
    const payload = ownership.connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = out orelse return PANCAKE_ERR_NULL_POINTER;
    const len_slot = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    if (cap < iroh.node_id_len) return PANCAKE_ERR_BUFFER_TOO_SMALL;

    const key = payload.netlayer.resident.loopConnRemoteKey(payload.conn) orelse {
        setLastError("conn_remote_node_id: sidecar reported no verified remote", .{});
        return PANCAKE_ERR_IO;
    };
    const designator = key.toDesignator();
    @memcpy(dest[0..designator.len], &designator);
    len_slot.* = designator.len;
    return PANCAKE_OK;
}

/// The endpoint's borrowed read-only readiness fd. Register it once with the
/// caller's poller and drain records whenever it signals. It stays valid until
/// netlayer release and must not be closed by the borrower.
pub export fn pancake_iroh_netlayer_readiness_fd(netlayer: ?*PancakeIrohNetlayer) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    return nl.resident.readinessFd();
}

/// Clear the fd's coalesced wake bytes, then drain at most `out_cap` records
/// without blocking. `out_count` is untouched on failure. Run on one thread per
/// endpoint, serialized against netlayer release.
pub export fn pancake_iroh_netlayer_drain_ready(
    netlayer: ?*PancakeIrohNetlayer,
    out_events: ?[*]PancakeIrohReadyEvent,
    out_cap: usize,
    out_count: ?*usize,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest_ptr = out_events orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_count orelse return PANCAKE_ERR_NULL_POINTER;
    if (out_cap == 0) {
        setLastError("iroh drain_ready: out_cap must not be zero", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const n = drainInto(nl, dest_ptr[0..out_cap]);
    if (n < 0) return c.failInternal("iroh drain_ready", error.OutOfMemory);
    slot.* = @intCast(n);
    return PANCAKE_OK;
}

/// Claim one accepted connection without blocking. Drive it after an accept
/// readiness record; release the returned handle with
/// `pancake_iroh_conn_release`.
pub export fn pancake_iroh_netlayer_try_accept(
    netlayer: ?*PancakeIrohNetlayer,
    out_conn: ?*?*PancakeIrohConn,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = null;
    const raw = nl.resident.loopTryAccept() orelse return PANCAKE_ERR_WOULD_BLOCK;
    const payload = ownership.registerConn(nl, raw) orelse {
        nl.resident.loopConnClose(raw);
        return c.failInternal("iroh accept", error.OutOfMemory);
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Admit one nonblocking dial. `request_id` must be nonzero and unique among
/// live requests. Success promises exactly one CONNECT readiness record; a
/// synchronous error promises none.
pub export fn pancake_iroh_netlayer_start_connect(
    netlayer: ?*PancakeIrohNetlayer,
    request_id: usize,
    node_id: ?[*]const u8,
    node_id_len: usize,
    addr_hints: ?[*]const u8,
    addr_hints_len: usize,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const id_ptr = node_id orelse return PANCAKE_ERR_NULL_POINTER;
    const hints: []const u8 = if (addr_hints) |h|
        h[0..addr_hints_len]
    else if (addr_hints_len == 0)
        &.{}
    else
        return PANCAKE_ERR_NULL_POINTER;
    if (request_id == 0) {
        setLastError("iroh start_connect: request_id must not be zero", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    var hint_entries: [1]model.HintEntry = undefined;
    const target = iroh.resolveConnectTarget(.{
        .transport = iroh.transport_name,
        .designator = id_ptr[0..node_id_len],
        .hints = model.Hints.forDirectAddresses(hints, &hint_entries),
    }) catch |err| {
        setLastError("iroh start_connect: invalid target: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    nl.resident.loopStartConnectResolved(request_id, target.id, target.hints) catch |err| {
        if (err == error.WouldBlock) return PANCAKE_ERR_WOULD_BLOCK;
        return dialErrorToCode(@errorCast(err));
    };
    return PANCAKE_OK;
}

/// Consume one terminal dial after CONNECT readiness. Connection allocation
/// and registration happen here, on the readiness owner thread.
pub export fn pancake_iroh_netlayer_finish_connect(
    netlayer: ?*PancakeIrohNetlayer,
    request_id: usize,
    out_conn: ?*?*PancakeIrohConn,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = null;
    const raw = nl.resident.loopFinishConnect(request_id) catch |err| return dialErrorToCode(err);
    const payload = ownership.registerConn(nl, raw) orelse {
        nl.resident.loopConnClose(raw);
        return c.failInternal("iroh finish_connect", error.OutOfMemory);
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Cancel an admitted dial. Its sole CONNECT readiness record still arrives
/// and must be finished to consume the endpoint-owned terminal row.
pub export fn pancake_iroh_netlayer_cancel_connect(
    netlayer: ?*PancakeIrohNetlayer,
    request_id: usize,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (request_id == 0) {
        setLastError("iroh cancel_connect: request_id must not be zero", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    nl.resident.loopRequestConnectCancel(request_id);
    return PANCAKE_OK;
}

/// Nonblocking raw read. The caller owns framing and `out_read` is untouched
/// on any non-OK result.
pub export fn pancake_iroh_conn_try_read(conn: ?*PancakeIrohConn, buf: ?[*]u8, len: usize, out_read: ?*usize) i32 {
    c.lastErrorClear();
    const payload = ownership.connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = buf orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_read orelse return PANCAKE_ERR_NULL_POINTER;
    const n = payload.netlayer.resident.loopTryRead(payload.conn, dest[0..len]);
    if (n == iroh.loop_would_block) return PANCAKE_ERR_WOULD_BLOCK;
    if (n == 0) return PANCAKE_ERR_CLOSED;
    if (n < 0) {
        setLastError("conn_try_read: connection lost", .{});
        return PANCAKE_ERR_IO;
    }
    slot.* = @intCast(n);
    return PANCAKE_OK;
}

/// Nonblocking raw write. Success may consume only a prefix; `out_written` is
/// untouched on any non-OK result.
pub export fn pancake_iroh_conn_try_write(conn: ?*PancakeIrohConn, buf: ?[*]const u8, len: usize, out_written: ?*usize) i32 {
    c.lastErrorClear();
    const payload = ownership.connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const src = buf orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_written orelse return PANCAKE_ERR_NULL_POINTER;
    const n = payload.netlayer.resident.loopTryWrite(payload.conn, src[0..len]);
    if (n == iroh.loop_would_block) return PANCAKE_ERR_WOULD_BLOCK;
    if (n < 0) {
        setLastError("conn_try_write: connection lost", .{});
        return PANCAKE_ERR_IO;
    }
    slot.* = @intCast(n);
    return PANCAKE_OK;
}

/// Drain pending readiness records without translating stable subjects. Never
/// drains more than `dest` holds, so a short output buffer loses no record.
fn drainInto(nl: *NetlayerPayload, dest: []PancakeIrohReadyEvent) isize {
    var raw: [128]iroh.ReadyEvent = undefined;
    var out_n: usize = 0;
    while (out_n < dest.len) {
        const want = @min(dest.len - out_n, raw.len);
        const n = nl.resident.drainReady(raw[0..want]);
        if (n < 0) return n;
        if (n == 0) break;
        const count: usize = @intCast(n);
        for (raw[0..count]) |rec| {
            dest[out_n] = .{ .subject = rec.subject, .events = rec.events };
            out_n += 1;
        }
        if (count < want) break;
    }
    return @intCast(out_n);
}

fn dialErrorToCode(err: net.netlayer.DialError) i32 {
    return switch (err) {
        // Permanent under ADR-0082 `isTransient`: bindings must not retry these.
        error.InvalidAddress, error.InvalidOptions, error.ConnectionRefused => PANCAKE_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.NetworkUnreachable,
        error.TimedOut,
        error.ConnectionLost,
        error.SocketConfigurationFailed,
        error.WakeNudgeFailed,
        => blk: {
            setLastError("connect: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_IO;
        },
    };
}
