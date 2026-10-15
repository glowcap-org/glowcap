//! Owning-tier actor reclamation (ADR-0101): releasing the last application
//! handle of a spawned capability reclaims its actor while the session stays
//! open, before Host teardown, and the `Hosting` adapter forwards the
//! behavior's state deinit so the reclaim is observable. The Vat-tier root
//! mechanics live in `test/actors/actor_roots_test.zig`. The alias, gift, and
//! session-closure roots in `test/driver/core_host/`.

const std = @import("std");
const glowcap = @import("glowcap");
const support_actors = @import("../support/actors.zig");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const tcp = net.tcp;

const dial_opts: driver.SessionOptions = .{
    .frame_cap = 4096,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Greeter = support_actors.StaticReplyValueActor("greet", "still serving");

/// A Value-shaped probe whose state deinit raises a flag: the observable
/// moment the Vat let go of the reclaimed actor.
const Probe = struct {
    freed: *bool,

    pub fn handle(self: *Probe, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        _ = self;
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "ping")) return error.NoSuchMethod;
        return .{ .string = "pong" };
    }

    pub fn deinit(self: *Probe, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.freed.* = true;
    }
};

fn hostOnce(server: *driver.Server) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

test "releasing the last handle reclaims a spawned actor while its session stays open" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));
    var host_future = try io.concurrent(hostOnce, .{server});

    const client_result = clientHalf(allocator, io, address);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

fn clientHalf(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var freed = false;
    const probe = try session.spawn(Probe, .{ .freed = &freed });
    const reply = try session.call(probe, "ping", &.{}, arena);
    try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
    try std.testing.expectEqualStrings("pong", reply.fulfilled.string);

    // The handle is the actor's only root: releasing it retires the row, and
    // the next local turn boundary frees the state. The session stays open.
    try session.release(probe);
    var boundary_freed = false;
    const boundary = try session.spawn(Probe, .{ .freed = &boundary_freed });
    _ = try session.call(boundary, "ping", &.{}, arena);
    try std.testing.expect(freed);

    // Still open: the partner's published greeter answers after the reclaim.
    const greeter = try session.fetch("greeter");
    const greeting = try session.call(greeter, "greet", &.{}, arena);
    try std.testing.expect(greeting == .fulfilled and greeting.fulfilled == .string);
    try std.testing.expectEqualStrings("still serving", greeting.fulfilled.string);
}
