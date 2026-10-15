//! Half-open handshakes in bulk, refused at the admission bound. A bounded
//! runtime whose open slots are all held by handshakes that never finish
//! refuses the next arrival without growing past the admitted shells.
//! Once the handshake deadline frees the slots, an honest session opens and calls.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const frame_cap = 8192;
const slots = 4;

const harness = @import("harness.zig");
const Treasure = harness.Treasure;
const DialRecorder = harness.DialRecorder;
const opts = harness.opts;

/// Accept one honest partner, publish the greeter, and serve until it leaves.
fn serveHonest(server: *driver.Server) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("treasure", Treasure, .{});
    try session.serve();
}

test "host runtime: a flood of half-open signed handshakes is refused at max_pending_opens while an honest session still opens and calls" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Never stepped, so a dial to one stays in its handshake and holds one
    // of the bounded runtime's open slots until the handshake deadline. The
    // host refuses a second dial to the same partner, so each slot gets its own.
    var silent: [slots + 1]*driver.Server = undefined;
    var silent_bufs: [slots + 1][64]u8 = undefined;
    var silent_designators: [slots + 1][tcp.designator_buf_len]u8 = undefined;
    var silent_locators: [slots + 1]model.PeerLocator = undefined;
    var opened: usize = 0;
    defer for (silent[0..opened]) |server| server.deinit();
    for (&silent, &silent_bufs, &silent_designators, &silent_locators) |*server, *buf, *designator, *locator| {
        server.* = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
        opened += 1;
        const address = try tcp.parseDesignator(try server.*.localDesignator(buf));
        locator.* = tcp.locatorFromAddress(designator, address);
    }

    var bounded = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, .{
        .frame_cap = frame_cap,
        .max_pending_opens = slots,
        .handshake = .{ .ms = 1_000 },
        .settle = .{ .ms = 10_000 },
    });
    defer bounded.deinit();
    var bounded_buf: [64]u8 = undefined;
    const bounded_address = try tcp.parseDesignator(try bounded.localDesignator(&bounded_buf));

    var recorder = DialRecorder{};
    for (silent_locators[0..slots], 0..) |locator, tag| try bounded.runtime.startDial(locator, .inherit, tag, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    // The next arrival is refused, and the runtime holds exactly the
    // admitted shells.
    try std.testing.expectError(driver.Error.PendingOpenLimitReached, bounded.runtime.connectLocator(silent_locators[slots], .inherit));
    try std.testing.expectEqual(@as(usize, slots), bounded.runtime.open_admissions);

    // The handshake deadline frees the slots without any session opening.
    var rounds: usize = 0;
    while (bounded.runtime.open_admissions != 0 and rounds < 500) : (rounds += 1) {
        try std.testing.expect(!try bounded.waitAcceptable(10));
    }
    try std.testing.expectEqual(@as(usize, 0), bounded.runtime.open_admissions);
    try std.testing.expect(recorder.opened_session == null and recorder.failed_err != null);

    // An honest session now opens, fetches the published capability, and
    // makes one call that returns within its ten second budget.
    var serve_future = try io.concurrent(serveHonest, .{bounded});
    var served = false;
    defer if (!served) serve_future.cancel(io) catch {};
    {
        var client_buf: [tcp.designator_buf_len]u8 = undefined;
        var client = try driver.connect(
            allocator,
            io,
            .{ .symbols = &.{.tcp} },
            tcp.locatorFromAddress(&client_buf, bounded_address),
            .ephemeral,
            opts,
        );
        defer client.deinit();
        const treasure = try client.fetch("treasure");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const reply = try client.call(treasure, "greet", &.{}, arena.allocator());
        try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
        try std.testing.expectEqualStrings("hello from the step server", reply.fulfilled.string);
    }
    try serve_future.await(io);
    served = true;
}
