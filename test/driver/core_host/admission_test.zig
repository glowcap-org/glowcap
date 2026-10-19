//! Session admission and its notifications: transport profiles own
//! extension semantics, the iroh dial pin refuses a wrong-identity hello,
//! one flush and one close per session, reserved notifications stay
//! allocation-free, and partner aborts retire without an echo.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const FairCounter = harness.FairCounter;
const Vendor = harness.Vendor;
const Introducer = harness.Introducer;
const host_pair = harness.host_pair;
const handshake_support = harness.handshake_support;
const Pair = harness.Pair;
const shuttle = harness.shuttle;
const shuttleAll = harness.shuttleAll;
const tcpLocator = harness.tcpLocator;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const publishAndOpenAcceptedOver = harness.publishAndOpenAcceptedOver;
const tcpSturdyref = harness.tcpSturdyref;
const onionLocator = harness.onionLocator;
const onionSturdyref = harness.onionSturdyref;
const ParkedDial = harness.ParkedDial;
const drainActions = harness.drainActions;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const CapturedString = harness.CapturedString;
const openPair = harness.openPair;
const retireClosingSession = harness.retireClosingSession;
const retireClosedSession = harness.retireClosedSession;
const Tagged = harness.Tagged;
const keyedDesignator = harness.keyedDesignator;
const TraceLog = harness.TraceLog;
const SessionOpenFailingAllocator = harness.SessionOpenFailingAllocator;
const TaggedRow = harness.TaggedRow;
const PublicationProbe = harness.PublicationProbe;

test "Host aggregate footprint and supported verb shapes stay within their budgets" {
    try std.testing.expect(Host.InitError == error{InvalidHostWorkQuantum});
    try std.testing.expect(Host.RuntimeAdoptionError == error{ ReenteredHost, HostClosing, HostNotQuiescent });
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(Host.LifecyclePhase).@"enum".field_names.len);
    try std.testing.expectEqual(@as(usize, 10), @typeInfo(Host.Options).@"struct".field_names.len);

    const set_session_limits: *const fn (*Host, ?usize, ?usize, ?usize, ?u32) error{ ReenteredHost, WrongThread, HostClosing }!void = &Host.setSessionLimits;
    const flush_session: *const fn (*Host, *HostSession) anyerror!void = &Host.flushSession;
    const fetch: *const fn (*Host, *HostSession, []const u8) anyerror!u64 = &Host.fetch;
    const queue_fetch: *const fn (*Host, *HostSession, []const u8) anyerror!u64 = &Host.queueFetch;
    const listen: *const fn (*Host, *HostSession, model.Reference) anyerror!u64 = &Host.listenTo;
    const queue_listen: *const fn (*Host, *HostSession, model.Reference) anyerror!u64 = &Host.queueListenTo;
    const listen_capability: *const fn (*Host, *HostSession, driver.core.Capability) anyerror!u64 = &Host.listenToCapability;
    const queue_listen_capability: *const fn (*Host, *HostSession, driver.core.Capability) anyerror!u64 = &Host.queueListenToCapability;
    const set_trace: *const fn (*Host, ?driver.core.trace.Sink) error{ ReenteredHost, WrongThread }!void = &Host.setTrace;
    const with_frame_cap: *const fn (usize) Host.Options = &Host.Options.withFrameCap;
    const frame_cap_method: *const fn (Host.Options) usize = &Host.Options.frameCap;
    const outbound_high_water: *const fn (Host.Options) usize = &Host.Options.outboundHighWaterBytes;
    const complete_pending_work: *const fn (*Host.PendingWorkLease) void = &Host.PendingWorkLease.complete;
    _ = .{
        set_session_limits,
        flush_session,
        fetch,
        queue_fetch,
        listen,
        queue_listen,
        listen_capability,
        queue_listen_capability,
        set_trace,
        with_frame_cap,
        frame_cap_method,
        outbound_high_water,
        complete_pending_work,
    };
    // Per-Host, not per-session, so a word here is a process cost, not a
    // 500k-session withdrawal. Stated under runtime safety, where each
    // embedded `std.ArrayList` header carries std's one-word
    // `pointer_stability` lock: 72 of these bytes, and each hash map carries
    // one more. ADR-0017's parked Node actions add 32: a map header that
    // costs a session under no pressure nothing, and the Node's one-word
    // count of the queue seats those actions return to. The work quantum is
    // a plain count, so it carries no optional tag word. ADR-0007 adds one
    // provider pointer (8 bytes per Host); the engine resolver keeps its
    // existing callback slot and sessions gain no fields. ADR-0007 adds a
    // 16-byte arena state to the last completion; sessions stay unchanged.
    // ADR-0058 adds 32 to the Host's Vat: the list of ingresses with sends
    // staged by the running turn, and that turn's failure. Staging sits on the
    // Vat so sessions pay nothing for it. ADR-0058 adds 104 more: the Vat's
    // list of layers waiting on that turn's outcome, the Host's lowering
    // receipts held until it, and the Node's batches staged for it. A
    // session's Peer gains one flag and stays within its struct budget.
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    // A public local completion has no peer. Its diagnostic presence tag
    // adds one word to each action seat and the Host's last-action storage.
    // Opaque callbacks carry archive-independent failure text. The Vat's
    // optional slice adds 16 bytes to the former error-code storage.
    // One Vat-wide callback identity makes owning forwarding recognizable
    // across Zig archives without expanding each listener or session.
    // Shared enlivenment adds one Host-wide map (24 bytes). Session shells
    // and existing vow rows gain no storage; groups exist only during fetches.
    // Rollback reserves failure notifications in one Vat-wide list and count
    // (40 bytes). Each pending answer uses a 16-byte slot, shared across Ports.
    // Held answer releases add one Host-wide worklist (40 bytes), reserved
    // one slot per live session like the encode worklist. The Node's
    // wire-hash root adds one word (ADR-0037). The session, peer, and
    // ingress tables are handle tables (ADR-0038): each is an array list
    // header with a free chain head and two counts in place of a hash map
    // header and a handle counter, 64 bytes across the three.
    try std.testing.expectEqual(@as(usize, 2704), @sizeOf(Host));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Host));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(driver.core.HostAction));
}

