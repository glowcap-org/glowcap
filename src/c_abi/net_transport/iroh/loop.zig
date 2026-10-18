//! Public raw-connection projection of iroh's event-driven readiness loop.
//!
//! This leaf translates the endpoint's stable readiness records and
//! nonblocking sidecar verbs into the C archive's exact result vocabulary. It
//! owns no endpoint or connection state. `ownership.zig` owns every payload and
//! teardown edge, while the caller continues to own framing.

const model = @import("model");
const net = @import("net");
const iroh = @import("iroh");
const c = @import("c_abi_shared");
const ownership = @import("ownership.zig");

const GlowcapIrohNetlayer = ownership.GlowcapIrohNetlayer;
const GlowcapIrohConn = ownership.GlowcapIrohConn;
const NetlayerPayload = ownership.NetlayerPayload;

const setLastError = c.setLastError;
const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_BUFFER_TOO_SMALL = c.GLOWCAP_ERR_BUFFER_TOO_SMALL;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;
const GLOWCAP_ERR_WOULD_BLOCK = c.GLOWCAP_ERR_WOULD_BLOCK;

/// Readiness event bits, defined from the resident so the compiler holds the C
/// mirror and the sidecar values in lockstep. A record may carry several.
pub const GLOWCAP_IROH_EV_READABLE: u32 = iroh.loop_ev_readable;
pub const GLOWCAP_IROH_EV_WRITABLE: u32 = iroh.loop_ev_writable;
pub const GLOWCAP_IROH_EV_CLOSED: u32 = iroh.loop_ev_closed;
pub const GLOWCAP_IROH_EV_ACCEPT: u32 = iroh.loop_ev_accept;
pub const GLOWCAP_IROH_EV_CONNECT: u32 = iroh.loop_ev_connect;

/// One readiness record handed to the host. `subject` is zero for accept, a
/// caller request id for connect completion, and otherwise the stable id
/// returned by `glowcap_iroh_conn_id`.
pub const GlowcapIrohReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

/// Close the connection and free the handle. Do not use `conn` afterward.
/// A later readiness record may still carry its stable id. The host drops that
/// record because its own id-to-connection row is already gone. No call ever
/// parks on the connection, so this free cannot race a parked read.
pub export fn glowcap_iroh_conn_release(conn: ?*GlowcapIrohConn) void {
    const payload = ownership.connFromOpaque(conn) orelse return;
    ownership.destroyConn(payload);
}

/// Stable readiness identity for this connection. It is unique for the
/// netlayer's lifetime and is not derived from the handle allocation address.
pub export fn glowcap_iroh_conn_id(conn: ?*GlowcapIrohConn) usize {
    const payload = ownership.connFromOpaque(conn) orelse return 0;
    return payload.conn_id;
}

/// Write the far end's QUIC-verified endpoint id into `out` as lowercase hex,
/// and the byte count into `out_len`. This is the transport proof of ADR-0105:
/// the TLS handshake authenticated the key at the other end. It answers for an
/// accepted connection exactly as for a dialed one.
///
/// `cap` must be at least `GLOWCAP_IROH_NODE_ID_BYTES`. A missing proof is an
/// I/O error, never success with a zero length, and `out_len` is untouched on
/// failure.
pub export fn glowcap_iroh_conn_remote_node_id(
    conn: ?*GlowcapIrohConn,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    c.lastErrorClear();
    const payload = ownership.connFromOpaque(conn) orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest = out orelse return GLOWCAP_ERR_NULL_POINTER;
    const len_slot = out_len orelse return GLOWCAP_ERR_NULL_POINTER;
    if (cap < iroh.node_id_len) return GLOWCAP_ERR_BUFFER_TOO_SMALL;

    const key = payload.netlayer.resident.loopConnRemoteKey(payload.conn) orelse {
        setLastError("conn_remote_node_id: the iroh library reported no verified remote", .{});
        return GLOWCAP_ERR_IO;
    };
    const designator = key.toDesignator();
    @memcpy(dest[0..designator.len], &designator);
    len_slot.* = designator.len;
    return GLOWCAP_OK;
}

/// The endpoint's borrowed read-only readiness fd. Register it once with the
/// caller's poller and drain records whenever it signals. It stays valid until
/// netlayer release and must not be closed by the borrower.
pub export fn glowcap_iroh_netlayer_readiness_fd(netlayer: ?*GlowcapIrohNetlayer) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    return nl.resident.readinessFd();
}

