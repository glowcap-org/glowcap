//! Feed and serve under pressure: inbound OOM leaves a borrowed hello
//! retryable, finite quanta resume round-robin fairness, staged outbound
//! refuses before the shared high-water, feedBytes retains only the
//! unapplied suffix, and a Node action one recipient's pressure parks holds
//! back nothing bound for its siblings.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const promise_capture = @import("../../support/capture.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("harness.zig");
const projection_support = @import("../../support/projection.zig");
const PublicationProbe = harness.PublicationProbe;
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

const PressureActionIo = struct {
    pub fn randomSecure(_: @This(), _: []u8) !void {
        return error.UnexpectedEntropyRequest;
    }
};

const PressureActionExec = struct {
    flushes: *usize,

    pub fn flush(self: @This(), _: engine.PeerHandle) !void {
        self.flushes.* += 1;
    }
    pub fn close(_: @This(), _: engine.PeerHandle) !void {}
    pub fn dial(_: @This(), _: @FieldType(driver.core.HostAction, "dial")) !void {}
    pub fn cancelDial(_: @This(), _: @FieldType(driver.core.HostAction, "cancel_dial")) !void {}
    pub fn complete(_: @This(), _: driver.core.HostAction) !void {}
};

test "core host: inbound OOM leaves a borrowed hello retryable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x31)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x32)), Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();

    const accepted = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7091", &.{});
    try peer.ensureAdvertisedLocator("tcp");
    const dialed = try peer.openDialedLocator(tcpLocator("127.0.0.1:7091"));
    defer peer.releaseSession(dialed) catch unreachable;
    var hello = (try dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();

    // Fail the next inbound allocation. The hello must remain unapplied and
    // its borrowed frame retryable; parked-withdraw scheduler reservation is
    // exercised separately on the adopted-Peer admission path.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, host.feed(accepted, hello.view()));
    try std.testing.expect(!accepted.sessionOpen());

    // The same borrowed frame remains retryable. Once allocation is restored,
    // it applies normally and the session opens.
    failing.fail_index = std.math.maxInt(usize);
    try host.feed(accepted, hello.view());
    try std.testing.expect(accepted.sessionOpen());
    try host.releaseSession(accepted);
}

test "core host: a finite quantum resumes round-robin work behind a sibling" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x33)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x34)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .host_work_quantum = 1,
    });
    defer host.deinit();
    var other = test_host.init(allocator, @as([32]u8, @splat(0x35)), Host.Options.withFrameCap(frame_cap));
    defer other.deinit();

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const first_pair = try openPair(allocator, &client, &host, "127.0.0.1:7092", &dials);
    const second_pair = try openPair(allocator, &other, &host, "127.0.0.1:7093", &dials);
    const first = first_pair.b;
    const second = second_pair.b;

    var first_hits: usize = 0;
    var second_hits: usize = 0;
    const first_actor = try host.vat.spawn(FairCounter, .{ .hits = &first_hits });
    const second_actor = try host.vat.spawn(FairCounter, .{ .hits = &second_hits });
    try host.vat.tellFromIngress(first.served.port.ingress, first_actor, .{ .verb = "hit", .args = &.{} });
    try host.vat.tellFromIngress(second.served.port.ingress, second_actor, .{ .verb = "hit", .args = &.{} });

    // The first dirty row is the sibling. `flushSession(first)` adds the
    // resumed session behind it; one finite quantum must therefore serve the
    // sibling and leave the first session for the next continuation.
    driver.core.testing.markDirty(&host, second.peer_handle);
    try host.flushSession(first);
    try std.testing.expectEqual(@as(usize, 0), first_hits);
    try std.testing.expectEqual(@as(usize, 1), second_hits);

    try host.flushSession(first);
    try std.testing.expectEqual(@as(usize, 1), first_hits);
}

test "core host: staged outbound pressure refuses before the shared high-water is exceeded" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x36)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x37)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .outbound_high_water_bytes = 1024,
    });
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7094", &dials);
    try pair.b.served.port.peer.session_state.registerImport(.from(7));

    var refused = false;
    _ = try pair.b.served.publish(&host.vat, "pressure", PendingPressure, .{
        .host = &host,
        .session = pair.b,
        .target = .{ .far = model.FarRef.object(7) },
        .refused = &refused,
    });
    var fetched = promise_capture.CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "pressure"), .{ .ctx = &fetched, .func = promise_capture.CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &host }, &.{pair}, &dials);
    const pressure = try fetched.require();

    try client.tell(pair.a, pressure, .{ .verb = "flood", .args = &.{} });
    var flood = (try pair.a.takeOutbound()) orelse return error.MissingFlood;
    defer flood.deinit();
    try host.feed(pair.b, flood.view());

    try std.testing.expect(refused);
    // The line refuses the producer that finds it reached, so the queue
    // holds the line plus less than one frame.
    const queued = pair.b.served.queuedOutboundBytes();
    try std.testing.expect(queued >= 1024);
    _ = try pair.b.served.port.peer.step();
    var one = (try pair.b.takeOutbound()) orelse return error.MissingQueued;
    defer one.deinit();
    try std.testing.expect(queued < 1024 + one.bytes().len);
}

