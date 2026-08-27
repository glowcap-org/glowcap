//! C stream-provider connection handles for the onion adapter.
//!
//! Dial and accept paths transfer an owned stream plus a retained netlayer
//! lease here. This module owns the raw C handle, readiness descriptor,
//! read/write failure latch, and final release of that lease.

const std = @import("std");
const net = @import("net");
const c = @import("c_abi_shared");
const failure_projection = @import("../failure.zig");
const runtime = @import("../runtime/state.zig");

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;

const RawConn = struct {
    stream: net.onion.resident.RawStream,
    owner: *runtime.Netlayer,
    operations: c.ForeignCallBarrier = .{},
    failure: c.PancakeProviderFailure = std.mem.zeroes(c.PancakeProviderFailure),
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

pub fn providerRead(_: ?*anyopaque, conn_raw: ?*anyopaque, out: ?[*]u8, cap: usize) callconv(.c) isize {
    const conn = rawConn(conn_raw);
    if (!conn.operations.acquire(conn.owner.io())) {
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_CLOSED, error.Closed);
        return -1;
    }
    defer conn.operations.release(conn.owner.io());
    const dest = (out orelse {
        c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        return -1;
    })[0..cap];
    const got = conn.stream.read(dest) catch |err| {
        if (err == error.EndOfStream) return 0;
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_IO, err);
        return -1;
    };
    return @intCast(got);
}

pub fn providerWriteAll(_: ?*anyopaque, conn_raw: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) i32 {
    const conn = rawConn(conn_raw);
    if (!conn.operations.acquire(conn.owner.io())) {
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_CLOSED, error.Closed);
        return PANCAKE_ERR_CLOSED;
    }
    defer conn.operations.release(conn.owner.io());
    const source = bytes orelse {
        c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        return PANCAKE_ERR_NULL_POINTER;
    };
    conn.stream.writeAll(source[0..len]) catch |err| {
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, PANCAKE_ERR_IO, err);
        return PANCAKE_ERR_IO;
    };
    return PANCAKE_OK;
}

pub fn providerConnTakeFailure(_: ?*anyopaque, conn_raw: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) void {
    c.transport_provider.takeProviderFailure(&rawConn(conn_raw).failure, out_failure);
}

pub fn providerConnClose(
    _: ?*anyopaque,
    conn_raw: ?*anyopaque,
    out_failure: ?*c.PancakeProviderFailure,
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
    return PANCAKE_OK;
}