test "Host transport profiles own extension semantics and refuse ambiguity" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x5d)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try std.testing.expectError(error.UnknownTransport, host.designatorScheme("custom-key"));
    try std.testing.expectError(error.TransportSemanticsConflict, host.defineTransport(.{ .symbol = "tcp", .designator_scheme = .key }));
    try std.testing.expectError(error.InvalidTransportName, host.defineTransport(.{ .symbol = "", .designator_scheme = .address }));
    const long_symbol: [glowcap.foundation.sealed.max_transport_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTransportName, host.defineTransport(.{ .symbol = &long_symbol, .designator_scheme = .key, .sealed_channel = true }));

    var mutable_name = [_]u8{ 'c', 'u', 's', 't', 'o', 'm', '-', 'k', 'e', 'y' };
    const defined = try host.defineTransport(.{ .symbol = &mutable_name, .designator_scheme = .key });
    mutable_name[0] = 'x';
    try std.testing.expectEqual(model.transport.DesignatorScheme.key, try host.designatorScheme("custom-key"));
    try std.testing.expectError(error.UnknownTransport, host.designatorScheme(&mutable_name));
    try std.testing.expectEqualStrings(defined, try host.defineTransport(.{ .symbol = "custom-key", .designator_scheme = .key }));
    try std.testing.expectError(error.TransportSemanticsConflict, host.defineTransport(.{ .symbol = "custom-key", .designator_scheme = .address }));

    const remote = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x61))).publicKey();
    const remote_designator = remote.toDesignator();
    try host.ensureAdvertisedLocator("custom-key");
    const session = try host.openDialedLocator(.{
        .transport = "custom-key",
        .designator = &remote_designator,
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expect(session.served.port.peer.demandedPartnerKey().?.eql(remote));
}

test "registered custom key transport governs the engine's partner hello claim" {
    const allocator = std.testing.allocator;
    var dialer = test_host.init(allocator, @as([32]u8, @splat(0x62)), Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    var acceptor = test_host.init(allocator, @as([32]u8, @splat(0x63)), Host.Options.withFrameCap(frame_cap));
    defer acceptor.deinit();
    _ = try dialer.defineTransport(.{ .symbol = "custom-key", .designator_scheme = .key });
    _ = try acceptor.defineTransport(.{ .symbol = "custom-key", .designator_scheme = .key });

    try dialer.ensureAdvertisedLocator("custom-key");
    try acceptor.ensureAdvertisedLocator("custom-key");
    const demanded = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x64))).publicKey().toDesignator();
    const dialed = try dialer.openDialedLocator(.{
        .transport = "custom-key",
        .designator = &demanded,
        .hints = model.Hints.emptyFalse(),
    });
    const accepted = try acceptor.openAcceptedAdvertised("custom-key");
    var hello = (try accepted.takeOutbound()) orelse return error.MissingAcceptedHello;
    defer hello.deinit();

    try std.testing.expectError(error.PartnerDesignatorMismatch, dialer.feed(dialed, hello.view()));
    try std.testing.expect(!dialed.sessionOpen());
}