test "core host: committed relayed listeners resume after outbound pressure" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x3a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x3b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7096", &dials);
    const peer = pair.b.served.port.peer;

    const projection = try peer.session_state.allocateLocalPromiseProjection();
    peer.session_state.exports.retain(projection.export_position);
    try peer.session_state.retainImportForSession(.from(42));
    try peer.session_state.installListenerNamed(projection.answer_name, .{
        .listener = .{ .import_position = .from(42) },
        .mode = .settling_only,
    });

    // The source fire is already consumed. With no outbound admission left,
    // the authoritative store still commits and leaves its settlement carrier
    // deferred for Host scheduling rather than turning pressure into a retry
    // of the one-shot protocol event.
    peer.outbound_budget = 0;
    const reason = try allocator.dupe(u8, "settled under pressure");
    try peer.settleAnswerTargetGuaranteed(projection.answer_target, .{
        .@"break" = .{ .message = reason },
    });
    try std.testing.expect(projection_support.resolution(&peer.session_state, projection.export_position) != null);

    driver.core.testing.markDirty(&host, pair.b.peer_handle);
    driver.core.testing.finishCommittedWork(&host, pair.b);
    try std.testing.expect(!pair.b.isTerminating());
    try std.testing.expect((try pair.b.takeOutbound()) == null);

    // The first wake clears its dedupe bit. The shared drain then retries the
    // parked carrier, meets the same pressure, and executes the replacement
    // FLUSH before returning a distinct pressure boundary. A blocking front
    // must not mistake that boundary for a finite scheduler yield and spin in
    // this stack frame while only transport readiness can move the window.
    var flushes: usize = 0;
    const action_exec = PressureActionExec{ .flushes = &flushes };
    try std.testing.expectEqual(
        driver.core.DrainResult.outbound_blocked,
        try driver.core.drainActions(&host, PressureActionIo{}, action_exec),
    );
    try std.testing.expectEqual(@as(usize, 2), flushes);
    try std.testing.expect(!pair.b.isTerminating());
    // Dirty work awaiting transport readiness must not wake persistence's
    // surrounding action drain indefinitely.
    try std.testing.expect(!host.hasRunnableWork());

    peer.outbound_budget = std.math.maxInt(usize);
    // Taking outbound is what marks the pressure actionable again; the empty
    // take resets the stand-down so the next drain retries the parked carrier.
    try std.testing.expect((try pair.b.takeOutbound()) == null);
    try std.testing.expectEqual(
        driver.core.DrainResult.drained,
        try driver.core.drainActions(&host, PressureActionIo{}, action_exec),
    );
    try std.testing.expectEqual(@as(usize, 3), flushes);
    var fire = (try pair.b.takeOutbound()) orelse return error.MissingListenerFire;
    fire.deinit();
    try host.flushSession(pair.b);
    var release = (try pair.b.takeOutbound()) orelse return error.MissingListenerRelease;
    defer release.deinit();
    const body = try glowcap.ocapn.codec.syrup.decodeBody(release.view());
    try std.testing.expect(body == .gc_export);
    try std.testing.expectEqual(@as(u64, 42), try body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(u64, 1), try body.gc_export.deltas.at(0));
    try std.testing.expect((try pair.b.takeOutbound()) == null);
}

