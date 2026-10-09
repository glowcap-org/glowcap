//! C stream-provider connection handles for the onion adapter.
//!
//! Dial and accept paths transfer an owned stream plus a retained netlayer
//! lease here. This module owns the raw C handle, readiness descriptor,
//! nonblocking read/write with its failure latch, and final release of that
//! lease.

const std = @import("std");
const net = @import("net");
const c = @import("c_abi_shared");
const failure_projection = @import("../failure.zig");
const runtime = @import("../runtime/state.zig");

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

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
    const dest = (out orelse {
        c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
        return -1;
    })[0..cap];
    const got = net.socket.receiveNonblocking(@intCast(conn.stream.readinessFd()), dest) catch |err| {
        if (err == error.WouldBlock) return c.transport_provider.GLOWCAP_TRANSPORT_WOULD_BLOCK;
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_IO, err);
        return -1;
    };
    return @intCast(got);
}

pub fn providerTryWrite(_: ?*anyopaque, conn_raw: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    const conn = rawConn(conn_raw);
    if (!conn.operations.acquire(conn.owner.io())) {
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_CLOSED, error.Closed);
        return -1;
    }
    defer conn.operations.release(conn.owner.io());
    const source = bytes orelse {
        c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
        return -1;
    };
    const wrote = net.socket.sendNonblocking(@intCast(conn.stream.readinessFd()), source[0..len]) catch |err| {
        if (err == error.WouldBlock) return c.transport_provider.GLOWCAP_TRANSPORT_WOULD_BLOCK;
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_IO, err);
        return -1;
    };
    return @intCast(wrote);
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
    if (owner.release()) |runtime_failure| {
        if (failure) |*primary|
            primary.noteChain(runtime_failure)
        else
            failure = runtime_failure;
    }
    if (failure) |chain| {
        c.setLastErrorChain("onion provider connection close", chain);
        const code = failure_projection.providerListen(chain.cause);
        return c.transport_provider.failProviderChain(
            out_failure,
            code,
            chain,
            failure_projection.providerListen,
        );
    }
    return GLOWCAP_OK;
}
