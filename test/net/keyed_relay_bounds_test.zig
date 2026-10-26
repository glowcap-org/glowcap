//! Bounds in the blocking keyed-relay carrier, proven against the in-process
//! relay in `test/support/ws_relay.zig`. The upgrade reader refuses a response
//! one byte past `max_upgrade_response_bytes` with `UpgradeRefused`. The
//! nonblocking read hands the turn back after `max_frames_per_read` frames and
//! leaves the rest buffered. A DNS answer past `max_resolved_addresses` fails
//! the dial with `TooManyAddresses`. Each test also admits the last length
//! under its bound, so a refusal cannot hide an off-by-one.

const std = @import("std");
const glowcap = @import("glowcap");
const ws_relay = @import("../support/ws_relay.zig");
const wait = @import("../support/wait.zig");
const crowded_lookup = @import("../support/crowded_lookup.zig");

const net = glowcap.net;
const relay = net.relay;
const protocol = net.websocket.client_protocol;
const would_block = net.multiplexed_resident.would_block;

const Io = std.Io;

/// Frames one `tryReadSome` consumes before it hands the turn back.
const max_frames_per_read = relay.white_box.max_frames_per_read;
/// How many addresses one DNS answer may seat.
const max_resolved_addresses = relay.white_box.max_resolved_addresses;

fn listenLoopback(io: Io) !Io.net.Server {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    return address.listen(io, .{ .reuse_address = true });
}

fn dialOutcome(resident: *relay.Resident) net.netlayer.RawConnectionDialOutcome(relay.RawConnection) {
    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.seed_bytes]u8, @splat(0x74)),
    );
    const designator = identity.publicKey().toDesignator();
    return resident.dialRawOutcome(.{
        .transport = relay.transport_name,
        .designator = &designator,
    });
}

// --- The HTTP upgrade response cap -------------------------------------------

fn serveSizedUpgrade(io: Io, server: *Io.net.Server, response_bytes: usize) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    try ws_relay.serveUpgradeSized(&leg, response_bytes);
}

fn expectSizedUpgrade(response_bytes: usize, admitted: bool) !void {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try listenLoopback(io);
    defer server.deinit(io);
    var served = try io.concurrent(serveSizedUpgrade, .{ io, &server, response_bytes });
    // best-effort: the await below settles a finished task, and this only
    // stops one still parked when an assertion fails first.
    defer _ = served.cancel(io) catch {};

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "ws://127.0.0.1:{d}/relay",
        .{server.socket.address.getPort()},
    );
    var resident = try relay.Resident.init(allocator, io, url);
    defer _ = resident.deinit();

    switch (dialOutcome(&resident)) {
        .connected => |connected| {
            var connection = connected;
            defer _ = connection.close();
            try std.testing.expect(admitted);
        },
        .failed => |failure| {
            try std.testing.expect(!admitted);
            try std.testing.expectEqual(error.ConnectionRefused, failure.classification);
            try std.testing.expectEqualStrings("UpgradeRefused", failure.chain.primaryName());
            try std.testing.expectEqual(
                net.carrier_failure.Phase.websocket_upgrade,
                failure.carrier_phase.?,
            );
        },
    }
    try served.await(io);
}

test "relay upgrade reader admits a response of exactly the cap" {
    try expectSizedUpgrade(protocol.max_upgrade_response_bytes, true);
}

test "relay upgrade reader refuses a response one byte past the cap" {
    try expectSizedUpgrade(protocol.max_upgrade_response_bytes + 1, false);
}

// --- Frames per nonblocking read ---------------------------------------------

/// Stage `pongs` empty pongs and one data frame in a single socket write, then
/// signal that the whole script is in flight.
fn servePongsThenData(
    io: Io,
    server: *Io.net.Server,
    pongs: usize,
    flushed: *std.atomic.Value(bool),
) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    try ws_relay.serveUpgrade(&leg);
    for (0..pongs) |_| try ws_relay.stageServerFrame(&leg, .pong, &.{});
    try ws_relay.stageServerFrame(&leg, .binary, "tail");
    try leg.writer.interface.flush();
    flushed.store(true, .release);
}

/// Stage `count` one-byte data frames, frame `i` carrying the byte `i`.
fn serveOneByteFrames(
    io: Io,
    server: *Io.net.Server,
    count: usize,
    flushed: *std.atomic.Value(bool),
) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    try ws_relay.serveUpgrade(&leg);
    for (0..count) |index| {
        const byte = [1]u8{@intCast(index)};
        try ws_relay.stageServerFrame(&leg, .binary, &byte);
    }
    try leg.writer.interface.flush();
    flushed.store(true, .release);
}

/// Read one data frame queued behind `pongs` pongs, counting the turns the
/// carrier hands back before the payload arrives.
fn expectPongsHandBackTurns(pongs: usize, expected_turns: usize) !void {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try listenLoopback(io);
    defer server.deinit(io);
    var flushed = std.atomic.Value(bool).init(false);
    var served = try io.concurrent(servePongsThenData, .{ io, &server, pongs, &flushed });
    // best-effort: see `expectSizedUpgrade`.
    defer _ = served.cancel(io) catch {};

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "ws://127.0.0.1:{d}/relay",
        .{server.socket.address.getPort()},
    );
    var resident = try relay.Resident.init(allocator, io, url);
    defer _ = resident.deinit();
    var connection = switch (dialOutcome(&resident)) {
        .connected => |connected| connected,
        .failed => |failure| return failure.classification,
    };
    defer _ = connection.close();
    try wait.untilFlag(io, wait.default_deadline_ms, &flushed);

    var dest: [16]u8 = undefined;
    var handed_back: usize = 0;
    const count = while (true) {
        const result = connection.tryRead(&dest);
        if (result != would_block) break result;
        // Buffered frames behind a handed-back turn are the budget. An empty
        // buffer would be a socket edge, which is not what this proves.
        try std.testing.expect(connection.hasBufferedReadWork());
        handed_back += 1;
        try std.testing.expect(handed_back <= expected_turns);
    };
    try std.testing.expectEqual(expected_turns, handed_back);
    try std.testing.expectEqualStrings("tail", dest[0..@intCast(count)]);
    try served.await(io);
}

