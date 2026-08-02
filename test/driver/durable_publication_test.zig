//! Durable publication and Host-level select-or-dial enlivenment over real
//! loopback sockets (ADR-0098 steps 3–4): `Server.publishDurable` mints an
//! unpredictable sturdyref and returns it complete; `Session.enliven` resolves
//! the sturdyref's peer to the live dialed session it names — or dials it —
//! so the caller never selects a session; and `removeDurable` makes the old
//! sturdyref miss while issued capabilities keep answering.
//!
//! One thread drives one host, so each server publishes, serves, and removes
//! on its own fiber; the client watches atomics and owns only its own host.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../support/actors.zig");

const model = pancake.ocapn.model;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;

const dial_opts: driver.SessionOptions = .{
    .frame_cap = 4096,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const FirstService = support_actors.StaticReplyValueActor("poke", "first service");
const SecondService = support_actors.StaticReplyValueActor("poke", "second service");

/// One server fiber: publish the durable service, hand the sturdyref URI to
/// the test, serve accepted sessions, and honor a removal request — every
/// host verb on this one thread.
fn ServeDurable(comptime Behavior: type) type {
    return struct {
        fn run(
            server: *driver.Server,
            allocator: std.mem.Allocator,
            uri_out: *?[]u8,
            published: *std.atomic.Value(bool),
            remove_requested: *std.atomic.Value(bool),
            removed: *std.atomic.Value(bool),
            done: *std.atomic.Value(bool),
        ) anyerror!void {
            const uri = try server.publishDurable(allocator, Behavior, .{});
            uri_out.* = uri;
            published.store(true, .release);

            var sessions: [4]?*driver.Session = .{ null, null, null, null };
            var count: usize = 0;
            defer for (sessions[0..count]) |s| if (s) |sess| sess.deinit();
            while (!done.load(.acquire)) {
                if (count < sessions.len and server.waitAcceptable(20) catch false) {
                    sessions[count] = server.accept() catch continue;
                    count += 1;
                }
                for (sessions[0..count]) |s| if (s) |sess| {
                    _ = sess.stepReadable(10) catch {};
                };
                if (remove_requested.load(.acquire) and !removed.load(.acquire)) {
                    const sturdy = try model.uri.parseSturdyref(allocator, uri);
                    defer model.uri.freeSturdyref(allocator, sturdy);
                    try server.removeDurable(sturdy.swissnum);
                    removed.store(true, .release);
                }
            }
        }
    };
}

test "durable publication: select-or-dial enlivens over the selected and the freshly dialed peer, and removal misses" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var done = std.atomic.Value(bool).init(false);

    var first = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer first.close() catch {};
    var second = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer second.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const first_designator = try allocator.dupe(u8, try first.localDesignator(&addr_buf));
    defer allocator.free(first_designator);

    var first_uri: ?[]u8 = null;
    defer if (first_uri) |uri| allocator.free(uri);
    var second_uri: ?[]u8 = null;
    defer if (second_uri) |uri| allocator.free(uri);
    var first_published = std.atomic.Value(bool).init(false);
    var second_published = std.atomic.Value(bool).init(false);
    var remove_requested = std.atomic.Value(bool).init(false);
    var removed = std.atomic.Value(bool).init(false);
    var no_remove = std.atomic.Value(bool).init(true);

    var first_serving = try io.concurrent(ServeDurable(FirstService).run, .{
        &first, allocator, &first_uri, &first_published, &remove_requested, &removed, &done,
    });
    var second_serving = try io.concurrent(ServeDurable(SecondService).run, .{
        &second, allocator, &second_uri, &second_published, &no_remove, &no_remove, &done,
    });
    defer {
        done.store(true, .release);
        second_serving.await(io) catch {};
        first_serving.await(io) catch {};
    }
    while (!first_published.load(.acquire) or !second_published.load(.acquire)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .real) catch {};
    }

    // The client dials only the first server. Enlivening the first sturdyref
    // must select that live dialed session rather than opening a second one.
    var dial_buf: [64]u8 = undefined;
    const client = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locator(&dial_buf, try tcp.parseDesignator(first_designator)), .ephemeral, dial_opts);
    defer client.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first_cap = try client.enlivenUri(first_uri.?);
    const first_reply = try client.call(first_cap, "poke", &.{}, arena);
    try std.testing.expect(first_reply == .fulfilled and first_reply.fulfilled == .string);
    try std.testing.expectEqualStrings("first service", first_reply.fulfilled.string);

    // The second sturdyref names a peer this host has never dialed: the same
    // verb dials it, proves the peer, and enlivens — the dial arm of
    // select-or-dial.
    const second_cap = try client.enlivenUri(second_uri.?);
    const second_reply = try client.call(second_cap, "poke", &.{}, arena);
    try std.testing.expect(second_reply == .fulfilled and second_reply.fulfilled == .string);
    try std.testing.expectEqualStrings("second service", second_reply.fulfilled.string);

    // Removal: a fresh client's lookup misses from now on, while everything
    // already issued keeps answering — the capability, and this client's own
    // session-cached enlivenment, which is issued authority, not discovery.
    remove_requested.store(true, .release);
    while (!removed.load(.acquire)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .real) catch {};
    }
    const late = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locator(&dial_buf, try tcp.parseDesignator(first_designator)), .ephemeral, dial_opts);
    defer late.deinit();
    try std.testing.expectError(driver.Error.FetchBroken, late.enlivenUri(first_uri.?));
    const still = try client.call(first_cap, "poke", &.{}, arena);
    try std.testing.expect(still == .fulfilled and still.fulfilled == .string);
    try std.testing.expectEqualStrings("first service", still.fulfilled.string);
    const cached = try client.enlivenUri(first_uri.?);
    const cached_reply = try client.call(cached, "poke", &.{}, arena);
    try std.testing.expect(cached_reply == .fulfilled and cached_reply.fulfilled == .string);
}