test "core host: unbounded feed condemns an event consumed before serve OOM" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x3c)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x3d)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7097", &dials);

    var attempts: usize = 0;
    pair.b.served.serve_options = .{
        .hook_ctx = &attempts,
        .before_serve = struct {
            fn fail(ctx: ?*anyopaque, _: *driver.core.Served, _: *engine.Event) driver.core.BeforeServeError!bool {
                const count: *usize = @ptrCast(@alignCast(ctx.?));
                count.* += 1;
                return error.OutOfMemory;
            }
        }.fail,
    };

    try client.tell(pair.a, .{ .far = model.FarRef.object(0) }, .{
        .verb = "consume-once",
        .args = &.{},
    });
    var frame = (try pair.a.takeOutbound()) orelse return error.MissingDeliver;
    defer frame.deinit();
    // The feed succeeds as a consumed terminal event: retrying the same frame
    // would duplicate authority, so the Host closes this session instead.
    try host.feed(pair.b, frame.view());
    try std.testing.expectEqual(@as(usize, 1), attempts);
    try std.testing.expect(!pair.b.served.port.peer.hasEvent());
    try std.testing.expect(pair.b.isTerminating());

    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .close => |peer_handle| {
            try std.testing.expectEqual(pair.b.peer_handle, peer_handle);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
}

test "core host: feedBytes retains only the unapplied suffix after mid-chunk pressure" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x38)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x39)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .outbound_high_water_bytes = 1024,
    });
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7095", &dials);
    try pair.b.served.port.peer.session_state.registerImport(.from(7));

    var hits: usize = 0;
    _ = try pair.b.served.publish(&host.vat, "pressure", FeedPressure, .{
        .session = pair.b,
        .hits = &hits,
    });
    var fetched = promise_capture.CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "pressure"), .{ .ctx = &fetched, .func = promise_capture.CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &host }, &.{pair}, &dials);
    const pressure = try fetched.require();

    // Setup needs room to return the fetched capability. On the quiescent
    // session, model an admitted operation whose encoded representation
    // crosses the Host waterline: engine admission still has room to commit
    // the operation, while the byte parser must park the following frame.
    // Production mints both values together; representation expansion is what
    // can put the encoded queue over that shared line after admission.
    pair.b.outbound_high_water_bytes = 100;
    pair.b.served.port.peer.outbound_budget = 256;

    var stream: [2 * frame_cap]u8 = undefined;
    var stream_len: usize = 0;
    for (0..2) |_| {
        try client.tell(pair.a, pressure, .{ .verb = "flood", .args = &.{} });
        var frame = (try pair.a.takeOutbound()) orelse return error.MissingFlood;
        defer frame.deinit();
        const view = frame.view();
        var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
        const prefix = stream_framing.renderPrefix(&prefix_buf, view.bytes.len);
        @memcpy(stream[stream_len..][0..prefix.len], prefix);
        stream_len += prefix.len;
        @memcpy(stream[stream_len..][0..view.bytes.len], view.bytes);
        stream_len += view.bytes.len;
    }

    // The first turn fills the outbound waterline. The call consumed that
    // frame and retained only the second frame; replaying the original chunk
    // would execute the first turn twice.
    try host.feedBytes(pair.b, stream[0..stream_len]);
    try std.testing.expectEqual(@as(usize, 1), hits);
    try std.testing.expectError(error.OutboundBackpressure, host.feedBytes(pair.b, &.{}));

    while (try pair.b.takeStreamOutbound()) |outbound_value| {
        var outbound = outbound_value;
        outbound.payload.deinit();
    }
    // Draining the first turn is the retry boundary: the core resumes its own
    // retained tail, so no binding-only empty feed is needed for liveness.
    try std.testing.expectEqual(@as(usize, 2), hits);
    try host.feedBytes(pair.b, &.{});
    try std.testing.expectEqual(@as(usize, 2), hits);

    // Drain the second turn's pressure and prove no consumed frame remained
    // parked for a later empty-feed resume.
    while (try pair.b.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try host.feedBytes(pair.b, &.{});
    try std.testing.expectEqual(@as(usize, 2), hits);
}

/// The gifted object, published by the exporter.
const PendingPressure = struct {
    host: *Host,
    session: *HostSession,
    target: model.Reference,
    refused: *bool,
    hits: ?*usize = null,

    pub fn handle(self: *PendingPressure, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "flood")) return error.NoSuchMethod;
        if (self.hits) |hits| hits.* += 1;
        var attempts: usize = 0;
        while (attempts < 32) : (attempts += 1) {
            self.host.tell(self.session, self.target, .{ .verb = "queued", .args = &.{} }) catch |err| {
                // The engine is the final admission authority. The Vat's
                // actor-facing seam currently projects that refusal as
                // SendRejected, while Host's preflight reports the typed
                // HostError when the shared counter is already full.
                if (err == driver.core.HostError.OutboundBackpressure or err == actors.Error.SendRejected) {
                    self.refused.* = true;
                    break;
                }
                return err;
            };
        }
        return .{ .boolean = self.refused.* };
    }
};