test "relay nonblocking read hands the turn back once the frame budget is spent" {
    // The data frame's own header is one of the turn's frames, and its payload
    // is copied by the iteration after it. So `max_frames_per_read - 2` pongs
    // still deliver the payload in the first turn, one more pong pushes the
    // payload to the second turn, and the same step repeats every
    // `max_frames_per_read` frames after that.
    const cases = [_]struct { pongs: usize, turns: usize }{
        .{ .pongs = max_frames_per_read - 2, .turns = 0 },
        .{ .pongs = max_frames_per_read - 1, .turns = 1 },
        .{ .pongs = max_frames_per_read, .turns = 1 },
        .{ .pongs = 2 * max_frames_per_read - 2, .turns = 1 },
        .{ .pongs = 2 * max_frames_per_read - 1, .turns = 2 },
        .{ .pongs = 3 * max_frames_per_read + 8, .turns = 3 },
    };
    for (cases) |case| try expectPongsHandBackTurns(case.pongs, case.turns);
}

test "relay nonblocking read spends the frame budget without losing a byte" {
    const allocator = std.testing.allocator;
    const total: usize = 150;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try listenLoopback(io);
    defer server.deinit(io);
    var flushed = std.atomic.Value(bool).init(false);
    var served = try io.concurrent(serveOneByteFrames, .{ io, &server, total, &flushed });
    // best-effort: see `expectSizedUpgrade`.
    defer _ = served.cancel(io) catch {};

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "ws://127.0.0.1:{d}/relay",
        .{server.socket.address.getPort()},
    );
    var resident = try relay.Resident.init(allocator, io, url);
    defer _ = resident.deinit();
    var connection = switch (dialOutcome(&resident)) {
        .connected => |connected| connected,
        .failed => |failure| return failure.classification,
    };
    defer _ = connection.close();
    try wait.untilFlag(io, wait.default_deadline_ms, &flushed);

    var dest: [256]u8 = undefined;
    var collected: [total]u8 = undefined;
    var sizes: [8]usize = undefined;
    var turns: usize = 0;
    var got: usize = 0;
    while (got < total) {
        try std.testing.expect(turns < sizes.len);
        const result = connection.tryRead(&dest);
        // Every turn here delivers bytes: a hand-back with `would_block` would
        // mean the budget swallowed a turn while data was waiting.
        try std.testing.expect(result > 0);
        const count: usize = @intCast(result);
        try std.testing.expect(got + count <= total);
        @memcpy(collected[got..][0..count], dest[0..count]);
        got += count;
        sizes[turns] = count;
        turns += 1;
        // Frames beyond the budget stay buffered for the next turn.
        try std.testing.expectEqual(got < total, connection.hasBufferedReadWork());
    }
    // Each turn parses `max_frames_per_read` headers. A header's payload byte
    // is copied by the next iteration, so the turn that stops on its 64th
    // header leaves that header's byte for the following turn.
    try std.testing.expectEqualSlices(
        usize,
        &.{ max_frames_per_read - 1, max_frames_per_read, total - 2 * max_frames_per_read + 1 },
        sizes[0..turns],
    );
    for (collected, 0..) |byte, index|
        try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
    try served.await(io);
}

// --- DNS answers past the address cap ----------------------------------------

/// A loopback port nothing listens on, so a connect to it refuses at once.
fn closedLoopbackPort(io: Io) !u16 {
    var probe = try listenLoopback(io);
    defer probe.deinit(io);
    return probe.socket.address.getPort();
}

fn expectCrowdedAnswer(comptime answer_len: usize, expect_too_many: bool) !void {
    const allocator = std.testing.allocator;
    // The lookup runs beside the loop that drains its queue, so the pool needs
    // a worker for `Io.async` even on a single-core runner.
    var threaded = Io.Threaded.init(allocator, .{ .async_limit = Io.Limit.limited(4) });
    defer threaded.deinit();
    var crowded = crowded_lookup.Lookup(answer_len).init(threaded.io());
    const io = crowded.io();

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "ws://relay.test:{d}/relay",
        .{try closedLoopbackPort(io)},
    );
    var resident = try relay.Resident.init(allocator, io, url);
    defer _ = resident.deinit();

    switch (dialOutcome(&resident)) {
        .connected => |connected| {
            var connection = connected;
            _ = connection.close();
            return error.TestUnexpectedResult;
        },
        .failed => |failure| {
            const too_many = std.mem.eql(u8, failure.chain.primaryName(), "TooManyAddresses");
            try std.testing.expectEqual(expect_too_many, too_many);
            if (too_many) {
                try std.testing.expectEqual(error.NetworkUnreachable, failure.classification);
                try std.testing.expectEqual(net.carrier_failure.Phase.resolve, failure.carrier_phase.?);
            }
        },
    }
}

test "relay dial races a DNS answer of exactly the address cap" {
    try expectCrowdedAnswer(max_resolved_addresses, false);
}

test "relay dial refuses a DNS answer one address past the cap" {
    try expectCrowdedAnswer(max_resolved_addresses + 1, true);
}
