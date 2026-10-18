//! C stream-provider connection handles for the onion adapter.
//!
//! Dial and accept paths transfer an owned stream plus a retained netlayer
//! lease here. This module owns the raw C handle, readiness descriptor,
//! nonblocking read/write with its failure latch, and final release of that
//! lease.

const std = @import("std");
const net = @import("net");
const c = @import("c_abi_shared");
const runtime = @import("../runtime/state.zig");

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;

const RawConn = struct {
    stream: net.onion.resident.RawStream,
    owner: *runtime.Netlayer,
    operations: c.ForeignCallBarrier = .{},
    failure: c.GlowcapProviderFailure = std.mem.zeroes(c.GlowcapProviderFailure),
};

pub const Adopted = struct {
    handle: *anyopaque,
    readiness_fd: i32,
};

pub fn adoptStream(owner: *runtime.Netlayer, stream: std.Io.net.Stream) !Adopted {
    errdefer {
        stream.close(owner.io());
        owner.releaseProviderChild();
    }
    if (!net.socket.setNoSigpipe(stream.socket.handle)) return error.SocketConfigurationFailed;
    const conn = try owner.allocator.create(RawConn);
    conn.* = .{
        .stream = net.onion.resident.RawStream.init(
            owner.io(),
            stream,
            &[_]u8{},
            &[_]u8{},
        ),
        .owner = owner,
        .operations = .{},
    };
    return .{ .handle = conn, .readiness_fd = @intCast(conn.stream.readinessFd()) };
}

fn rawConn(raw: ?*anyopaque) *RawConn {
    return @ptrCast(@alignCast(raw.?));
}

pub fn providerTryRead(_: ?*anyopaque, conn_raw: ?*anyopaque, out: ?[*]u8, cap: usize) callconv(.c) isize {
    const conn = rawConn(conn_raw);
    if (!conn.operations.acquire(conn.owner.io())) {
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_CLOSED, error.Closed);
        return -1;
    }
    defer conn.operations.release(conn.owner.io());
    const dest = (out orelse return c.transport_provider.failNullBuffer(&conn.failure))[0..cap];
    return c.transport_provider.tryOutcome(&conn.failure, net.socket.receiveNonblocking(@intCast(conn.stream.readinessFd()), dest));
}

pub fn providerTryWrite(_: ?*anyopaque, conn_raw: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    const conn = rawConn(conn_raw);
    if (!conn.operations.acquire(conn.owner.io())) {
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_CLOSED, error.Closed);
        return -1;
    }
    defer conn.operations.release(conn.owner.io());
    const source = (bytes orelse return c.transport_provider.failNullBuffer(&conn.failure))[0..len];
    return c.transport_provider.tryOutcome(&conn.failure, net.socket.sendNonblocking(@intCast(conn.stream.readinessFd()), source));
}

pub fn providerConnTakeFailure(_: ?*anyopaque, conn_raw: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) void {
    c.transport_provider.takeProviderFailure(&rawConn(conn_raw).failure, out_failure);
}

pub fn providerConnClose(
    _: ?*anyopaque,
    conn_raw: ?*anyopaque,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const conn = rawConn(conn_raw);
    const owner = conn.owner;
    var failure: ?net.netlayer.ListenerCloseFailure = null;
    if (conn.operations.beginShutdown(owner.io())) conn.stream.shutdown() catch |err| {
        failure = net.netlayer.ListenerCloseFailure.init(err);
    };
    conn.operations.wait(owner.io());
    conn.stream.close();
    owner.allocator.destroy(conn);
    return closeOutcome("onion provider connection close", failure, owner.release(), out_failure);
}

/// Project a close's outcome after the owner released its runtime share: the
/// runtime's failure, if any, chains behind the close's own.
pub fn closeOutcome(
    comptime what: []const u8,
    close_failure: ?net.netlayer.ListenerCloseFailure,
    runtime_failure: ?net.netlayer.ListenerCloseFailure,
    out_failure: ?*c.GlowcapProviderFailure,
) i32 {
    var failure = close_failure;
    if (runtime_failure) |chain| {
        if (failure) |*primary| primary.noteChain(chain) else failure = chain;
    }
    const chain = failure orelse return GLOWCAP_OK;
    c.setLastErrorChain(what, chain);
    return c.transport_provider.failProviderChain(out_failure, c.netlayerFailureCode(chain.cause), chain, c.netlayerFailureCode);
}