/// Clear the fd's coalesced wake bytes, then drain at most `out_cap` records
/// without blocking. `out_count` is untouched on failure. Run on one thread per
/// endpoint, serialized against netlayer release.
pub export fn glowcap_iroh_netlayer_drain_ready(
    netlayer: ?*GlowcapIrohNetlayer,
    out_events: ?[*]GlowcapIrohReadyEvent,
    out_cap: usize,
    out_count: ?*usize,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest_ptr = out_events orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_count orelse return GLOWCAP_ERR_NULL_POINTER;
    if (out_cap == 0) {
        setLastError("iroh drain_ready: out_cap must not be zero", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const n = drainInto(nl, dest_ptr[0..out_cap]);
    if (n < 0) return c.failInternal("iroh drain_ready", error.OutOfMemory);
    slot.* = @intCast(n);
    return GLOWCAP_OK;
}

/// Claim one accepted connection without blocking. Drive it after an accept
/// readiness record. Release the returned handle with
/// `glowcap_iroh_conn_release`.
pub export fn glowcap_iroh_netlayer_try_accept(
    netlayer: ?*GlowcapIrohNetlayer,
    out_conn: ?*?*GlowcapIrohConn,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_conn orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = null;
    const raw = nl.resident.loopTryAccept() orelse return GLOWCAP_ERR_WOULD_BLOCK;
    const payload = ownership.registerConn(nl, raw) orelse {
        nl.resident.loopConnClose(raw);
        return c.failInternal("iroh accept", error.OutOfMemory);
    };
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

/// Admit one nonblocking dial. `request_id` must be nonzero and unique among
/// live requests. Success promises exactly one CONNECT readiness record. A
/// synchronous error promises none.
pub export fn glowcap_iroh_netlayer_start_connect(
    netlayer: ?*GlowcapIrohNetlayer,
    request_id: usize,
    node_id: ?[*]const u8,
    node_id_len: usize,
    addr_hints: ?[*]const u8,
    addr_hints_len: usize,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const id_ptr = node_id orelse return GLOWCAP_ERR_NULL_POINTER;
    const hints: []const u8 = if (addr_hints) |h|
        h[0..addr_hints_len]
    else if (addr_hints_len == 0)
        &.{}
    else
        return GLOWCAP_ERR_NULL_POINTER;
    if (request_id == 0) {
        setLastError("iroh start_connect: request_id must not be zero", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    var hint_entries: [1]model.HintEntry = undefined;
    const target = iroh.resolveConnectTarget(.{
        .transport = iroh.transport_name,
        .designator = id_ptr[0..node_id_len],
        .hints = model.Hints.forDirectAddresses(hints, &hint_entries),
    }) catch |err| {
        setLastError("iroh start_connect: invalid target: {s}", .{@errorName(err)});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    nl.resident.loopStartConnectResolved(request_id, target.id, target.hints) catch |err| {
        if (err == error.WouldBlock) return GLOWCAP_ERR_WOULD_BLOCK;
        return dialErrorToCode(@errorCast(err), "");
    };
    return GLOWCAP_OK;
}

/// Consume one terminal dial after CONNECT readiness. Connection allocation
/// and registration happen here, on the readiness owner thread. A failure
/// records iroh's own text for the fault beside its classification in this
/// archive's last-error slot, read through `glowcap_iroh_last_error`.
pub export fn glowcap_iroh_netlayer_finish_connect(
    netlayer: ?*GlowcapIrohNetlayer,
    request_id: usize,
    out_conn: ?*?*GlowcapIrohConn,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_conn orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = null;
    var text: iroh.DialText = .{};
    const raw = nl.resident.loopFinishConnect(request_id, &text) catch |err| return dialErrorToCode(err, text.slice());
    const payload = ownership.registerConn(nl, raw) orelse {
        nl.resident.loopConnClose(raw);
        return c.failInternal("iroh finish_connect", error.OutOfMemory);
    };
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

/// Cancel an admitted dial. Its sole CONNECT readiness record still arrives
/// and must be finished to consume the endpoint-owned terminal row.
pub export fn glowcap_iroh_netlayer_cancel_connect(
    netlayer: ?*GlowcapIrohNetlayer,
    request_id: usize,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (request_id == 0) {
        setLastError("iroh cancel_connect: request_id must not be zero", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    nl.resident.loopRequestConnectCancel(request_id);
    return GLOWCAP_OK;
}

/// Nonblocking raw read. The caller owns framing and `out_read` is untouched
/// on any non-OK result.
pub export fn glowcap_iroh_conn_try_read(conn: ?*GlowcapIrohConn, buf: ?[*]u8, len: usize, out_read: ?*usize) i32 {
    c.lastErrorClear();
    const payload = ownership.connFromOpaque(conn) orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest = buf orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_read orelse return GLOWCAP_ERR_NULL_POINTER;
    const n = payload.netlayer.resident.loopTryRead(payload.conn, dest[0..len]);
    if (n == iroh.loop_would_block) return GLOWCAP_ERR_WOULD_BLOCK;
    if (n == 0) return GLOWCAP_ERR_CLOSED;
    if (n < 0) {
        setLastError("conn_try_read: connection lost", .{});
        return GLOWCAP_ERR_IO;
    }
    slot.* = @intCast(n);
    return GLOWCAP_OK;
}

/// Nonblocking raw write. Success may consume only a prefix. `out_written` is
/// untouched on any non-OK result.
pub export fn glowcap_iroh_conn_try_write(conn: ?*GlowcapIrohConn, buf: ?[*]const u8, len: usize, out_written: ?*usize) i32 {
    c.lastErrorClear();
    const payload = ownership.connFromOpaque(conn) orelse return GLOWCAP_ERR_NULL_POINTER;
    const src = buf orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_written orelse return GLOWCAP_ERR_NULL_POINTER;
    const n = payload.netlayer.resident.loopTryWrite(payload.conn, src[0..len]);
    if (n == iroh.loop_would_block) return GLOWCAP_ERR_WOULD_BLOCK;
    if (n < 0) {
        setLastError("conn_try_write: connection lost", .{});
        return GLOWCAP_ERR_IO;
    }
    slot.* = @intCast(n);
    return GLOWCAP_OK;
}

/// Drain pending readiness records without translating stable subjects. Never
/// drains more than `dest` holds, so a short output buffer loses no record.
fn drainInto(nl: *NetlayerPayload, dest: []GlowcapIrohReadyEvent) isize {
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

/// Project a dial's classification onto the C result and name the concrete
/// cause in the last-error slot: the classification, then the transport's own
/// text for the fault when the sidecar supplied one. The slot copies, so the
/// text may live on the caller's stack.
fn dialErrorToCode(err: net.netlayer.DialError, detail: []const u8) i32 {
    if (detail.len != 0)
        setLastError("connect: {s}: {s}", .{ @errorName(err), detail })
    else
        setLastError("connect: {s}", .{@errorName(err)});
    return c.netlayerFailureCode(err);
}
