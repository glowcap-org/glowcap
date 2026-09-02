//! The byte-fed drive (ADR-0072) and its compose verbs: a `driver.Served`
//! owns no socket — the caller feeds inbound frames and drains outbound,
//! owning the loop — and serves identically to the socket path, including
//! `beginSendNamed`/`beginTellNamed` chains and their break stages.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;
const net = glowcap.net;
const syrup = glowcap.ocapn.codec.syrup;
const crypto = glowcap.foundation.crypto;

const harness = @import("harness.zig");
const handshake_budget = harness.handshake_budget;
const frame_cap = harness.frame_cap;
const dial_opts = harness.dial_opts;
const connectPlain = harness.connectPlain;
const acceptPlain = harness.acceptPlain;
const Greeter = harness.Greeter;
const HostedGreeter = harness.HostedGreeter;

// ── Byte-fed drive (ADR-0072) ────────────────────────────────────────────────
//
// A `driver.Served` owns no socket: the caller feeds inbound frames with
// `feedBorrowed` and drains outbound with `takeOutbound`, owning the loop
// itself. This is the sans-io driving mode `libglowcap_host` and a browser
// ride. The test shuttles a real eventual-send and its resolution between two
// byte-fed vats over an already-open in-memory session, with no `net.Connection`
// on either side, so the byte-fed path serves identically to the socket path.

const Adder = struct {
    n: i64,
    pub fn handle(self: *Adder, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "add")) return error.NoSuchMethod;
        self.n += try msg.argInt(0);
        return .{ .integer = self.n };
    }
};

fn captureFedInt(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const slot: *i64 = @ptrCast(@alignCast(ctx.?));
    slot.* = switch (resolution) {
        .fulfilled => |value| value.integer,
        .broken, .give => -1,
    };
}

/// Encode `from`'s pending outbound and hand every frame to `to`, borrowed. The
/// byte-fed analogue of the socket shuttle: no sockets, frames moved by value.
fn shuttleFed(from: *driver.Served, from_vat: *actors.Vat, to: *driver.Served, to_vat: *actors.Vat) !void {
    try from.driveFed(from_vat);
    while (from.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try to.feedBorrowed(to_vat, frame.view());
    }
}

test "byte-fed Served serves an eventual-send with no socket (ADR-0072)" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    // Both sides are byte-fed: no `net.Connection`, the test owns the loop.
    var server_vat = actors.Vat.init(allocator);
    defer server_vat.deinit();
    var server = driver.Served.over(allocator, &pair.p2);
    defer server.deinit(&server_vat);
    const adder = try server_vat.spawn(Adder, .{ .n = 10 });
    try server.port.bindExport(&server_vat, adder, 7);
    // Hand-wired pairing: the client addresses position 7 out-of-band, so the
    // bound position takes an explicit grant.
    try pair.p2.exportObject(7);
    try pair.p1.importObject(7);

    var client_vat = actors.Vat.init(allocator);
    defer client_vat.deinit();
    var client = driver.Served.over(allocator, &pair.p1);
    defer client.deinit(&client_vat);
    const remote: actors.Ref = .{ .far = model.FarRef.object(7) };
    const promise = try client.port.send(&client_vat, remote, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });

    var result: i64 = 0;
    try client.port.on(&client_vat, promise, .{ .ctx = &result, .func = captureFedInt });

    // The deliver flows client -> server (the server's `feedBorrowed` runs the
    // actor and encodes the resolve); the resolve flows server -> client (the
    // client's `feedBorrowed` fires the promise listener). No socket touched.
    try shuttleFed(&client, &client_vat, &server, &server_vat);
    try shuttleFed(&server, &server_vat, &client, &client_vat);

    try std.testing.expectEqual(@as(i64, 15), result);
}

