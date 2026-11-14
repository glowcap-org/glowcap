//! The byte-fed drain's spill across chunk boundaries: it holds the front of
//! one frame at most, refuses a prefix that turns malformed or oversize across
//! the boundary, dispatches every frame before a refusal, and pays a bounded
//! number of allocator calls per straddling frame.

const std = @import("std");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");

const fixtures = @import("../support/completion_loop_fixtures.zig");
const frame_cap = fixtures.frame_cap;
const startSession = fixtures.startSession;
const makeServerPeer = fixtures.makeServerPeer;
const pumpStream = fixtures.pumpStream;
const drainOutboundStreamBytes = fixtures.drainOutboundStreamBytes;

/// A client's start-session followed by `count` fetches, as one outer stream,
/// and the end offset of every frame in it.
fn buildFetchStream(allocator: std.mem.Allocator, count: usize, ends: *std.ArrayList(usize)) !std.ArrayList(u8) {
    var stream: std.ArrayList(u8) = .empty;
    errdefer stream.deinit(allocator);
    var client = handshake.stubPeer(allocator);
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    try client.sendBorrowed(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &stream);
    try ends.append(allocator, stream.items.len);
    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    _ = try pumpStream(&server_twin, &client, allocator);
    fetch_pump.drainEvents(&client);
    for (0..count) |_| {
        const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
        try client.send(prepared.message);
        try drainOutboundStreamBytes(&client, allocator, &stream);
        try ends.append(allocator, stream.items.len);
    }
    return stream;
}

/// Feed `stream` to a fresh server peer in `chunk_len` pieces and return
/// everything the peer queued in answer. After every call the spill holds at
/// most the front of one frame. Returns how many calls began with a frame
/// waiting in the spill.
fn drainChunked(allocator: std.mem.Allocator, stream: []const u8, chunk_len: usize, max_frame: usize, sink: *std.ArrayList(u8)) !usize {
    var server = try makeServerPeer(null, allocator);
    defer server.deinit();
    try drainOutboundStreamBytes(&server, allocator, sink); // the server's own hello
    sink.clearRetainingCapacity();
    var spill: glowcap.net.Spill = .{};
    defer spill.deinit(allocator);
    var straddled: usize = 0;
    var offset: usize = 0;
    while (offset < stream.len) {
        const end = @min(offset + chunk_len, stream.len);
        if (spill.isActive()) straddled += 1;
        try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&server, &spill, stream[offset..end], allocator));
        offset = end;
        try std.testing.expect(spill.len < max_frame);
        try std.testing.expect(spill.buf.len < chunk_len);
    }
    try std.testing.expectEqual(@as(usize, 0), spill.len);
    try drainOutboundStreamBytes(&server, allocator, sink);
    return straddled;
}

test "drain spill: chunks that never land on a frame boundary leave the spill under one frame" {
    const allocator = std.testing.allocator;
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(allocator);
    var stream = try buildFetchStream(allocator, 12, &ends);
    defer stream.deinit(allocator);

    var max_frame: usize = ends.items[0];
    for (ends.items[1..], 0..) |end, i| max_frame = @max(max_frame, end - ends.items[i]);

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    {
        var server = try makeServerPeer(null, allocator);
        defer server.deinit();
        try drainOutboundStreamBytes(&server, allocator, &whole);
        whole.clearRetainingCapacity();
        var spill: glowcap.net.Spill = .{};
        defer spill.deinit(allocator);
        try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&server, &spill, stream.items, allocator));
        try drainOutboundStreamBytes(&server, allocator, &whole);
    }
    try std.testing.expect(whole.items.len > 0);

    // Each chunk is wider than the widest frame, so a spill that absorbs it
    // whole grows to a chunk. Frame sizes differ, so no chunk lines up.
    for ([_]usize{ 3 * max_frame + 1, 2 * max_frame + 7, max_frame + 5 }) |chunk_len| {
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(allocator);
        // The test must straddle, or it proves nothing about the spill.
        try std.testing.expect(try drainChunked(allocator, stream.items, chunk_len, max_frame, &got) > 0);
        try std.testing.expectEqualSlices(u8, whole.items, got.items);
    }
}

/// A peer that has read a prefix of a frame into a spill, then a chunk that
/// cannot complete it.
fn expectRefusedAcrossSpill(first: []const u8, second: []const u8, cause: []const u8) !void {
    var peer = handshake.stubPeer(std.testing.allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    var spill: glowcap.net.Spill = .{};
    defer spill.deinit(std.testing.allocator);
    try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&peer, &spill, first, std.testing.allocator));
    try std.testing.expect(spill.isActive());
    try std.testing.expectEqual(glowcap.net.DrainVerdict.fail, glowcap.net.drainWholeFrames(&peer, &spill, second, std.testing.allocator));
    const recorded = peer.lastAbort() orelse return error.TestExpectedFailure;
    try std.testing.expectEqualStrings(cause, recorded.error_name);
}

test "drain spill: a prefix refused across the spill boundary fails the session with its cause" {
    try expectRefusedAcrossSpill("1", "x:abc", "MalformedFrame");
    try expectRefusedAcrossSpill("99", "99:abc", "FrameTooLarge");
}

