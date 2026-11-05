//! A claim that runs between steps, after the application released its
//! Session inside a callback but before that release could finish, finds no
//! exporter. The release waits because the partner stopped reading, so the
//! wire and the imports it exported stay live across steps. A claim there
//! would hand out a session the next step frees.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const harness = @import("harness.zig");
const Treasure = harness.Treasure;
const opts = harness.opts;

/// Keeps the capability its one `hold` argument names: an import the serving
/// session exported.
const HoldImport = struct {
    held: *?driver.Capability,

    pub fn handle(self: *HoldImport, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        const verb = selector orelse return error.NoSuchMethod;
        if (!std.mem.eql(u8, verb, "hold")) {
            ht.releaseArguments(args);
            return error.NoSuchMethod;
        }
        self.held.* = try args.capability(0);
        return .{ .void = {} };
    }
};

/// Drops the serving Session from inside a local turn.
const DropOwned = struct {
    owned: *?*driver.Session,

    pub fn handle(self: *DropOwned, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        _ = selector;
        const session = self.owned.* orelse return error.SessionAlreadyDropped;
        self.owned.* = null;
        session.deinit();
        return .{ .void = {} };
    }
};

/// Hand the server one local object, then hold the connection without
/// reading until told to stop.
fn holdThenStall(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress, stop: *const std.atomic.Value(bool)) !void {
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&designator_buf, address), .ephemeral, opts);
    defer session.deinit();
    const holder = try session.fetch("holder");
    const local = try session.spawn(Treasure, .{});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try session.call(holder, "hold", &.{.{ .capability = local }}, arena.allocator());
    while (!stop.load(.acquire))
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .real) catch {};
}

/// Call `drop` on the server's published dropper, from a partner that reads.
fn callDrop(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress) !void {
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&designator_buf, address), .ephemeral, opts);
    defer session.deinit();
    const dropper = try session.fetch("dropper");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try session.call(dropper, "drop", &.{}, arena.allocator());
}

fn stepQuietly(runtime: *driver.HostRuntime, timeout_ms: i32) !void {
    _ = runtime.stepAny(timeout_ms) catch |err| switch (err) {
        error.ConnectionClosed, error.ProtocolAbort => {},
        else => |other| return other,
    };
}

test "a reference claim between steps refuses an exporter Session released inside a callback" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, harness.steppedQuiet());
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));
    var stop = std.atomic.Value(bool).init(false);
    var client = try io.concurrent(holdThenStall, .{ allocator, io, address, &stop });
    defer {
        stop.store(true, .release);
        // best-effort: the client's session ends with the cancelled server side.
        client.await(io) catch {};
    }

    var owned: ?*driver.Session = try server.accept();
    errdefer if (owned) |session| session.deinit();
    var held: ?driver.Capability = null;
    _ = try owned.?.publish("holder", HoldImport, .{ .held = &held });
    try owned.?.attend();
    const session = owned.?;
    const released = session.hs;
    const peer_handle = released.peer_handle;
    var rounds: usize = 0;
    while (held == null and rounds < 1_000) : (rounds += 1) try stepQuietly(server.runtime, 10);
    const import = held orelse return error.TestUnexpectedResult;

    // Fill the resident and both socket buffers toward a partner that has
    // stopped reading, so the session's close must wait on the resident.
    const payload: [7_000]u8 = @splat('x');
    var sent: usize = 0;
    var refused_in_a_row: usize = 0;
    while (refused_in_a_row < 200 and sent < 4_000) {
        if (session.tell(import, "greet", &.{.{ .string = &payload }})) {
            sent += 1;
            refused_in_a_row = 0;
        } else |err| {
            if (err != error.OutboundBackpressure) return err;
            refused_in_a_row += 1;
            try stepQuietly(server.runtime, 1);
        }
    }

    try std.testing.expect(refused_in_a_row == 200);

    // A second partner's call runs the behavior that drops the first Session.
    var dropping_client = try io.concurrent(callDrop, .{ allocator, io, address });
    // best-effort: the dropping partner's own result is not what this proves.
    defer dropping_client.await(io) catch {};
    const dropping_session = try harness.acceptWhileStepping(server.runtime, server);
    defer dropping_session.deinit();
    _ = try dropping_session.publish("dropper", DropOwned, .{ .owned = &owned });
    try dropping_session.attend();
    rounds = 0;
    while (owned != null and rounds < 1_000) : (rounds += 1) try stepQuietly(server.runtime, 10);
    try std.testing.expect(owned == null);
    // The window this proves: the release waits on the unsent bytes, so the
    // wire and its import are still live between steps.
    try std.testing.expect(server.runtime.wires.get(peer_handle) != null);
    try std.testing.expect(server.runtime.deferred_session_releases != null);

    try std.testing.expectEqual(null, try server.runtime.claimReferenceExporter(import.raw()));
    try std.testing.expectError(error.SessionNotOwned, server.runtime.claimExporterSession(released));

    stop.store(true, .release);
    rounds = 0;
    while (server.runtime.wires.get(peer_handle) != null and rounds < 1_000) : (rounds += 1) try stepQuietly(server.runtime, 10);
    try std.testing.expect(server.runtime.wires.get(peer_handle) == null);
}