const FeedPressure = struct {
    session: *HostSession,
    hits: *usize,

    pub fn handle(self: *FeedPressure, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "flood")) return error.NoSuchMethod;
        self.hits.* += 1;
        while (true) {
            self.session.served.port.peer.sendBorrowed(.{ .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &.{},
                .answer = null,
            } }) catch |err| {
                if (err == error.OutboundBackpressure) break;
                return err;
            };
        }
        return .{ .boolean = true };
    }
};

/// Defer the answer and hand the test the wire answer this turn must settle,
/// so a Node action can address that pending answer directly.
const DeferringCapture = struct {
    host: *Host,
    session: *HostSession,
    out_resolver: *u64,
    out_answer: *?engine.AnswerTarget,

    pub fn handle(self: *DeferringCapture, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "work")) return error.NoSuchMethod;
        self.out_answer.* = turn.origin.served;
        self.out_resolver.* = try self.host.deferTurn(self.session, turn);
        return .{ .void = {} };
    }
};

/// One deferred call left pending on the server: the wire answer a Node
/// action can address, and the flag its break sets on the client side.
const PendingDeferral = struct {
    resolver: u64 = 0,
    answer: ?engine.AnswerTarget = null,
    broken: bool = false,

    /// Publish a deferring worker on the server side of `pair`, fetch and
    /// call it from the client, and pump until the call is parked on its
    /// resolver. `self` must outlive the call: its `broken` flag is the
    /// listener's context.
    fn open(
        self: *PendingDeferral,
        allocator: std.mem.Allocator,
        client: *Host,
        server: *Host,
        pair: Pair,
        dials: *std.ArrayList(ParkedDial),
    ) !engine.AnswerTarget {
        _ = try pair.b.served.publish(&server.vat, "worker", DeferringCapture, .{
            .host = server,
            .session = pair.b,
            .out_resolver = &self.resolver,
            .out_answer = &self.answer,
        });
        var worker = CapturedRef{};
        try client.vowOn(try client.fetch(pair.a, "worker"), .{ .ctx = &worker, .func = CapturedRef.record });
        try pumpToQuiescence(allocator, &.{ client, server }, &.{pair}, dials);
        try client.vowOn(
            try client.send(pair.a, try worker.require(), .{ .verb = "work", .args = &.{} }),
            .{ .ctx = &self.broken, .func = promise_capture.captureBroken },
        );
        try pumpToQuiescence(allocator, &.{ client, server }, &.{pair}, dials);
        if (self.resolver == 0) return error.MissingResolver;
        return self.answer orelse error.MissingAnswer;
    }
};

test "core host: a node action parked on one recipient's pressure leaves sibling actions live" {
    const allocator = std.testing.allocator;
    var first = test_host.init(allocator, @as([32]u8, @splat(0x3c)), Host.Options.withFrameCap(frame_cap));
    defer first.deinit();
    var second = test_host.init(allocator, @as([32]u8, @splat(0x3d)), Host.Options.withFrameCap(frame_cap));
    defer second.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x3e)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pressured = try openPair(allocator, &first, &server, "127.0.0.1:7097", &dials);
    const sibling = try openPair(allocator, &second, &server, "127.0.0.1:7098", &dials);
    const hosts = [_]*Host{ &first, &second, &server };
    const pairs = [_]Pair{ pressured, sibling };

    var pressured_call = PendingDeferral{};
    const pressured_target = try pressured_call.open(allocator, &first, &server, pressured, &dials);
    var sibling_call = PendingDeferral{};
    const sibling_target = try sibling_call.open(allocator, &second, &server, sibling, &dials);

    // The first recipient can take no more outbound frames. A Node break for
    // its pending answer waits on that pressure; the sibling's break, queued
    // behind it, belongs to another session and must not wait with it.
    pressured.b.served.port.peer.outbound_budget = 0;
    try server.node.actions.queue.reserve(allocator, 2);
    server.node.actions.queue.pushReserved(.{ .fail = .{
        .dest = .{ .served_answer = .{ .recipient_peer = pressured.b.peer_handle, .answer = pressured_target } },
        .reason = .{ .static = "exporter gone" },
    } });
    server.node.actions.queue.pushReserved(.{ .fail = .{
        .dest = .{ .served_answer = .{ .recipient_peer = sibling.b.peer_handle, .answer = sibling_target } },
        .reason = .{ .static = "exporter gone" },
    } });
    var rounds: usize = 0;
    while (rounds < 16 and !sibling_call.broken) : (rounds += 1) {
        _ = drainActions(allocator, &.{&server}, &dials) catch |err| switch (err) {
            error.OutboundBackpressure => {},
            else => return err,
        };
        _ = try shuttleAll(&pairs);
        _ = try drainActions(allocator, &.{ &first, &second }, &dials);
    }
    try std.testing.expect(sibling_call.broken);
    try std.testing.expect(!pressured_call.broken);

    // The parked break is owed, not dropped: once the partner reads and the
    // embedder takes the recipient's bytes, it re-enters the queue and lands.
    pressured.b.served.port.peer.outbound_budget = std.math.maxInt(usize);
    try std.testing.expect((try pressured.b.takeOutbound()) == null);
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    try std.testing.expect(pressured_call.broken);
    try std.testing.expectEqual(@as(usize, 0), server.parked_node_actions.count());
}