/// How many inbound events the peer holds, dropping them.
fn countEvents(peer: *engine.Peer) usize {
    var count: usize = 0;
    while (peer.pollEvent()) |event| {
        var e = event;
        e.deinit();
        count += 1;
    }
    return count;
}

test "drain spill: a malformed frame behind the completing one fails after the frames before it dispatch" {
    const allocator = std.testing.allocator;
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(allocator);
    var stream = try buildFetchStream(allocator, 2, &ends);
    defer stream.deinit(allocator);
    // The session start, then two fetches, the second behind the first.
    const cut = ends.items[1] - 3;
    try std.testing.expect(cut > ends.items[0]);

    var reference = try makeServerPeer(null, allocator);
    defer reference.deinit();
    {
        var spill: glowcap.net.Spill = .{};
        defer spill.deinit(allocator);
        try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&reference, &spill, stream.items, allocator));
    }
    const dispatched = countEvents(&reference);
    try std.testing.expect(dispatched >= 2);

    var server = try makeServerPeer(null, allocator);
    defer server.deinit();
    var spill: glowcap.net.Spill = .{};
    defer spill.deinit(allocator);
    try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&server, &spill, stream.items[0..cut], allocator));
    try std.testing.expect(spill.isActive());
    const rest = try std.mem.concat(allocator, u8, &.{ stream.items[cut..], "x:zz" });
    defer allocator.free(rest);
    try std.testing.expectEqual(glowcap.net.DrainVerdict.fail, glowcap.net.drainWholeFrames(&server, &spill, rest, allocator));
    const recorded = server.lastAbort() orelse return error.TestExpectedFailure;
    try std.testing.expectEqualStrings("MalformedFrame", recorded.error_name);
    // The completing frame and the one behind it both dispatched.
    try std.testing.expectEqual(dispatched, countEvents(&server));
}

test "drain spill: a straddling frame costs at most one park and one exact growth" {
    const allocator = std.testing.allocator;
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(allocator);
    var stream = try buildFetchStream(allocator, 12, &ends);
    defer stream.deinit(allocator);

    var server = try makeServerPeer(null, allocator);
    defer server.deinit();
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(allocator);
    try drainOutboundStreamBytes(&server, allocator, &sink);

    // The contract per chunk that completes a parked frame and parks the front
    // of the next: at most two allocation calls (the park and one exact
    // growth, which an allocator that cannot resize in place serves with a
    // fresh block) and two frees (that growth's old block, then the drain).
    // Every cut is four bytes before a frame ends, inside its body.
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var spill: glowcap.net.Spill = .{};
    defer spill.deinit(failing.allocator());
    var offset: usize = 0;
    var chunks: usize = 0;
    for (ends.items[1..]) |end| {
        const cut = end - 4;
        const calls_before = failing.alloc_index + failing.resize_index;
        const frees_before = failing.deallocations;
        try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&server, &spill, stream.items[offset..cut], failing.allocator()));
        try std.testing.expect(failing.alloc_index + failing.resize_index - calls_before <= 2);
        try std.testing.expect(failing.deallocations - frees_before <= 2);
        offset = cut;
        chunks += 1;
    }
    try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&server, &spill, stream.items[offset..], failing.allocator()));
    try std.testing.expectEqual(@as(usize, 0), spill.len);
    try std.testing.expect(chunks > 8);
}

test "drain spill: a completing frame the peer refuses leaves nothing waiting" {
    var peer = handshake.stubPeer(std.testing.allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    var spill: glowcap.net.Spill = .{};
    defer spill.deinit(std.testing.allocator);
    // A well-framed body that is no codec frame, cut inside the body.
    try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&peer, &spill, "5:xx", std.testing.allocator));
    try std.testing.expect(spill.isActive());
    try std.testing.expectEqual(glowcap.net.DrainVerdict.fail, glowcap.net.drainWholeFrames(&peer, &spill, "xxx", std.testing.allocator));
    // The refused frame does not wait as a whole frame for a later call.
    try std.testing.expect(!spill.isActive());
}

test "drain spill: a cap lowered while a frame waits refuses the completing chunk" {
    var peer = handshake.stubPeer(std.testing.allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = 64;
    var spill: glowcap.net.Spill = .{};
    defer spill.deinit(std.testing.allocator);
    try std.testing.expectEqual(glowcap.net.DrainVerdict.ok, glowcap.net.drainWholeFrames(&peer, &spill, "50:ab", std.testing.allocator));
    try std.testing.expect(spill.isActive());
    peer.session_state.limits.max_frame_bytes = 4;
    try std.testing.expectEqual(@as(usize, 4), peer.limits().max_frame_bytes);
    try std.testing.expectEqual(glowcap.net.DrainVerdict.fail, glowcap.net.drainWholeFrames(&peer, &spill, "cde", std.testing.allocator));
    const recorded = peer.lastAbort() orelse return error.TestExpectedFailure;
    try std.testing.expectEqualStrings("FrameTooLarge", recorded.error_name);
}
