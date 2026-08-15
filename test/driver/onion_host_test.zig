//! Host-tier onion loopback proof over the fake Tor daemon.

const std = @import("std");
const pancake = @import("pancake");

const driver = pancake.driver;
const model = pancake.ocapn.model;
const net = pancake.net;
const onion = net.onion;
const support_actors = @import("../support/actors.zig");
const fake = @import("../support/onion_fake_daemon.zig");

const dial_opts: driver.SessionOptions = .{
    .frame_cap = 4096,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const greeting = "hello from an onion service";
const Greeter = support_actors.StaticReplyValueActor("greet", greeting);

fn hostOnce(server: *driver.Server) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

test "onion at the host tier: publish, dial, fetch, and call with no Tor" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    var host_res: onion.Resident = .{ .io = io, .config = .{
        .socks = daemon.socksText(),
        .control_endpoint = daemon.controlText(),
    } };
    var server = try driver.listen(allocator, host_res.netlayer(), .{ .designator = "" }, .ephemeral, dial_opts);
    defer server.deinit();

    var designator_buf: [128]u8 = undefined;
    const designator = try server.localDesignator(&designator_buf);
    try std.testing.expectEqualStrings(fake.service_id, designator);

    var empty: [0]u8 = .{};
    try std.testing.expectEqual(
        @as(?usize, fake.service_key.len),
        try server.restorationState(&empty),
    );
    var short: [fake.service_key.len - 1]u8 = @splat(0xa5);
    try std.testing.expectEqual(
        @as(?usize, fake.service_key.len),
        try server.restorationState(&short),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** short.len), &short);
    var restoration_key: [fake.service_key.len]u8 = undefined;
    try std.testing.expectEqual(
        @as(?usize, fake.service_key.len),
        try server.restorationState(&restoration_key),
    );
    try std.testing.expectEqualStrings(fake.service_key, &restoration_key);

    var host_future = try io.concurrent(hostOnce, .{server});
    var splice = try io.concurrent(fake.Daemon.spliceDial, .{daemon});

    const client_result = clientHalf(allocator, io, daemon.socksText());
    const host_result = host_future.await(io);
    try splice.await(io);
    try client_result;
    try host_result;
}

fn clientHalf(allocator: std.mem.Allocator, io: std.Io, socks: []const u8) !void {
    var res: onion.Resident = .{ .io = io, .config = .{ .socks = socks } };
    const layers = [_]net.netlayer.Netlayer{res.netlayer()};
    var session = try driver.connect(allocator, &layers, .{
        .transport = onion.transport_name,
        .designator = fake.service_id,
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const greeter = try session.fetch("greeter");
    const reply = try session.call(greeter, "greet", &.{}, arena_state.allocator());
    try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
    try std.testing.expectEqualStrings(greeting, reply.fulfilled.string);
}
