//! `inproc` on HostRuntime through a completion resident (ADR-0202): two
//! runtimes on their own threads meet through one in-process exchange, and
//! the dialer fetches and calls across the bounded pipes.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;

const fixtures = @import("residents.zig");
const Treasure = fixtures.Treasure;
const frame_cap = fixtures.frame_cap;
const opts = fixtures.opts;

const inproc = net.inproc_completion;
const InprocBackend = inproc.CompletionBackend(net.Backend);
const Policy = inproc.ResidentPolicy(InprocBackend, net.tcp.CompletionPolicy(net.Backend));
const InprocResident = net.completion_resident.Resident(InprocBackend, Policy);

fn open(exchange: *inproc.Exchange) !InprocResident {
    return InprocResident.init(
        std.testing.allocator,
        try InprocBackend.init(std.testing.allocator, .{ .exchange = exchange }, 64, 16, frame_cap),
        .{},
    );
}

fn retire(resident: *InprocResident) void {
    resident.closeAndDrain(2_000) catch |err| std.debug.panic("inproc resident drain failed: {t}", .{err});
    resident.deinit();
}

fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("treasure", Treasure, .{});
    while (!done.load(.acquire)) {
        _ = session.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

test "inproc completion residents serve a fetch and a call between two runtimes" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var exchange = inproc.Exchange.init(allocator);
    defer exchange.deinit();

    var server_resident = try open(&exchange);
    defer retire(&server_resident);
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = model.transport.Known.inproc.metadata(),
        .resident = server_resident.resident(),
    }};
    var server = try driver.listen(allocator, io, .{ .residents = &providers }, model.transport.inproc, .{ .designator = "server" }, .ephemeral, opts);
    defer server.deinit();
    try std.testing.expectEqualStrings("server", (try server.advertisedLocator()).designator);

    var done = std.atomic.Value(bool).init(false);
    var server_future = try io.concurrent(serve, .{ server, &done });
    defer {
        done.store(true, .release);
        server_future.await(io) catch {};
    }

    var dialer_resident = try open(&exchange);
    defer retire(&dialer_resident);
    var dialer = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    defer dialer.deinit();
    _ = try dialer.addResident(model.transport.Known.inproc.metadata(), dialer_resident.resident());

    const session = try dialer.connectLocator(.{
        .transport = model.transport.inproc,
        .designator = "server",
        .hints = model.Hints.emptyFalse(),
    }, .inherit);
    const view = try driver.Session.adopt(&dialer, session);
    defer view.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const treasure = try view.fetch("treasure");
    const greeted = try view.call(treasure, "greet", &.{}, arena_state.allocator());
    try std.testing.expect(greeted == .fulfilled and greeted.fulfilled == .string);
    try std.testing.expectEqualStrings("hello from the exporter", greeted.fulfilled.string);
}