test "registered extension profile governs sealed-channel composition" {
    const allocator = std.testing.allocator;
    const options = Host.Options.withFrameCap(frame_cap);
    var host = test_host.init(allocator, @as([32]u8, @splat(0x65)), options);
    defer host.deinit();
    _ = try host.defineTransport(.{
        .symbol = "private-noise-stream",
        .designator_scheme = .key,
        .dial_shape = .host_port,
        .address_source = .direct_addresses_hint,
        .sealed_channel = true,
    });
    try host.ensureAdvertisedLocator("private-noise-stream");

    const remote = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x66))).publicKey().toDesignator();
    const session = try host.openDialedLocator(.{
        .transport = "private-noise-stream",
        .designator = &remote,
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expect(session.sealed != null);
    try host.releaseSession(session);
}

test "session release refuses an ingress disagreement before consuming the handle" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x67)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var log = TraceLog{};
    try host.setTrace(.{ .ctx = &log, .emit = TraceLog.emit });

    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7067"));
    const peer_handle = session.peer_handle;

    // Inject a lifecycle disagreement: the Vat does not own the ingress, while
    // the Host shell still does. Release must surface that fact without
    // tracing a close, changing lifecycle, or freeing the caller's session
    // handle.
    try host.vat.cancelIngress(session.served.port.ingress, "injected retirement");
    try std.testing.expectError(error.UnknownIngress, host.releaseSession(session));
    try std.testing.expect(host.sessions.get(peer_handle) == session);
    try std.testing.expectEqual(HostSession.LifecyclePhase.active, session.lifecyclePhase());
    try std.testing.expect(!log.contains("close"));
}

