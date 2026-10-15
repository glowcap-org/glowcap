//! `onion` on HostRuntime through completion residents (ADR-0202), over the
//! fake Tor daemon: the listening resident binds a loopback listener and
//! publishes it, advertises the service id Tor named, and a dialing resident
//! reaches it through SOCKS. What the fake cannot prove, that a real Tor
//! answers the same way, is `test/support/onion_fake_daemon.zig`'s caveat.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const support_actors = @import("../../support/actors.zig");
const fake = @import("../../support/onion_fake_daemon.zig");

const supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();
const OnionBackend = if (supported) net.OnionBackend else void;
const OnionResident = if (supported)
    net.completion_resident.Resident(OnionBackend, net.onion.completion.ResidentPolicy(OnionBackend, net.tcp.CompletionPolicy(net.Backend)))
else
    void;

const frame_cap = 4096;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const greeting = "hello from an onion resident";
const Greeter = support_actors.StaticReplyValueActor("greet", greeting);

fn retire(resident: *OnionResident) void {
    resident.closeAndDrain(2_000) catch |err| std.debug.panic("onion resident drain failed: {t}", .{err});
    resident.deinit();
}

fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    while (!done.load(.acquire)) {
        _ = session.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

// The publish conversation is a pending setup (ADR-0193): the listen
// admits at once, the loop keeps serving while the control conversation
// runs, and the listener event arrives when the service exists. The delayed
// fake control reply makes the order deterministic: a plain dial through
// the same resident completes while the publish is still running.
test "onion listen admits pending and the loop serves a dial during its setup" {
    if (!supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();
    daemon.control_delay_ms = 50;
    const socks = try net.tcp.parseDesignator(daemon.socksText());
    const control = try net.tcp.parseDesignator(daemon.controlText());

    var resident = try OnionResident.init(allocator, OnionBackend.initOnion(
        allocator,
        try net.Backend.init(allocator, 64, 16, frame_cap),
        .{ .socks = socks, .control = control, .setup_timeout_ms = 5_000 },
    ), .{});
    defer retire(&resident);
    const mux = resident.resident();

    const listen_outcome = mux.acceptor().?.listen(7, net.onion.transport_name, .{
        .designator = "",
        .options = .inherit,
    });
    var attempt = switch (listen_outcome) {
        .admitted => |admitted| switch (admitted) {
            .pending => |pending| pending,
            else => return error.ListenAdmittedSynchronously,
        },
        .failed => |failure| return failure.cause,
    };

    // A plain dial through the same resident, aimed at the control port
    // itself: connecting to it needs nothing from the publish conversation.
    const dial_locator = try model.clonePeerLocator(allocator, .{
        .transport = model.transport.tcp,
        .designator = daemon.controlText(),
        .hints = model.Hints.emptyFalse(),
    });
    defer model.freePeerLocator(allocator, dial_locator);
    switch (mux.dialer().?.startDial(9, dial_locator, .inherit, .application)) {
        .admitted => {},
        .failed => |failure| return failure.chain.cause,
    }

    // Pump until the listener event, collecting the order the records
    // arrived in. The dial's connect record must precede it.
    var dial_connected = false;
    var turns: usize = 0;
    while (turns < 2_000) : (turns += 1) {
        var event_buf: [8]net.multiplexed_resident.ReadyEvent = undefined;
        const events = try mux.drainReady(&event_buf);
        for (events) |event| {
            if (event.events & net.multiplexed_resident.ev_connect != 0) dial_connected = true;
            if (event.events & net.multiplexed_resident.ev_listen != 0) {
                try std.testing.expect(event.subject == 7);
                try std.testing.expect(dial_connected);
                switch (attempt.finish()) {
                    .ready => {},
                    .failed => |failure| return failure.cause,
                }
                return;
            }
        }
        // The runtime's park: staged work reaches the kernel before the wait.
        mux.beforeWait(.park);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
    return error.PublishNeverFinished;
}

test "onion listens and dials on completion residents through Tor's SOCKS and control ports" {
    if (!supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();
    const socks = try net.tcp.parseDesignator(daemon.socksText());
    const control = try net.tcp.parseDesignator(daemon.controlText());

    var server_resident = try OnionResident.init(allocator, OnionBackend.initOnion(
        allocator,
        try net.Backend.init(allocator, 64, 16, frame_cap),
        .{ .socks = socks, .control = control },
    ), .{});
    defer retire(&server_resident);
    const server_providers = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = model.transport.Known.onion.metadata(),
        .resident = server_resident.resident(),
    }};
    var server = try driver.listen(allocator, io, .{ .residents = &server_providers }, model.transport.onion, .{ .designator = "" }, .ephemeral, opts);
    defer server.deinit();

    const advertised = try model.clonePeerLocator(allocator, try server.advertisedLocator());
    defer model.freePeerLocator(allocator, advertised);
    try std.testing.expectEqualStrings(model.transport.onion, advertised.transport);
    try std.testing.expectEqualStrings(fake.service_id, advertised.designator);
    try std.testing.expectEqual(@as(usize, 0), advertised.hints.entries.len);
    // The service forwards to the loopback listener the resident bound.
    try std.testing.expect(std.mem.startsWith(u8, daemon.lastForwardTarget(), "127.0.0.1:"));

    var done = std.atomic.Value(bool).init(false);
    var server_future = try io.concurrent(serve, .{ server, &done });
    var splice = try io.concurrent(fake.Daemon.spliceDial, .{daemon});
    defer {
        done.store(true, .release);
        server_future.await(io) catch {};
    }

    var client_resident = try OnionResident.init(allocator, OnionBackend.initOnion(
        allocator,
        try net.Backend.init(allocator, 64, 16, frame_cap),
        .{ .socks = socks },
    ), .{});
    defer retire(&client_resident);
    {
        var client = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
        defer client.deinit();
        _ = try client.addResident(model.transport.Known.onion.metadata(), client_resident.resident());
        const hs = try client.connectLocator(advertised, .inherit);
        const view = try driver.Session.adopt(&client, hs);
        defer view.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const greeter = try view.fetch("greeter");
        const reply = try view.call(greeter, "greet", &.{}, arena.allocator());
        try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
        try std.testing.expectEqualStrings(greeting, reply.fulfilled.string);
    }
    try splice.await(io);
}

test "an onion listen names no designator and needs a loopback platform" {
    if (!supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const Policy = net.onion.completion.ResidentPolicy(OnionBackend, net.tcp.CompletionPolicy(net.Backend));
    const socks = try net.tcp.parseDesignator("127.0.0.1:9050");

    var backend = OnionBackend.initOnion(allocator, try net.Backend.init(allocator, 8, 2, 64), .{ .socks = socks });
    defer backend.deinit();
    try std.testing.expectError(error.InvalidAddress, Policy.listenTarget(&backend, model.transport.onion, .{ .designator = fake.service_id }));
    _ = try Policy.listenTarget(&backend, model.transport.onion, .{ .designator = "" });
    // Plain TCP still listens on the same backend.
    try std.testing.expect((try Policy.listenTarget(&backend, model.transport.tcp, .{ .designator = "127.0.0.1:4242" })) == .platform);

    var wide = OnionBackend.initOnion(allocator, try net.Backend.initWithListenerIp4(allocator, 8, 2, 64, .{ 0, 0, 0, 0 }), .{ .socks = socks });
    defer wide.deinit();
    try std.testing.expectError(error.ListenerNotForwardable, Policy.listenTarget(&wide, model.transport.onion, .{ .designator = "" }));
}
