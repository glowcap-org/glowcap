//! A whole CapTP conversation over the multiplexed resident (ADR-0024): the
//! three-party dial drives the seam's whole surface, the first connect
//! through the awaiting pump, and the redeem dial a give provokes *inside* a
//! blocking call, the nested connect wait, and the throttled test drives the
//! outbound retention contract: a frame larger than the write window survives
//! `would_block`, resumes on `ev_writable`, and never reorders.
//!
//! Defects it catches: with `handleResidentEvent`'s `ev_connect` arm
//! dropped, the dial hangs to `HandshakeTimedOut` and both tests fail. With
//! `pushPendingResident` resuming from offset zero, the throttled call dies on
//! a corrupt frame.

const std = @import("std");
const glowcap = @import("glowcap");
const support_actors = @import("../../support/actors.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const fixtures = @import("residents.zig");
const FakeResident = fixtures.FakeResident;
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const IgnoreSessionOpen = fixtures.IgnoreSessionOpen;
const Treasure = fixtures.Treasure;
const Introducer = fixtures.Introducer;
const prepareAcceptOwnershipRuntime = fixtures.prepareAcceptOwnershipRuntime;
const frame_cap = fixtures.frame_cap;
const opts = fixtures.opts;

fn exporterServe(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var first = try server.accept();
    defer first.deinit();
    _ = try first.publish("treasure", Treasure, .{});

    var second: ?*driver.Session = null;
    defer if (second) |s| s.deinit();

    while (!done.load(.acquire)) {
        if (second == null and try server.waitAcceptable(20)) {
            second = try server.accept();
            try second.?.attend();
        }
        _ = first.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

fn gifterServe(
    gifter: *driver.Server,
    exporter_designator: []const u8,
    done: *std.atomic.Value(bool),
) anyerror!void {
    const treasure_session = try gifter.runtime.connectLocator(.{
        .transport = model.transport.tcp,
        .designator = exporter_designator,
        .hints = model.Hints.emptyFalse(),
    }, .inherit);
    const treasure_view = try driver.Session.adopt(gifter.runtime, treasure_session);
    defer treasure_view.deinit();
    const treasure = try treasure_view.fetch("treasure");

    const view = try gifter.accept();
    defer view.deinit();
    _ = try view.publish("introducer", Introducer, .{ .treasure = treasure });
    while (!done.load(.acquire)) {
        _ = view.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

test "a resident-dialed session fetches, calls, and redeems a give through the resident (ADR-0024)" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var done = std.atomic.Value(bool).init(false);

    var exporter = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer exporter.deinit();
    var exporter_addr_buf: [64]u8 = undefined;
    const exporter_designator = try allocator.dupe(u8, try exporter.localDesignator(&exporter_addr_buf));
    defer allocator.free(exporter_designator);

    var gifter = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer gifter.deinit();
    const gifter_locator = try model.clonePeerLocator(allocator, try gifter.advertisedLocator());
    defer model.freePeerLocator(allocator, gifter_locator);

    var exporter_future = try io.concurrent(exporterServe, .{ exporter, &done });
    var gifter_future = try io.concurrent(gifterServe, .{ gifter, exporter_designator, &done });
    defer {
        done.store(true, .release);
        gifter_future.await(io) catch {};
        exporter_future.await(io) catch {};
    }

    // The recipient reaches everything through the fake resident: its dial
    // table holds no stream netlayer at all, so a stream fallback would fail
    // loudly with `UnknownTransport` instead of quietly rescuing the test.
    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    var recipient = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    defer recipient.deinit();
    _ = try recipient.addResident(
        model.transport.Known.tcp.metadata(),
        fake.multiplexedResident(),
    );

    const gifter_session = try recipient.connectLocator(gifter_locator, .inherit);
    const view = try driver.Session.adopt(&recipient, gifter_session);
    defer view.deinit();
    // The application started this dial itself, so no session introduced it.
    try std.testing.expect(fake.last_introducer == null);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const introducer = try view.fetch("introducer");
    const introduced = try view.call(introducer, "introduce", &.{}, arena);
    if (introduced == .broken) std.debug.print("introduce broke: {s}\n", .{introduced.broken});
    try std.testing.expect(introduced == .fulfilled);
    try std.testing.expect(introduced.fulfilled == .capability);

    // The redeem dial the give provoked also went through the resident: two
    // live resident connections, none of any other kind. That dial carried
    // the gifter as its introducer, named by the designator the gifter signed.
    try std.testing.expectEqual(@as(usize, 2), fake.conns.count());
    const last_introducer = fake.last_introducer orelse return error.TestExpectedIntroducer;
    try std.testing.expectEqualStrings(gifter_locator.designator, last_introducer[0..fake.last_introducer_len]);

    const greeted = try view.call(introduced.fulfilled.capability, "greet", &.{}, arena);
    try std.testing.expect(greeted == .fulfilled and greeted.fulfilled == .string);
    try std.testing.expectEqualStrings("hello from the exporter", greeted.fulfilled.string);
}

test "a frame larger than the write window survives would_block and resumes in order (ADR-0024)" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var done = std.atomic.Value(bool).init(false);

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const designator = try allocator.dupe(u8, try server.localDesignator(&addr_buf));
    defer allocator.free(designator);

    const Sink = support_actors.StaticReplyValueActor("take", "took");
    const serveOne = struct {
        fn run(srv: *driver.Server, latch: *std.atomic.Value(bool)) anyerror!void {
            var session = try srv.accept();
            defer session.deinit();
            _ = try session.publish("sink", Sink, .{});
            while (!latch.load(.acquire)) {
                _ = session.stepReadable(20) catch |err| switch (err) {
                    error.ConnectionClosed, error.ProtocolAbort => break,
                    else => |e| return e,
                };
            }
        }
    }.run;
    var server_future = try io.concurrent(serveOne, .{ server, &done });
    defer {
        done.store(true, .release);
        server_future.await(io) catch {};
    }

    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    var runtime = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(
        model.transport.Known.tcp.metadata(),
        fake.multiplexedResident(),
    );

    const session = try runtime.connectLocator(.{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .inherit);
    var foreign_runtime = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    defer foreign_runtime.deinit();
    try std.testing.expectError(
        driver.Error.SessionNotOwned,
        driver.Session.adopt(&foreign_runtime, session),
    );
    try std.testing.expectError(driver.Error.SessionNotOwned, foreign_runtime.releaseWire(session));
    const view = try driver.Session.adopt(&runtime, session);
    try std.testing.expectError(error.SessionAlreadyOwned, driver.Session.adopt(&runtime, session));
    defer view.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sink = try view.fetch("sink");

    // Throttle after the handshake so setup stays plain; the big-argument
    // call is what crosses the choked window.
    fake.throttle = true;
    const big = try arena.alloc(u8, 6000);
    @memset(big, 'x');
    const took = try view.call(sink, "take", &.{.{ .string = big }}, arena);
    try std.testing.expect(took == .fulfilled and took.fulfilled == .string);
    try std.testing.expectEqualStrings("took", took.fulfilled.string);

    // The window really refused mid-frame, and nothing stayed retained.
    try std.testing.expect(fake.write_blocks > 0);
    const wire = runtime.wires.get(session.peer_handle).?;
    try std.testing.expect(wire.link.pending == null);
}