test "byte-fed iroh dial pin: a hello claiming another identity is refused; a same-name forgery is unproven" {
    const allocator = std.testing.allocator;

    const honest_seed = @as([32]u8, @splat(0x41));
    const honest = crypto.SecretKey.fromSeed(honest_seed);
    const designator = honest.publicKey().toDesignator();
    var uri_buf: [96]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "ocapn://{s}.iroh", .{designator[0..]});

    // Happy path: the acceptor advertises the dialed identity, so the dialer's
    // claim pin holds and the session opens.
    {
        var dialer = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
        defer dialer.deinit();
        var acceptor = test_host.init(allocator, honest_seed, Host.Options.withFrameCap(frame_cap));
        defer acceptor.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(allocator);

        // iroh accepts may omit direct-addresses (discovery); keyed-tcp may not.
        try dialer.ensureAdvertisedLocator("iroh");
        try acceptor.setAdvertisedLocator(.{
            .transport = "iroh",
            .designator = designator[0..],
            .hints = model.Hints.emptyFalse(),
        });
        const accepted = try acceptor.openAcceptedAdvertised("iroh");
        const loc = try model.uri.parsePeer(allocator, uri);
        defer model.freePeerLocator(allocator, loc);
        const dialed = try dialer.openDialedLocator(loc);
        const pair = Pair{ .ah = &dialer, .a = dialed, .bh = &acceptor, .b = accepted };
        try pumpToQuiescence(allocator, &.{ &dialer, &acceptor }, &.{pair}, &dials);
        try std.testing.expect(dialed.sessionOpen());
        try std.testing.expect(accepted.sessionOpen());
    }

    // A peer advertising a *different* identity than the one dialed is refused
    // before the session opens, the claim pin, the check that survives
    // fresh session keys (ADR-0028).
    {
        const other_seed = @as([32]u8, @splat(0x43));
        const other_designator = crypto.SecretKey.fromSeed(other_seed).publicKey().toDesignator();
        var dialer = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
        defer dialer.deinit();
        var acceptor = test_host.init(allocator, other_seed, Host.Options.withFrameCap(frame_cap));
        defer acceptor.deinit();

        try dialer.ensureAdvertisedLocator("iroh");
        try acceptor.setAdvertisedLocator(.{
            .transport = "iroh",
            .designator = other_designator[0..],
            .hints = model.Hints.emptyFalse(),
        });
        const accepted = try acceptor.openAcceptedAdvertised("iroh");
        const loc = try model.uri.parsePeer(allocator, uri);
        defer model.freePeerLocator(allocator, loc);
        const dialed = try dialer.openDialedLocator(loc);
        var hello = accepted.served.port.peer.takeOutbound().?;
        defer hello.deinit();
        try std.testing.expectError(error.PartnerDesignatorMismatch, dialer.feed(dialed, hello.view()));
        try std.testing.expect(!dialed.sessionOpen());
    }

    // A peer cannot advertise an identity it does not hold the secret for
    // (ADR-0028). The forgery is refused at the squatter's own side, by the
    // seam that would have signed the hello, so it never reaches the wire.
    {
        const squatter_seed = @as([32]u8, @splat(0x42));
        var acceptor = test_host.init(allocator, squatter_seed, Host.Options.withFrameCap(frame_cap));
        defer acceptor.deinit();
        try std.testing.expectError(
            error.UnheldIdentity,
            acceptor.setAdvertisedLocator(.{
                .transport = "iroh",
                .designator = designator[0..],
                .hints = model.Hints.emptyFalse(),
            }),
        );
    }

    // A byte-fed host can still be handed a channel with no endpoint proof.
    // The claim must match the dial target, but its provenance remains
    // unauthenticated because no realizer vouched for the channel.
    {
        const squatter_seed = @as([32]u8, @splat(0x42));
        var dialer = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
        defer dialer.deinit();
        try dialer.ensureAdvertisedLocator("iroh");
        const loc = try model.uri.parsePeer(allocator, uri);
        defer model.freePeerLocator(allocator, loc);
        const dialed = try dialer.openDialedLocator(loc);

        var hello = try handshake_support.signedHelloFrame(
            allocator,
            crypto.SecretKey.fromSeed(squatter_seed),
            "iroh",
            designator[0..],
            model.Hints.emptyFalse(),
        );
        defer hello.deinit();
        try dialer.feed(dialed, hello.view());
        try std.testing.expect(dialed.sessionOpen());
        const seen = try dialer.partnerIdentity(dialed);
        try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, seen.provenance);
    }
}

