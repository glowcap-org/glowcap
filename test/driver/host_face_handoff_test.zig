//! The front-door handoff proof (ADR-0090): a three-party give settles as a
//! live, callable capability *inside* the recipient's blocking `call`, with no
//! redeem verb in sight — the contract every binding's `Session` carries,
//! proven here for the owning native tier.
//!
//! Three hosts on TCP loopback. The exporter publishes `treasure`. The gifter
//! holds one `driver.PollHost` with two sessions — a dialed session to the
//! exporter (where it fetched the treasure) and an accepted session from the
//! recipient — and its introducer actor replies with the fetched capability,
//! which the host core turns into a signed give because the capability's home
//! is the *other* session. The recipient's `call` hears the give, and its own
//! pump answers the redeem: dials the exporter, withdraws, and settles the
//! call with the live capability. One extra `call` on that capability
//! proves it really reaches the exporter's actor.
//!
//! The gifter's single serve loop is also the multiplex proof: it serves the
//! recipient's fetch and the exporter session's deposit traffic from one
//! blocking wait spanning both wires.
//!
//! Validated against an injected defect: with the pump's redeem answer
//! sabotaged (`answerDial` reporting `dialFailed` unconditionally), the
//! introduce call settles broken and this test fails; restored, it passes.
//! A green run therefore proves the redeem path executed, not merely that
//! nothing crashed.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../support/actors.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;
const ip = std.Io.net;

const frame_cap = 8192;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Treasure = support_actors.StaticReplyValueActor("greet", "hello from the exporter");

/// Replies to `introduce` with the capability it was constructed around. The
/// reply's home is the gifter's *exporter* session, so the host core claims
/// it and originates a signed give instead of resolving it as-is.
const Introducer = struct {
    treasure: driver.Capability,

    pub fn handle(self: *Introducer, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "introduce")) return error.NoSuchMethod;
        return .{ .capability = self.treasure };
    }
};

