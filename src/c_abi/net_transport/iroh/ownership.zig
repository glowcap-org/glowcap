//! Heap-pinned iroh endpoint, raw connection, and provider-adapter ownership.
//!
//! The raw loop ABI and generic multiplexed-provider projection are two views
//! of this one endpoint lease. Keeping their payloads and final teardown here
//! gives connection rows, listener metadata, the sidecar endpoint, and its
//! `std.Io.Threaded` one lifetime authority and one teardown order.

const std = @import("std");

const model = @import("model");
const iroh = @import("iroh");
const c = @import("c_abi_shared");

/// Public opaque handle for one iroh endpoint.
pub const GlowcapIrohNetlayer = opaque {};
/// Public opaque handle for one raw nonblocking iroh connection.
pub const GlowcapIrohConn = opaque {};

/// The netlayer handle owns the one iroh endpoint (and, through it, the
/// sidecar's runtime) plus the `std.Io.Threaded` the resident captures. Every
/// connection made from it borrows the endpoint, so the netlayer must outlive
/// every connection.
pub const NetlayerPayload = struct {
    threaded: std.Io.Threaded,
    resident: iroh.Resident,
    /// The allocator the netlayer and every connection made from it use, so a
    /// connection frees through the same policy as the netlayer that minted it.
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize),
    config: iroh.Resident.Config,
    /// The multiplexed-provider adapter, minted by the first provider query and
    /// freed with the netlayer.
    multiplexed_adapter: ?*MultiplexedAdapter = null,

    pub fn retain(self: *NetlayerPayload) bool {
        var current = self.references.load(.acquire);
        while (current != 0) {
            if (self.references.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    pub fn release(self: *NetlayerPayload) ?anyerror {
        if (self.references.fetchSub(1, .acq_rel) != 1) return null;
        const alloc = self.allocator;
        var failure: ?anyerror = null;
        if (self.multiplexed_adapter) |adapter| {
            if (adapter.native.deinit()) |reported| failure = reported.cause;
            alloc.destroy(adapter);
        }
        self.resident.deinit() catch |err| {
            if (failure == null) failure = err;
        };
        self.threaded.deinit();
        alloc.destroy(self);
        return failure;
    }
};

/// One loop connection: the sidecar handle, its stable readiness identity, and
/// a back-pointer to the netlayer whose endpoint owns it. No read/write buffers
/// and no spill: the host frames the raw bytes this hands out.
pub const ConnPayload = struct {
    allocator: std.mem.Allocator,
    conn_id: usize,
    conn: *anyopaque,
    netlayer: *NetlayerPayload,
};

/// C projection storage; transport state lives in the native adapter.
pub const MultiplexedAdapter = struct {
    payload: *NetlayerPayload,
    profile: c.GlowcapTransportProfile,
    multiplexed_transport: c.GlowcapMultiplexedTransport,
    entry: c.GlowcapTransportProviderEntry,
    native: iroh.MultiplexedAdapter,

    pub fn fromOpaque(ctx: ?*anyopaque) *MultiplexedAdapter {
        return @ptrCast(@alignCast(ctx.?));
    }
};

/// Wrap a freshly accepted or dialed raw loop handle. The caller closes the
/// raw handle when allocation or stable-id validation fails.
pub fn registerConn(nl: *NetlayerPayload, raw: *anyopaque) ?*ConnPayload {
    const payload = nl.allocator.create(ConnPayload) catch return null;
    const conn_id = nl.resident.loopConnId(raw);
    if (conn_id == 0) {
        nl.allocator.destroy(payload);
        return null;
    }
    payload.* = .{
        .allocator = nl.allocator,
        .conn_id = conn_id,
        .conn = raw,
        .netlayer = nl,
    };
    return payload;
}

/// Release a raw loop connection and its sidecar handle. The readiness owner
/// removes its stable-id routing row before this call.
pub fn destroyConn(payload: *ConnPayload) void {
    const alloc = payload.allocator;
    payload.netlayer.resident.loopConnClose(payload.conn);
    alloc.destroy(payload);
}

pub fn netlayerFromOpaque(netlayer: ?*GlowcapIrohNetlayer) ?*NetlayerPayload {
    const ptr = netlayer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn connFromOpaque(conn: ?*GlowcapIrohConn) ?*ConnPayload {
    const ptr = conn orelse return null;
    return @ptrCast(@alignCast(ptr));
}