test "core host: releasing a pressured recipient returns its parked actions to the queue" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x3f)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x40)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7099", &dials);

    var call = PendingDeferral{};
    const target = try call.open(allocator, &client, &server, pair, &dials);

    // Park a break on the pressured recipient, with an owned reason so the
    // leak check sees the payload's whole life.
    pair.b.served.port.peer.outbound_budget = 0;
    try server.node.actions.queue.reserve(allocator, 1);
    server.node.actions.queue.pushReserved(.{ .fail = .{
        .dest = .{ .served_answer = .{ .recipient_peer = pair.b.peer_handle, .answer = target } },
        .reason = .{ .owned = try allocator.dupe(u8, "exporter gone") },
    } });
    _ = drainActions(allocator, &.{&server}, &dials) catch |err| switch (err) {
        error.OutboundBackpressure => {},
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 1), server.parked_node_actions.count());

    // Release returns the row to the queue; the action finds no recipient
    // and is consumed, so nothing stays parked and nothing leaks.
    try server.releaseSession(pair.b);
    try std.testing.expectEqual(@as(usize, 0), server.parked_node_actions.count());
    _ = try drainActions(allocator, &.{&server}, &dials);
    try std.testing.expect(!server.node.hasAction());
    try client.releaseSession(pair.a);
}

test "core host: refused node action parking retains its payload and frees provisional storage" {
    var refusals: usize = 0;
    var completed = false;
    for (0..16) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var client = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x41)), Host.Options.withFrameCap(frame_cap));
        defer client.deinit();
        var server = test_host.init(allocator, @as([32]u8, @splat(0x42)), Host.Options.withFrameCap(frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(allocator);
        const pair = try openPair(allocator, &client, &server, "127.0.0.1:7100", &dials);
        var call = PendingDeferral{};
        const target = try call.open(allocator, &client, &server, pair, &dials);

        pair.b.served.port.peer.outbound_budget = 0;
        try server.reserveActions(1);
        try server.node.actions.queue.reserve(allocator, 1);
        const reason = try allocator.dupe(u8, "parking must retain this failure");
        server.node.actions.queue.pushReserved(.{ .fail = .{
            .dest = .{ .served_answer = .{ .recipient_peer = pair.b.peer_handle, .answer = target } },
            .reason = .{ .owned = reason },
        } });
        // Exhaust the physical queue seats so parking must reserve its return
        // seat after allocating the recipient row and its first list backing.
        const queue = &server.node.actions.queue;
        while (queue.list.items.len < queue.list.capacity)
            queue.pushReserved(.{ .flush = pair.b.peer_handle });
        const queued = queue.liveLen();
        failing.fail_index = failing.alloc_index + fail_offset;
        failing.resize_fail_index = failing.resize_index;
        const result = server.nextAction();
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        if (result) |_| {
            completed = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            refusals += 1;
            try std.testing.expectEqual(@as(usize, 0), server.parked_node_actions.count());
            try std.testing.expectEqual(@as(usize, 0), server.node.actions.parked_reservations);
            try std.testing.expectEqual(queued, queue.liveLen());
            try std.testing.expectEqual(reason.ptr, server.node.peekAction().?.fail.reason.owned.ptr);
            _ = try server.nextAction();
        }
        try std.testing.expectEqual(@as(usize, 1), server.parked_node_actions.count());
        pair.b.served.port.peer.outbound_budget = std.math.maxInt(usize);
        try std.testing.expect((try pair.b.takeOutbound()) == null);
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        try std.testing.expect(call.broken);
        try std.testing.expectEqual(@as(usize, 0), server.parked_node_actions.count());
        if (completed) break;
    }
    // Map, recipient list, and queue return seat each have a refusal path.
    try std.testing.expect(refusals >= 3);
    try std.testing.expect(completed);
}