test "queueUniqueSessionAction keeps one flush and one close per session" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const a_session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7101", &.{});
    const b_session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7102", &.{});
    const a = a_session.peer_handle;
    const b = b_session.peer_handle;
    try driver.core.testing.queueUniqueSessionAction(&host, .flush, a);
    try driver.core.testing.queueUniqueSessionAction(&host, .flush, a);
    try driver.core.testing.queueUniqueSessionAction(&host, .close, a);
    try driver.core.testing.queueUniqueSessionAction(&host, .close, a);
    try driver.core.testing.queueUniqueSessionAction(&host, .flush, b);
    var flushes: usize = 0;
    var closes: usize = 0;
    while (try host.nextAction()) |action| {
        switch (action) {
            .flush => |id| {
                flushes += 1;
                try std.testing.expect(id == a or id == b);
            },
            .close => |id| {
                closes += 1;
                try std.testing.expectEqual(a, id);
            },
            else => try std.testing.expect(false),
        }
    }
    try std.testing.expectEqual(@as(usize, 2), flushes);
    try std.testing.expectEqual(@as(usize, 1), closes);
}

test "reserved session notifications remain allocation-free after mint" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = test_host.init(failing.allocator(), @as([32]u8, @splat(0x2b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7103", &.{});

    // A queued frame and a terminal verdict can both need notification after
    // protocol ownership has moved. Mint reserved these two slots; neither
    // enqueue may consult the allocator in that irreversible window.
    failing.fail_index = failing.alloc_index;
    try driver.core.testing.queueUniqueSessionAction(&host, .flush, session.peer_handle);
    try driver.core.testing.queueUniqueSessionAction(&host, .close, session.peer_handle);
    try std.testing.expect(!failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect((try host.takeAction()).? == .flush);
    try std.testing.expect((try host.takeAction()).? == .close);

    // A reservation is reusable capacity, not a one-shot tail index. Repeated
    // pop/push cycles must compact the dead prefix without allocating or ever
    // reaching appendAssumeCapacity at the physical end of the backing.
    failing.fail_index = failing.alloc_index;
    for (0..256) |_| {
        try driver.core.testing.queueUniqueSessionAction(&host, .flush, session.peer_handle);
        try std.testing.expect((try host.takeAction()).? == .flush);
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "abort encode OOM still closes authority and exposes close notification" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = test_host.init(failing.allocator(), @as([32]u8, @splat(0x3b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7104", &.{});

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        driver.core.testing.condemn(&host, session, .resource_exhausted, "allocation pressure"),
    );
    try std.testing.expect(session.isTerminating());
    try std.testing.expectEqual(glowcap.ocapn.session.State.closed, session.served.port.peer.session_state.state);

    failing.fail_index = std.math.maxInt(usize);
    var saw_close = false;
    while (try host.takeAction()) |action| switch (action) {
        .close => |peer_handle| {
            try std.testing.expectEqual(session.peer_handle, peer_handle);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
}

test "partner abort immediately retires a byte-fed session without an echo" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x5b)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x6b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7107", &dials);
    var captured = CapturedRef{};
    const vow = try client.fetch(pair.a, "never-resolves");
    try client.vowOn(vow, .{ .ctx = &captured, .func = CapturedRef.record });
    var abandoned = (try pair.a.takeOutbound()) orelse return error.MissingFetch;
    abandoned.deinit();
    while (try client.takeAction()) |_| {}

    const diagnostic = "server is shutting down";
    try pair.b.served.port.peer.sendBorrowed(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = diagnostic,
    } });
    try pair.b.served.port.peer.stepToIdle();
    var abort_frame = (try pair.b.takeOutbound()) orelse return error.MissingAbort;
    defer abort_frame.deinit();

    try client.feed(pair.a, abort_frame.view());
    try std.testing.expect(pair.a.isTerminating());
    try std.testing.expect(pair.a.ingressCancelled());
    try std.testing.expect(captured.broken);
    try std.testing.expectEqualStrings(diagnostic, captured.reason_buf[0..captured.reason_len]);
    try std.testing.expect((try pair.a.takeOutbound()) == null);
    try std.testing.expectError(error.SessionCondemned, client.feed(pair.a, abort_frame.view()));

    const action = (try client.takeAction()) orelse return error.MissingClose;
    try std.testing.expect(action == .close);
    try std.testing.expectEqual(pair.a.peer_handle, action.close);
    try std.testing.expect((try client.takeAction()) == null);
}

test "partner abort before start-session retires an accepted session without an echo" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x7b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7108", &.{});

    // Accepted sessions project their own hello immediately. Remove it so any
    // later outbound frame would be an improper abort echo.
    var hello = (try session.takeOutbound()) orelse return error.MissingHello;
    hello.deinit();
    const hello_action = (try host.takeAction()) orelse return error.MissingFlush;
    try std.testing.expect(hello_action == .flush);
    try std.testing.expectEqual(session.peer_handle, hello_action.flush);
    try std.testing.expect((try host.takeAction()) == null);

    var abort_frame = try glowcap.ocapn.codec.syrup.encodeMessage(allocator, .{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "partner stopped during negotiation",
    } });
    defer abort_frame.deinit();

    try host.feed(session, abort_frame.view());
    try std.testing.expect(session.isTerminating());
    try std.testing.expect(session.ingressCancelled());
    try std.testing.expect(!session.sessionOpen());
    try std.testing.expect((try session.takeOutbound()) == null);

    const action = (try host.takeAction()) orelse return error.MissingClose;
    try std.testing.expect(action == .close);
    try std.testing.expectEqual(session.peer_handle, action.close);
    try std.testing.expect((try host.takeAction()) == null);
}

test "release cleanup OOM remains resumable through the action drain" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = test_host.init(failing.allocator(), @as([32]u8, @splat(0x4b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const remaining = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7105", &.{});
    const released = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7106", &.{});

    try remaining.served.port.peer.sendBorrowed(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "queued before release",
    } });
    driver.core.testing.markDirty(&host, remaining.peer_handle);

    // `releaseSession` has committed the other shell before its cleanup pump.
    // Encode OOM is therefore swallowed, but the dirty row must survive for
    // the documented action-drain retry rather than requiring an unrelated
    // future Host verb.
    failing.fail_index = failing.alloc_index;
    try host.releaseSession(released);
    try std.testing.expect(failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    const action = (try host.takeAction()) orelse return error.MissingRetriedFlush;
    try std.testing.expect(action == .flush);
    try std.testing.expectEqual(remaining.peer_handle, action.flush);
    var frame = (try remaining.takeOutbound()) orelse return error.MissingRetriedFrame;
    frame.deinit();
}

test "a keyed dial to a malformed designator refuses without freeing it twice" {
    // `keyed-tcp` pins the session to the key its designator names, so a
    // designator that is not canonical Ed25519 hex is refused after the shell
    // has been minted. The refusal path unwinds the mint, and the dialed
    // designator has exactly one owner, so this is a plain error rather than a
    // second free of bytes the shell already released. Reachable straight from
    // `glowcap_host_session_open_dialed_locator`, which passes an embedder's
    // transport and designator through untouched.
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x21)), .{});
    defer host.deinit();
    try host.ensureAdvertisedLocator("keyed-tcp");

    try std.testing.expectError(error.InvalidAddress, host.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = "not-a-key",
        .hints = model.Hints.emptyFalse(),
    }));

    // The refusal left nothing behind: the same designator dials again.
    try std.testing.expectError(error.InvalidAddress, host.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = "not-a-key",
        .hints = model.Hints.emptyFalse(),
    }));
}

test "route-bundle transports cannot be opened as physical sessions" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x22)), .{});
    defer host.deinit();
    try host.setAdvertisedLocator(tcpLocator("127.0.0.1:7068"));

    try std.testing.expectError(driver.core.HostError.UnknownTransport, host.openDialedLocator(.{
        .transport = model.transport.id,
        .designator = "not-a-route",
        .hints = model.Hints.emptyFalse(),
    }));

    try std.testing.expectError(driver.core.HostError.UnknownTransport, host.openAcceptedAdvertised(model.transport.id));

    var pinned = engine.Peer.initNegotiating(allocator);
    defer pinned.deinit();
    try std.testing.expectError(driver.core.HostError.UnknownTransport, host.openAcceptedAdvertisedOver(&pinned, model.transport.id));
}