test "byte-fed Served opens a keyed session from scratch and serves (ADR-0072)" {
    const allocator = std.testing.allocator;
    var p_server = engine.Peer.initNegotiating(allocator);
    defer p_server.deinit();
    var p_client = engine.Peer.initNegotiating(allocator);
    defer p_client.deinit();

    // Each side proactively signs and queues its own keyed start-session, as a
    // real handshake does; the whole exchange then runs byte-fed, no socket.
    const loc_s: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() };
    const loc_c: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:2", .hints = model.Hints.emptyFalse() };
    try p_server.sendKeyedStartSession(loc_s, crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x51))));
    try p_client.sendKeyedStartSession(loc_c, crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x52))));

    var server = driver.Served.over(allocator, &p_server);
    var server_vat = actors.Vat.init(allocator);
    defer server_vat.deinit();
    defer server.deinit(&server_vat);
    var client_vat = actors.Vat.init(allocator);
    defer client_vat.deinit();
    var client = driver.Served.over(allocator, &p_client);
    defer client.deinit(&client_vat);

    // Shuttle the handshake frames between the two byte-fed vats until both
    // sessions open — the full connection lifecycle, driven by the caller.
    var i: usize = 0;
    while (i < 16 and !(p_server.sessionIsOpen() and p_client.sessionIsOpen())) : (i += 1) {
        try shuttleFed(&client, &client_vat, &server, &server_vat);
        try shuttleFed(&server, &server_vat, &client, &client_vat);
    }
    try std.testing.expect(p_server.sessionIsOpen());
    try std.testing.expect(p_client.sessionIsOpen());

    // Serve real work over the byte-fed, self-opened session.
    const adder = try server_vat.spawn(Adder, .{ .n = 100 });
    try server.port.bindExport(&server_vat, adder, 9);
    try p_server.exportObject(9);
    try p_client.importObject(9);
    const remote: actors.Ref = .{ .far = model.FarRef.object(9) };
    const promise = try client.port.send(&client_vat, remote, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    var result: i64 = 0;
    try client.port.on(&client_vat, promise, .{ .ctx = &result, .func = captureFedInt });
    try shuttleFed(&client, &client_vat, &server, &server_vat);
    try shuttleFed(&server, &server_vat, &client, &client_vat);
    try std.testing.expectEqual(@as(i64, 105), result);
}

test "byte-fed compose: beginSendNamed chains fetch then send, and the fetch break keeps its stage" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    var server_vat = actors.Vat.init(allocator);
    defer server_vat.deinit();
    var server = driver.Served.over(allocator, &pair.p2);
    defer server.deinit(&server_vat);
    _ = try server.publish(&server_vat, "greeter", Greeter, .{});

    var client_vat = actors.Vat.init(allocator);
    defer client_vat.deinit();
    var client = driver.Served.over(allocator, &pair.p1);
    defer client.deinit(&client_vat);

    // Happy path: one begin, then pump — no shadow continuation in the caller.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var capture = driver.SettleCapture{ .arena = arena.allocator() };
    var flag = driver.SettleFlag{ .inner = .{ .ctx = &capture, .func = driver.SettleCapture.fire } };
    var pending: driver.PendingSend = undefined;
    try client.beginSendNamed(&client_vat, &pending, "greeter", .{ .verb = "greet", .args = &.{.{ .string = "carol" }} }, .{ .ctx = &flag, .func = driver.SettleFlag.fire });
    defer pending.deinit();

    var i: usize = 0;
    while (i < 8 and !flag.done) : (i += 1) {
        try shuttleFed(&client, &client_vat, &server, &server_vat);
        try shuttleFed(&server, &server_vat, &client, &client_vat);
    }
    try std.testing.expect(flag.done);
    try std.testing.expectEqual(driver.PendingSend.Stage.delivering, pending.stage);
    const settled = try capture.finish();
    try std.testing.expectEqualStrings("hello from the hosting vat", settled.fulfilled.string);

    // An unpublished name breaks at the fetch leg: the terminal fires the
    // fetch's own refusal and `stage` still reads `.fetching`.
    var broken_arena = std.heap.ArenaAllocator.init(allocator);
    defer broken_arena.deinit();
    var broken_capture = driver.SettleCapture{ .arena = broken_arena.allocator() };
    var broken_flag = driver.SettleFlag{ .inner = .{ .ctx = &broken_capture, .func = driver.SettleCapture.fire } };
    var broken_pending: driver.PendingSend = undefined;
    try client.beginSendNamed(&client_vat, &broken_pending, "nobody", .{ .verb = "greet", .args = &.{} }, .{ .ctx = &broken_flag, .func = driver.SettleFlag.fire });
    defer broken_pending.deinit();
    i = 0;
    while (i < 8 and !broken_flag.done) : (i += 1) {
        try shuttleFed(&client, &client_vat, &server, &server_vat);
        try shuttleFed(&server, &server_vat, &client, &client_vat);
    }
    try std.testing.expect(broken_flag.done);
    try std.testing.expectEqual(driver.PendingSend.Stage.fetching, broken_pending.stage);
    try std.testing.expectEqual(driver.Settled.broken, std.meta.activeTag(try broken_capture.finish()));
}