/// The exporter: publish `treasure` on the first accepted session (the
/// gifter), then interleave serving with accepting the second session — the
/// recipient's redeem dial — and keep pumping until the latch drops. One
/// host under both accepts, so the withdraw on session two finds the gift the
/// deposit on session one recorded.
fn exporterServe(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var first = try server.accept();
    defer first.deinit();
    _ = try first.publish("treasure", Treasure, .{});

    var second: ?*driver.Session = null;
    defer if (second) |s| s.deinit();

    while (!done.load(.acquire)) {
        if (second == null and try server.waitAcceptable(20)) {
            second = try server.accept();
            // No publication on the withdrawing Port: the gift retained the
            // exact Host-Vat actor reached through the first Port and projects
            // that actor here. A swiss-name lookup would fail this proof.
        }
        _ = first.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

/// The gifter, whole, on its own thread — one thread drives one host (the
/// core's contract, held by its owner assert): build the host, dial the
/// exporter and fetch the treasure, accept the recipient, publish the
/// introducer around the fetched capability, and serve both wires from one
/// blocking wait until the latch drops.
fn gifterServe(
    allocator: std.mem.Allocator,
    io: std.Io,
    netlayers: []const net.netlayer.Netlayer,
    exporter_transport: []const u8,
    exporter_designator: []const u8,
    exporter_hint: []const u8,
    listener: net.netlayer.Listener,
    done: *std.atomic.Value(bool),
) anyerror!void {
    var designator_buf: [64]u8 = undefined;
    const bound = listener.localDesignator(&designator_buf);

    var host = try driver.PollHost.init(allocator, io, netlayers, .ephemeral, opts);
    defer host.deinit();
    try host.core.setSelfDesignator(bound);

    var hint_entry: [1]model.HintEntry = undefined;
    const treasure_session = try host.connectLocator(.{
        .transport = exporter_transport,
        .designator = exporter_designator,
        .hints = model.Hints.forDirectAddresses(exporter_hint, &hint_entry),
    });
    var treasure_view = driver.Session.view(&host, treasure_session);
    const treasure = try treasure_view.fetch("treasure");

    var hint_entries: [1]model.HintEntry = undefined;
    try host.core.setAdvertisedLocator(.{
        .transport = listener.transportName(),
        .designator = bound,
        .hints = model.Hints.forDirectAddresses(bound, &hint_entries),
    });
    const hs = try host.acceptWire(listener, listener.transportName());
    var view = driver.Session.view(&host, hs);
    _ = try view.publish("introducer", Introducer, .{ .treasure = treasure });
    while (!done.load(.acquire)) {
        _ = view.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

/// The listen half's redeem: a plain `driver.Server` accepts the recipient and
/// its accepted view calls out to a capability living on a third peer, so the
/// *server's* host must dial and redeem. Before the server's host carried its
/// own dial table this settled broken, which is the asymmetry with every
/// binding that ADR-0090 exists to remove.
fn serverSideRedeem(
    allocator: std.mem.Allocator,
    server: *driver.Server,
    exporter_designator: []const u8,
    done: *std.atomic.Value(bool),
) anyerror!void {
    defer done.store(true, .release);
    const accepted = try server.accept();
    defer accepted.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    // The accepted view fetches the introducer *from its partner* and calls
    // it; the reply is a give naming the exporter, and this host — built by
    // `driver.listen`, not by hand — dials and redeems inside the call.
    const introducer = try accepted.fetch("introducer");
    const introduced = try accepted.call(introducer, "introduce", &.{}, arena_state.allocator());
    if (introduced == .broken) std.debug.print("server-side redeem broke: {s}\n", .{introduced.broken});
    try std.testing.expect(introduced == .fulfilled);
    try std.testing.expect(introduced.fulfilled == .capability);

    const greeted = try accepted.call(introduced.fulfilled.capability, "greet", &.{}, arena_state.allocator());
    try std.testing.expect(greeted == .fulfilled and greeted.fulfilled == .string);
    try std.testing.expectEqualStrings("hello from the exporter", greeted.fulfilled.string);
    _ = exporter_designator;
}

test "front door handoff: a give settles live inside call, and the redeemed capability answers (ADR-0090)" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var done = std.atomic.Value(bool).init(false);

    // Exporter: a plain owning Server on its own thread.
    var exporter = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer exporter.close() catch {};
    var exporter_addr_buf: [64]u8 = undefined;
    const exporter_designator = try allocator.dupe(u8, try exporter.localDesignator(&exporter_addr_buf));
    defer allocator.free(exporter_designator);

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};

    // The gifter's listener is bound here so the recipient can learn the
    // address; the gifter host itself lives entirely on its thread.
    var gifter_listener = try tcp_resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    defer gifter_listener.close();
    var gifter_dial_buf: [64]u8 = undefined;
    const gifter_designator = gifter_listener.localDesignator(&gifter_dial_buf);

    var exporter_future = try io.concurrent(exporterServe, .{ &exporter, &done });
    var gifter_future = try io.concurrent(gifterServe, .{ allocator, io, &netlayers, model.transport.tcp, exporter_designator, "", gifter_listener, &done });
    defer {
        done.store(true, .release);
        gifter_future.await(io) catch {};
        exporter_future.await(io) catch {};
    }

    // The recipient: an ordinary one-call connect to the gifter. The call's
    // reply is a give; the settle wait answers the redeem dial to the
    // exporter and hands back the live capability.
    const recipient = try driver.connect(allocator, &netlayers, .{
        .transport = model.transport.tcp,
        .designator = gifter_designator,
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, opts);
    defer recipient.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const introducer = try recipient.fetch("introducer");
    const introduced = try recipient.call(introducer, "introduce", &.{}, arena);
    if (introduced == .broken) std.debug.print("introduce broke: {s}\n", .{introduced.broken});
    try std.testing.expect(introduced == .fulfilled);
    try std.testing.expect(introduced.fulfilled == .capability);
    const redeemed = introduced.fulfilled.capability;

    // The redeemed capability answers: this call routes over the exporter
    // session the recipient's own pump dialed during the wait above.
    const greeted = try recipient.call(redeemed, "greet", &.{}, arena);
    try std.testing.expect(greeted == .fulfilled and greeted.fulfilled == .string);
    try std.testing.expectEqualStrings("hello from the exporter", greeted.fulfilled.string);
}

test "front door handoff over keyed-tcp: the give's hint survives the redeem dial (ADR-0090)" {
    // The tcp test above cannot see the redeem dial's `direct-addresses`
    // hint, because address transports ignore it. Keyed-tcp cannot dial
    // without it: the exporter's signed hello names its key as designator and
    // its bound `host:port` as the hint, the give carries both, and the
    // recipient's pump must hand both to the netlayer. This is the wire the
    // hint-dropping regression broke.
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const foundation = pancake.foundation;
    const exporter_secret = foundation.crypto.SecretKey.fromSeed([_]u8{0x5b} ** foundation.crypto.SEED_BYTES);
    var keyed_resident = net.tcp_keyed.Resident{ .io = io, .public_key = exporter_secret.publicKey() };
    var tcp_resident = tcp.Resident{ .io = io };
    var done = std.atomic.Value(bool).init(false);

    // Exporter: an owning Server on keyed-tcp, signing with the key its
    // designator is. `Server.accept` advertises the bound address through the
    // listener's hint, which is what the give must carry.
    var exporter = try driver.listen(allocator, keyed_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .{ .keyed = exporter_secret }, opts);
    defer exporter.close() catch {};
    var exporter_key_buf: [128]u8 = undefined;
    const exporter_designator = try allocator.dupe(u8, try exporter.localDesignator(&exporter_key_buf));
    defer allocator.free(exporter_designator);
    var exporter_hint_buf: [64]u8 = undefined;
    const exporter_hint = try allocator.dupe(u8, try exporter.listener.localDirectAddresses(&exporter_hint_buf));
    defer allocator.free(exporter_hint);
    try std.testing.expect(exporter_hint.len > 0);

    const netlayers = [_]net.netlayer.Netlayer{ tcp_resident.netlayer(), keyed_resident.netlayer() };

    var gifter_listener = try tcp_resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    defer gifter_listener.close();
    var gifter_dial_buf: [64]u8 = undefined;
    const gifter_designator = gifter_listener.localDesignator(&gifter_dial_buf);

    var exporter_future = try io.concurrent(exporterServe, .{ &exporter, &done });
    var gifter_future = try io.concurrent(gifterServe, .{ allocator, io, &netlayers, net.tcp_keyed.transport_name, exporter_designator, exporter_hint, gifter_listener, &done });
    defer {
        done.store(true, .release);
        gifter_future.await(io) catch {};
        exporter_future.await(io) catch {};
    }

    const recipient = try driver.connect(allocator, &netlayers, .{
        .transport = model.transport.tcp,
        .designator = gifter_designator,
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, opts);
    defer recipient.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const introducer = try recipient.fetch("introducer");
    const introduced = try recipient.call(introducer, "introduce", &.{}, arena);
    if (introduced == .broken) std.debug.print("keyed introduce broke: {s}\n", .{introduced.broken});
    try std.testing.expect(introduced == .fulfilled);
    try std.testing.expect(introduced.fulfilled == .capability);
    const redeemed = introduced.fulfilled.capability;

    const greeted = try recipient.call(redeemed, "greet", &.{}, arena);
    try std.testing.expect(greeted == .fulfilled and greeted.fulfilled == .string);
    try std.testing.expectEqualStrings("hello from the exporter", greeted.fulfilled.string);
}

test "driver Server can replace listener-derived reachability with deployment routing" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = pancake.foundation.crypto.SecretKey.fromSeed([_]u8{0x6b} ** pancake.foundation.crypto.SEED_BYTES);
    var resident = net.tcp_keyed.Resident{ .io = io, .public_key = secret.publicKey() };
    var server = try driver.listen(
        allocator,
        resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .{ .keyed = secret },
        opts,
    );
    defer server.close() catch {};

    var designator_buf: [128]u8 = undefined;
    const designator = try server.localDesignator(&designator_buf);
    var hints: [1]model.HintEntry = undefined;
    try server.setAdvertisedLocator(.{
        .transport = net.tcp_keyed.transport_name,
        .designator = designator,
        .hints = model.Hints.forDirectAddresses("proxy.example:443", &hints),
    });

    const advertised = server.advertisedLocator();
    try std.testing.expectEqualStrings(designator, advertised.designator);
    try std.testing.expectEqualStrings("proxy.example:443", advertised.hints.entries[0].value.string);
    try std.testing.expectError(error.TransportMismatch, server.setAdvertisedLocator(.{
        .transport = model.transport.tcp,
        .designator = "proxy.example:443",
        .hints = model.Hints.emptyFalse(),
    }));
}

test "front door handoff: a listening server redeems too, so both halves match every binding (ADR-0090)" {
    // The connect half's proof is above. This is the accept half: the party
    // that *listens* receives an introduction and redeems it, which requires
    // its host to hold a dial table of its own. `driver.listen` gives it one.
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var done = std.atomic.Value(bool).init(false);

    var exporter = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer exporter.close() catch {};
    var exporter_addr_buf: [64]u8 = undefined;
    const exporter_designator = try allocator.dupe(u8, try exporter.localDesignator(&exporter_addr_buf));
    defer allocator.free(exporter_designator);

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};

    // The party under test: an ordinary `driver.listen` server.
    var redeemer = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer redeemer.close() catch {};
    var redeemer_addr_buf: [64]u8 = undefined;
    const redeemer_designator = try allocator.dupe(u8, try redeemer.localDesignator(&redeemer_addr_buf));
    defer allocator.free(redeemer_designator);

    var exporter_future = try io.concurrent(exporterServe, .{ &exporter, &done });
    var redeem_future = try io.concurrent(serverSideRedeem, .{ allocator, &redeemer, exporter_designator, &done });
    var joined = false;
    defer {
        if (!joined) {
            done.store(true, .release);
            redeem_future.await(io) catch {};
            exporter_future.await(io) catch {};
        }
    }

    // The gifter dials both peers, so the party under test is the accepting
    // half, and publishes the introducer on the session it dialed to it.
    try dialingGifter(allocator, io, &netlayers, exporter_designator, redeemer_designator, &done);
    try redeem_future.await(io);
    done.store(true, .release);
    try exporter_future.await(io);
    joined = true;
}

/// A gifter that *dials* both parties: it fetches the treasure from the
/// exporter and publishes an introducer on the session it dialed to the
/// redeeming server, so the redeemer meets the give as the accepting half.
fn dialingGifter(
    allocator: std.mem.Allocator,
    io: std.Io,
    netlayers: []const net.netlayer.Netlayer,
    exporter_designator: []const u8,
    redeemer_designator: []const u8,
    done: *std.atomic.Value(bool),
) anyerror!void {
    var host = try driver.PollHost.init(allocator, io, netlayers, .ephemeral, opts);
    defer host.deinit();

    const treasure_session = try host.connectLocator(.{
        .transport = model.transport.tcp,
        .designator = exporter_designator,
        .hints = model.Hints.emptyFalse(),
    });
    var treasure_view = driver.Session.view(&host, treasure_session);
    const treasure = try treasure_view.fetch("treasure");

    const to_redeemer = try host.connectLocator(.{
        .transport = model.transport.tcp,
        .designator = redeemer_designator,
        .hints = model.Hints.emptyFalse(),
    });
    var redeemer_view = driver.Session.view(&host, to_redeemer);
    _ = try redeemer_view.publish("introducer", Introducer, .{ .treasure = treasure });

    while (!done.load(.acquire)) {
        _ = redeemer_view.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}
