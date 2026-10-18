//! A session that one partner's refused frame ended releases like any other.
//! The runtime keeps the cause on that session, and releasing the session
//! latches no runtime-wide failure, so the next honest partner opens and
//! calls. The differential probe against a live Goblins vat
//! (`zig build goblins-differential`) found the opposite shape: one malformed
//! frame from one client, then the release of its session, stopped a
//! listener for every later dial.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const tcp = net.tcp;

const harness = @import("harness.zig");
const Treasure = harness.Treasure;
const opts = harness.opts;

/// Accept one partner, publish the greeter, serve until the partner is gone,
/// then record why the wire ended and release the session.
fn serveOne(server: *driver.Server, cause: *?anyerror) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("treasure", Treasure, .{});
    // best-effort: a refused frame ends the serve with its cause, which the status below records.
    session.serve() catch {};
    const status = try session.closeStatus();
    cause.* = if (status.cause) |failure| failure.chain.cause else null;
}

test "host runtime: releasing the session a partner's over-cap frame ended leaves the listener serving the next partner" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer server.deinit();
    var server_buf: [64]u8 = undefined;
    const server_address = try tcp.parseDesignator(try server.localDesignator(&server_buf));

    // The first partner sends one call whose frame is past the listener's cap.
    // The listener refuses it and ends that session.
    var first_cause: ?anyerror = null;
    var first_serve = try io.concurrent(serveOne, .{ server, &first_cause });
    var first_served = false;
    defer if (!first_served) first_serve.cancel(io) catch {};
    {
        var client_buf: [tcp.designator_buf_len]u8 = undefined;
        var client = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&client_buf, server_address), .ephemeral, .{
            .frame_cap = 4 * harness.frame_cap,
            .handshake = .{ .ms = 10_000 },
            .settle = .{ .ms = 10_000 },
        });
        defer client.deinit();
        const treasure = try client.fetch("treasure");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const oversized = try arena.allocator().alloc(u8, 2 * harness.frame_cap);
        @memset(oversized, 'x');
        if (client.call(treasure, "greet", &.{.{ .string = oversized }}, arena.allocator())) |reply| {
            try std.testing.expect(reply == .broken);
        } else |_| {}
    }
    try first_serve.await(io);
    first_served = true;
    try std.testing.expect(first_cause != null);
    try std.testing.expect(server.runtime.terminalFailure() == null);

    // The next honest partner opens, fetches, and calls through the same listener.
    var second_cause: ?anyerror = null;
    var second_serve = try io.concurrent(serveOne, .{ server, &second_cause });
    var second_served = false;
    defer if (!second_served) second_serve.cancel(io) catch {};
    {
        var client_buf: [tcp.designator_buf_len]u8 = undefined;
        var client = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&client_buf, server_address), .ephemeral, opts);
        defer client.deinit();
        const treasure = try client.fetch("treasure");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const reply = try client.call(treasure, "greet", &.{}, arena.allocator());
        try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
        try std.testing.expectEqualStrings("hello from the step server", reply.fulfilled.string);
    }
    try second_serve.await(io);
    second_served = true;
    try std.testing.expect(second_cause == null);
    try std.testing.expect(server.runtime.terminalFailure() == null);
}
