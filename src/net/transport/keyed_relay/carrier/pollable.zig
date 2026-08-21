//! Pollable clear-WebSocket carrier opener.

const std = @import("std");

const foundation = @import("foundation");
const carrier_failure = @import("../../../carrier_failure.zig");
const netlayer = @import("../../../netlayer.zig");
const tls_stream = @import("../../../tls/pollable_stream.zig");
const clock = @import("../../../clock.zig");
const byte_stream = @import("byte_stream.zig");
const endpoint = @import("../endpoint.zig");
const route = @import("../route.zig");
const relay_stream = @import("../stream.zig");
const relay_upgrade = @import("../upgrade.zig");
const runtime = @import("runtime.zig");

const DialError = netlayer.DialError;
const RawConnectionDialOutcome = netlayer.RawConnectionDialOutcome;
const RelayStream = relay_stream.RelayStream;

pub const OpenOutcome = RawConnectionDialOutcome(*RelayStream);
const tls_handshake_timeout_ms: i64 = 10_000;

/// Open one channel while preserving the exact DNS, socket, entropy, and
/// WebSocket-upgrade cause beside the shared retry classification.
pub fn openOutcome(
    carrier: runtime.Lease,
    allocator: std.mem.Allocator,
    request: route.OpenRequest,
    stop_requested: ?*const std.atomic.Value(bool),
) OpenOutcome {
    if (request.endpoint.scheme.secure() and !carrier.hasTls())
        return .{ .failed = .fromCarrier(
            error.SocketConfigurationFailed,
            .init(.secure_handshake, error.SecureCarrierUnavailable),
        ) };
    var operation_lease: ?runtime.Lease = carrier.retain();
    const outcome = openOwned(&operation_lease, allocator, request, stop_requested);
    return switch (outcome) {
        .connected => |stream| .{ .connected = stream },
        .failed => |failure| blk: {
            var exact = failure;
            if (operation_lease) |*lease|
                if (lease.releaseOutcome()) |cleanup| exact.chain.noteChain(cleanup);
            break :blk .{ .failed = exact };
        },
    };
}

/// The operation lease transfers directly into the successful stream. A
/// failed open leaves it with the caller so release remains part of the same
/// failure transaction rather than an ignored defer.
fn openOwned(
    operation_lease: *?runtime.Lease,
    allocator: std.mem.Allocator,
    request: route.OpenRequest,
    stop_requested: ?*const std.atomic.Value(bool),
) OpenOutcome {
    const lease = operation_lease.*.?;
    const io = lease.io();
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    io.randomSecure(&seed) catch |err|
        return .{ .failed = .fromCarrier(
            error.ConnectionLost,
            .init(.websocket_upgrade, err),
        ) };
    const connected = switch (endpoint.connect(io, request.endpoint)) {
        .connected => |stream| stream,
        .failed => |failure| return .{ .failed = failure },
    };
    var connected_owned = true;
    defer if (connected_owned) connected.close(io);

    var source = if (request.endpoint.scheme.secure()) secure: {
        const opened = lease.openTls(request.endpoint.host) orelse
            return .{ .failed = .fromCarrier(
                error.SocketConfigurationFailed,
                .init(.secure_handshake, error.SecureCarrierUnavailable),
            ) };
        var client = switch (opened) {
            .client => |value| value,
            .failed => |failure| return .{ .failed = .fromCarrier(
                error.ConnectionRefused,
                .{
                    .phase = .secure_handshake,
                    .chain = failure.chain,
                    .detail = failure.detail,
                },
            ) },
        };
        const secure_stream = tls_stream.Stream.create(
            lease.stateAllocator(),
            io,
            connected,
            client,
        ) catch |err| {
            var chain = foundation.FailureChain.init(err);
            if (client.deinitOutcome()) |cleanup| chain.noteChain(cleanup.chain);
            return .{ .failed = .fromCarrier(
                error.OutOfMemory,
                .{ .phase = .secure_handshake, .chain = chain },
            ) };
        };
        connected_owned = false;
        secure_stream.establish(
            clock.nowMs(io) + tls_handshake_timeout_ms,
            stop_requested,
        ) catch |err| {
            const exact = secure_stream.deinitOutcome();
            const classification: DialError = switch (err) {
                error.TimedOut => error.TimedOut,
                error.Cancelled => error.ConnectionLost,
                error.TlsFailed => error.ConnectionRefused,
            };
            return .{ .failed = .fromCarrier(
                classification,
                if (exact) |failure| .{
                    .phase = .secure_handshake,
                    .chain = failure.chain,
                    .detail = failure.detail,
                } else carrier_failure.Failure.init(.secure_handshake, err),
            ) };
        };
        break :secure byte_stream.adoptSecure(secure_stream);
    } else clear: {
        const adopted = byte_stream.adoptClear(
            lease.stateAllocator(),
            io,
            connected,
        ) catch |err| return .{ .failed = .init(err) };
        connected_owned = false;
        break :clear adopted;
    };
    const stream = RelayStream.create(allocator, lease, source, seed) catch |err| {
        var failure = netlayer.DialFailure.fromCarrier(
            err,
            carrier_failure.Failure.init(.websocket_upgrade, err),
        );
        if (source.deinitOutcome()) |cleanup| failure.chain.noteChain(cleanup);
        return .{ .failed = failure };
    };
    operation_lease.* = null;

    relay_upgrade.run(stream, request, stop_requested) catch |err| switch (err) {
        error.UpgradeRefused => return failedStream(stream, error.ConnectionRefused, err),
        error.ConnectionLost => return failedStream(stream, error.ConnectionLost, err),
        error.UpgradeTimedOut => return failedStream(stream, error.TimedOut, err),
    };
    return .{ .connected = stream };
}

fn failedStream(stream: *RelayStream, classification: DialError, fallback: anyerror) OpenOutcome {
    if (stream.failure == null) stream.noteFailure(fallback);
    return .{ .failed = .fromCarrier(
        classification,
        .{
            .phase = .websocket_upgrade,
            .chain = stream.destroy() orelse foundation.FailureChain.init(fallback),
        },
    ) };
}

pub fn open(
    carrier: runtime.Lease,
    allocator: std.mem.Allocator,
    request: route.OpenRequest,
    stop_requested: ?*const std.atomic.Value(bool),
) DialError!*RelayStream {
    return switch (openOutcome(carrier, allocator, request, stop_requested)) {
        .connected => |stream| stream,
        .failed => |failure| failure.classification,
    };
}