test "byte-fed compose: beginTellNamed fires void after the tell, and a cancel breaks the fetch leg" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    var server_vat = actors.Vat.init(allocator);
    defer server_vat.deinit();
    var server = driver.Served.over(allocator, &pair.p2);
    defer server.deinit(&server_vat);
    _ = try server.publish(&server_vat, "greeter", Greeter, .{});

    var client_vat = actors.Vat.init(allocator);
    defer client_vat.deinit();
    var client = driver.Served.over(allocator, &pair.p1);
    defer client.deinit(&client_vat);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var capture = driver.SettleCapture{ .arena = arena.allocator() };
    var flag = driver.SettleFlag{ .inner = .{ .ctx = &capture, .func = driver.SettleCapture.fire } };
    var pending: driver.PendingSend = undefined;
    try client.beginTellNamed(&client_vat, &pending, "greeter", .{ .verb = "greet", .args = &.{} }, .{ .ctx = &flag, .func = driver.SettleFlag.fire });
    defer pending.deinit();
    var i: usize = 0;
    while (i < 8 and !flag.done) : (i += 1) {
        try shuttleFed(&client, &client_vat, &server, &server_vat);
        try shuttleFed(&server, &server_vat, &client, &client_vat);
    }
    try std.testing.expect(flag.done);
    try std.testing.expectEqual(driver.PendingSend.Stage.delivering, pending.stage);
    const settled = try capture.finish();
    try std.testing.expectEqual(driver.Settled.fulfilled, std.meta.activeTag(settled));
    try std.testing.expectEqual(model.Argument.void, std.meta.activeTag(settled.fulfilled));

    // A cancel while the fetch is still in flight breaks the chain once, at
    // the fetch leg, with the cancel's own reason.
    var cancel_arena = std.heap.ArenaAllocator.init(allocator);
    defer cancel_arena.deinit();
    var cancel_capture = driver.SettleCapture{ .arena = cancel_arena.allocator() };
    var cancel_flag = driver.SettleFlag{ .inner = .{ .ctx = &cancel_capture, .func = driver.SettleCapture.fire } };
    var cancel_pending: driver.PendingSend = undefined;
    try client.beginSendNamed(&client_vat, &cancel_pending, "greeter", .{ .verb = "greet", .args = &.{} }, .{ .ctx = &cancel_flag, .func = driver.SettleFlag.fire });
    defer cancel_pending.deinit();
    client.port.breakFarVows("cancelled");
    try std.testing.expect(cancel_flag.done);
    try std.testing.expectEqual(driver.PendingSend.Stage.fetching, cancel_pending.stage);
    const cancelled = try cancel_capture.finish();
    try std.testing.expectEqualStrings("cancelled", cancelled.broken);
}
