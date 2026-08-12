//! `driver_core.Host` end to end with no socket anywhere: hosts are wired
//! by moving frames between `takeOutbound` and `feed` by hand, and every host
//! effect (a dial, gift-id entropy) is answered through the action queue,
//! the byte-fed contract the C driver archive and the bindings ride
//! (ADR-0072). The capstone is the full three-party handoff: a gifter's
//! ordinary reply becomes a signed give through the host-internal
//! origination, the recipient's host surfaces one `dial` action, and the
//! settled vow carries a routable token that reaches the exporter's object.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../support/core_host.zig");
const promise_capture = @import("../support/capture.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;
const stream_framing = pancake.foundation.stream_framing;

const frame_cap = 4096;

test "Host admission frame cap defaults to the canonical session limit" {
    // Single-source lock: a default-constructed Host admits the same frame size
    // the driver C ABI publishes as PANCAKE_DEFAULT_FRAME_CAP, so a native Zig
    // embedder and a C embedder agree on the default admission cap. If someone
    // re-hardcodes this default to a bare literal, this fails instead of
    // silently shrinking a Zig host's admissible frame below the advertised C
    // default.
    try std.testing.expectEqual(
        (engine.SessionLimits{}).max_frame_bytes,
        (Host.Options{}).frameCap(),
    );
}

test "core host transport packages publish no prefix before a later conflict" {
    var host = test_host.init(std.testing.allocator, [_]u8{0x30} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const profiles = [_]model.transport.Metadata{
        .{ .symbol = "x-transaction-first", .designator_scheme = .address },
        .{ .symbol = model.transport.tcp, .designator_scheme = .key },
    };
    var canonical = [_][]const u8{ "untouched-0", "untouched-1" };
    try std.testing.expectError(
        error.TransportSemanticsConflict,
        host.defineTransports(&profiles, &canonical),
    );
    try std.testing.expectError(error.UnknownTransport, host.transportProfile("x-transaction-first"));
    try std.testing.expectEqualStrings("untouched-0", canonical[0]);
    try std.testing.expectEqualStrings("untouched-1", canonical[1]);
}

test "core host transport package allocation failure leaves authority and outputs untouched" {
    var saw_failure = false;
    var reached_success = false;

    for (0..32) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = std.math.maxInt(usize);
        var host = test_host.init(failing.allocator(), [_]u8{0x2f} ** 32, Host.Options.withFrameCap(frame_cap));
        defer {
            failing.fail_index = std.math.maxInt(usize);
            host.deinit();
        }

        const profile: model.transport.Metadata = .{
            .symbol = "x-allocation-transaction",
            .designator_scheme = .address,
        };
        var canonical = [_][]const u8{"untouched"};
        failing.fail_index = failing.alloc_index + offset;
        if (host.defineTransports(&.{profile}, &canonical)) |_| {
            reached_success = true;
            try std.testing.expectEqualStrings(profile.symbol, canonical[0]);
            try std.testing.expect((try host.transportProfile(profile.symbol)).eql(profile));
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
            try std.testing.expectEqualStrings("untouched", canonical[0]);
            try std.testing.expectError(error.UnknownTransport, host.transportProfile(profile.symbol));
        }
        if (reached_success) break;
    }

    try std.testing.expect(saw_failure);
    try std.testing.expect(reached_success);
}

test "core host: inbound OOM leaves a borrowed hello retryable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var host = test_host.init(allocator, [_]u8{0x31} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = test_host.init(std.testing.allocator, [_]u8{0x32} ** 32, Host.Options.withFrameCap(frame_cap));
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
    var client = test_host.init(allocator, [_]u8{0x33} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x34} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .host_work_quantum = 1,
    });
    defer host.deinit();
    var other = test_host.init(allocator, [_]u8{0x35} ** 32, Host.Options.withFrameCap(frame_cap));
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
    host.testingMarkDirty(second.peer_id);
    try host.flushSession(first);
    try std.testing.expectEqual(@as(usize, 0), first_hits);
    try std.testing.expectEqual(@as(usize, 1), second_hits);

    try host.flushSession(first);
    try std.testing.expectEqual(@as(usize, 1), first_hits);
}

test "core host: staged outbound pressure refuses before the shared high-water is exceeded" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x36} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x37} ** 32, .{
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
    try std.testing.expect(pair.b.served.queuedOutboundBytes() <= 1024);
}

test "core host: committed relayed listeners resume after outbound pressure" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x3a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7096", &dials);
    const peer = pair.b.served.port.peer;

    const relayed = model.ImportPosition.from(41);
    try peer.session_state.installThirdPartyImport(relayed, "home");
    const row_id = peer.session_state.importedPromiseRowId(relayed).?;
    try peer.session_state.registerImport(.from(42));
    try peer.session_state.installImportedPromiseListener(relayed, .{
        .listener = .{ .import_position = .from(42) },
        .mode = .settling_only,
    });

    // The source fire is already consumed. With no outbound admission left,
    // the authoritative store still commits and leaves its listener carrier
    // parked for Host scheduling rather than turning pressure into a retry of
    // the one-shot protocol event.
    peer.outbound_budget = 0;
    const reason = try allocator.dupe(u8, "settled under pressure");
    try peer.applyRelayedResolutionGuaranteed(relayed, row_id, .{
        .@"break" = .{ .message = reason },
    });
    try std.testing.expect(peer.session_state.importedPromiseResolution(relayed) != null);

    host.testingMarkDirty(pair.b.peer_id);
    host.testingFinishCommittedWork(pair.b);
    try std.testing.expect(!pair.b.condemned);
    try std.testing.expect((try pair.b.takeOutbound()) == null);

    // Popping the first wake clears its dedupe bit. The next drain retries the
    // parked carrier, meets the same pressure, and must publish another FLUSH
    // rather than condemning the Host or reporting an empty action queue.
    try std.testing.expectEqual(pair.b.peer_id, (try host.nextAction()).?.flush);
    try std.testing.expectEqual(pair.b.peer_id, (try host.nextAction()).?.flush);
    try std.testing.expect(!pair.b.condemned);

    peer.outbound_budget = std.math.maxInt(usize);
    try std.testing.expectEqual(pair.b.peer_id, (try host.nextAction()).?.flush);
    var fire = (try pair.b.takeOutbound()) orelse return error.MissingListenerFire;
    fire.deinit();
    try host.flushSession(pair.b);
    try std.testing.expect((try pair.b.takeOutbound()) == null);
}

test "core host: unbounded feed condemns an event consumed before serve OOM" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x3c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x3d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7097", &dials);

    var attempts: usize = 0;
    pair.b.served.serve_options = .{
        .hook_ctx = &attempts,
        .before_serve = struct {
            fn fail(ctx: ?*anyopaque, _: *driver.core.Served, _: *engine.Event) anyerror!bool {
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
    try std.testing.expect(pair.b.condemned);

    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .close => |peer_id| {
            try std.testing.expectEqual(pair.b.peer_id, peer_id);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
}

test "core host: feedBytes retains only the unapplied suffix after mid-chunk pressure" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x38} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x39} ** 32, .{
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

    while (try pair.b.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
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
const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked over fed bytes" };
    }
};

const FairCounter = struct {
    hits: *usize,

    pub fn handle(self: *FairCounter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hit")) return error.NoSuchMethod;
        self.hits.* += 1;
        return .{ .integer = @intCast(self.hits.*) };
    }
};

const PendingPressure = struct {
    host: *Host,
    session: *HostSession,
    target: model.Reference,
    refused: *bool,
    hits: ?*usize = null,

    pub fn handle(self: *PendingPressure, turn: *actors.Turn, msg: actors.Message) !model.Argument {
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

    pub fn handle(self: *FeedPressure, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "flood")) return error.NoSuchMethod;
        self.hits.* += 1;
        while (true) {
            self.session.served.port.peer.sendCopying(.{ .deliver = .{
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

const PublicationProbe = struct {
    host: *Host,
    refused: *bool,

    pub fn handle(self: *PublicationProbe, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "publish")) return error.NoSuchMethod;
        _ = self.host.publishGiftable("nested", Widget, .{}) catch |err| {
            if (err == driver.core.HostError.ReenteredHost) {
                self.refused.* = true;
                return .{ .boolean = true };
            }
            return err;
        };
        return .{ .boolean = false };
    }
};

/// The exporter's vendor: replies with a capability to an object it hosts, so
/// a caller comes by that capability through an ordinary call instead of
/// through `fetch`. `fetch` is the one path that enrolls its result on its
/// own, so this is how a test gets a capability that has no routing token yet.
const Vendor = struct {
    widget: model.Reference,
    pub fn handle(self: *Vendor, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "make")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
    }
};

/// The gifter's introducer: replies with the foreign capability it fetched.
/// The host's own origination interceptor turns that reply into a give.
const Introducer = struct {
    widget: model.Reference,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
    }
};

/// A wired pair: one host's connection whose outbound is the other's inbound.
const host_pair = @import("../support/host_pair.zig");
const handshake_support = @import("../support/handshake.zig");
const Pair = host_pair.Pair;
const shuttle = host_pair.shuttle;
const shuttleAll = host_pair.shuttleAll;
const tcpLocator = host_pair.tcpLocator;
const publishAndOpenAccepted = host_pair.publishAndOpenAccepted;
const publishAndOpenAcceptedOver = host_pair.publishAndOpenAcceptedOver;

fn helloLocatorBytes(allocator: std.mem.Allocator, session: *HostSession) ![]u8 {
    var frame = (try session.takeOutbound()) orelse return error.MissingHello;
    defer frame.deinit();
    const body = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
    if (body != .start_session) return error.MissingHello;
    const locator = try body.start_session.acceptable_location.toOwned(allocator);
    defer model.freePeerLocator(allocator, locator);
    return pancake.ocapn.codec.signed.locationBytes(allocator, locator);
}

test "core host advertised locator: missing snapshot refuses dial and accept" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x70} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try std.testing.expectError(
        error.MissingAdvertisedLocator,
        host.openDialedLocator(tcpLocator("127.0.0.1:7090")),
    );
    try std.testing.expectError(
        error.MissingAdvertisedLocator,
        host.openAcceptedAdvertised("tcp"),
    );
}

test "core host advertised locator: address transport keeps a hex designator opaque" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x72} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const address_shaped_like_key = [_]u8{'a'} ** crypto.PeerKey.designator_len;
    try host.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = &address_shaped_like_key,
        .hints = model.Hints.emptyFalse(),
    });
    const stored = host.advertisedLocator("tcp") orelse return error.MissingAdvertisedLocator;
    try std.testing.expectEqualSlices(u8, &address_shaped_like_key, stored.designator);

    const other_key = crypto.SecretKey.fromSeed([_]u8{0x74} ** 32).publicKey().toDesignator();
    try std.testing.expectError(error.UnheldIdentity, host.setAdvertisedLocator(.{
        .transport = "iroh",
        .designator = &other_key,
        .hints = model.Hints.emptyFalse(),
    }));
}

test "core host advertised locator: duplicate caller hints are refused before storage" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x76} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_direct_addresses, .value = .{ .string = "127.0.0.1:7091" } },
        .{ .name = model.transport.hint_direct_addresses, .value = .{ .string = "127.0.0.1:7092" } },
    };
    try std.testing.expectError(error.DuplicateHintName, host.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:7091",
        .hints = .{ .entries = &hints },
    }));
    try std.testing.expect(host.advertisedLocator("tcp") == null);
}

test "core host advertised locator: explicit dial default publishes once" {
    const allocator = std.testing.allocator;
    const seed = [_]u8{0x73} ** 32;
    var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAdvertisedLocator("tcp");
    const tcp = host.advertisedLocator("tcp") orelse return error.MissingAdvertisedLocator;
    try std.testing.expectEqualStrings("127.0.0.1:0", tcp.designator);
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, tcp.hints.wire_form);
    try std.testing.expectEqualStrings("tcp", host.acceptableLocator().?.transport);

    const own_key = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    try host.ensureAdvertisedLocator("iroh");
    const iroh = host.advertisedLocator("iroh") orelse return error.MissingAdvertisedLocator;
    try std.testing.expectEqualSlices(u8, &own_key, iroh.designator);
    try std.testing.expectEqualStrings("tcp", host.acceptableLocator().?.transport);

    try std.testing.expect(host.selectAdvertisedLocator("iroh"));
    try std.testing.expectEqualStrings("iroh", host.acceptableLocator().?.transport);
    try std.testing.expect(!host.selectAdvertisedLocator("missing"));
    try std.testing.expectEqualStrings("iroh", host.acceptableLocator().?.transport);
    host.removeAdvertisedLocator("iroh");
    try std.testing.expect(host.advertisedLocator("iroh") == null);
    try std.testing.expect(host.acceptableLocator() == null);
    try std.testing.expect(host.selectAdvertisedLocator("tcp"));
    try std.testing.expectEqualStrings("tcp", host.acceptableLocator().?.transport);

    try host.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:7099",
        .hints = model.Hints.emptyFalse(),
    });
    try host.ensureAdvertisedLocator("tcp");
    try std.testing.expectEqualStrings(
        "127.0.0.1:7099",
        host.advertisedLocator("tcp").?.designator,
    );
}

test "core host advertised locator: a cross-transport route survives dial preparation and enters every hello" {
    const allocator = std.testing.allocator;
    const seed = [_]u8{0x75} ** 32;
    var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const own_key = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    const advertised: model.PeerLocator = .{
        .transport = "keyed-relay",
        .designator = &own_key,
        .hints = model.Hints.emptyFalse(),
    };
    try host.setAdvertisedLocator(advertised);
    // Opening the room connection prepares TCP as a dial fallback. It must not
    // replace the keyed-relay route other peers use to reach this host.
    try host.ensureAdvertisedLocator("tcp");

    const dialed = try host.openDialedLocator(tcpLocator("127.0.0.1:7090"));
    defer host.releaseSession(dialed) catch unreachable;
    const accepted = try host.openAcceptedAdvertised("tcp");
    defer host.releaseSession(accepted) catch unreachable;

    const expected = try pancake.ocapn.codec.signed.locationBytes(allocator, advertised);
    defer allocator.free(expected);
    const dialed_location = try helloLocatorBytes(allocator, dialed);
    defer allocator.free(dialed_location);
    const accepted_location = try helloLocatorBytes(allocator, accepted);
    defer allocator.free(accepted_location);
    try std.testing.expectEqualSlices(u8, expected, dialed_location);
    try std.testing.expectEqualSlices(u8, expected, accepted_location);
}

test "core host handshake: a key dial accepts the partner's selected address route" {
    const allocator = std.testing.allocator;
    var dialer = test_host.init(allocator, [_]u8{0x76} ** 32, Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    const partner_seed = [_]u8{0x77} ** 32;
    const partner_key = crypto.SecretKey.fromSeed(partner_seed).publicKey().toDesignator();

    try dialer.setAdvertisedLocator(tcpLocator("127.0.0.1:7092"));
    const session = try dialer.openDialedLocator(.{
        .transport = "iroh",
        .designator = &partner_key,
        .hints = model.Hints.emptyFalse(),
    });

    // The iroh channel reached the demanded key, while the peer asks future
    // sessions to use a TCP ingress. The hello's route is not a description of
    // this channel and therefore is not compared as though it were the dial
    // target.
    var hello = try handshake_support.signedHelloFrame(
        allocator,
        crypto.SecretKey.fromSeed(partner_seed),
        "tcp",
        "proxy.example:443",
        model.Hints.emptyFalse(),
    );
    defer hello.deinit();
    try dialer.feed(session, hello.view());
    try std.testing.expect(session.sessionOpen());
    try dialer.releaseSession(session);
}

test "core host advertised locator: dial and accept sign byte-identical snapshots" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x71} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var hints = [_]model.HintEntry{
        .{ .name = "route", .value = .{ .string = "published-once" } },
    };
    const advertised: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:7089",
        .hints = .{ .entries = &hints },
    };
    try host.setAdvertisedLocator(advertised);

    const dialed = try host.openDialedLocator(tcpLocator("127.0.0.1:7090"));
    defer host.releaseSession(dialed) catch unreachable;
    const accepted = try host.openAcceptedAdvertised("tcp");
    defer host.releaseSession(accepted) catch unreachable;

    const dial_bytes = try helloLocatorBytes(allocator, dialed);
    defer allocator.free(dial_bytes);
    const accept_bytes = try helloLocatorBytes(allocator, accepted);
    defer allocator.free(accept_bytes);
    const published_bytes = try pancake.ocapn.codec.signed.locationBytes(allocator, advertised);
    defer allocator.free(published_bytes);

    try std.testing.expectEqualSlices(u8, published_bytes, dial_bytes);
    try std.testing.expectEqualSlices(u8, published_bytes, accept_bytes);
    try std.testing.expect(!std.mem.eql(u8, advertised.designator, "127.0.0.1:7090"));
}

test "core host advertised locator retains complete multi-hint snapshots" {
    const allocator = std.testing.allocator;
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.captp_version = .next;
    opts.codec = .capnp;
    var host = test_host.init(allocator, [_]u8{0x78} ** 32, opts);
    defer host.deinit();

    const hints = [_]model.HintEntry{
        .{ .name = "route-a", .value = .{ .string = "one" } },
        .{ .name = "route-b", .value = .{ .string = "two" } },
        .{ .name = "route-c", .value = .{ .string = "three" } },
        .{ .name = "route-d", .value = .{ .string = "four" } },
    };
    try host.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:7088",
        .hints = .{ .entries = &hints },
    });

    const stored = host.acceptableLocator().?;
    try std.testing.expectEqual(@as(usize, hints.len + 2), stored.hints.entries.len);
    for (hints) |expected| {
        const actual = for (stored.hints.entries) |candidate| {
            if (std.mem.eql(u8, expected.name, candidate.name)) break candidate;
        } else return error.MissingHint;
        try std.testing.expectEqualStrings(expected.value.string, actual.value.string);
    }
}

test "core host onion advertisement stays hintless under a non-baseline preference" {
    const allocator = std.testing.allocator;
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.captp_version = .next;
    opts.codec = .capnp;
    var host = test_host.init(allocator, [_]u8{0x79} ** 32, opts);
    defer host.deinit();

    const service_id = [_]u8{'a'} ** 56;
    const supplied_hints = [_]model.HintEntry{.{
        .name = "must-not-escape",
        .value = .{ .string = "not part of the onion locator grammar" },
    }};
    const onion: model.PeerLocator = .{
        .transport = model.transport.onion,
        .designator = &service_id,
        .hints = .{ .entries = &supplied_hints },
    };
    try host.setAdvertisedLocator(onion);

    const stored = host.acceptableLocator().?;
    try std.testing.expectEqual(@as(usize, 0), stored.hints.entries.len);
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, stored.hints.wire_form);

    const accepted = try host.openAcceptedAdvertised(model.transport.onion);
    defer host.releaseSession(accepted) catch unreachable;
    const hello_location = try helloLocatorBytes(allocator, accepted);
    defer allocator.free(hello_location);
    const expected = try pancake.ocapn.codec.signed.locationBytes(allocator, .{
        .transport = onion.transport,
        .designator = onion.designator,
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, hello_location);
}

fn tcpSturdyref(designator: []const u8, swissnum: []const u8) model.SturdyRef {
    return .{ .peer = tcpLocator(designator), .swissnum = swissnum };
}

fn onionLocator(designator: []const u8) model.PeerLocator {
    return .{
        .transport = model.transport.onion,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
}

fn onionSturdyref(designator: []const u8, swissnum: []const u8) model.SturdyRef {
    return .{ .peer = onionLocator(designator), .swissnum = swissnum };
}

/// One dial request parked for the test to execute, designator duped clear of
/// the action queue's popped-view lifetime.
const ParkedDial = struct { host: *Host, ticket: pancake.ocapn.engine.Node.PendingId, designator: []u8 };

/// Drain every host's action queue: gift-id requests are answered inline with
/// deterministic bytes (entropy is the embedder's job), flush notices are
/// no-ops here (the shuttle polls every queue anyway), and dial requests park
/// on `dials` for the test to execute explicitly.
fn drainActions(allocator: std.mem.Allocator, hosts: []const *Host, dials: *std.ArrayList(ParkedDial)) !bool {
    var did_work = false;
    for (hosts) |host| {
        while (try host.nextAction()) |action| {
            switch (action) {
                .flush => {},
                .need_gift_id => |n| {
                    const gift_id = [_]u8{0x5a} ** 32;
                    try host.provideGiftId(n.ticket, &gift_id);
                    did_work = true;
                },
                .dial => |d| {
                    // Ticket-only action: pending row owns the dial view (no re-parse).
                    // Every dial in this file targets a tcp locator with a
                    // socket-address designator.
                    const view = host.pendingDial(d.ticket) orelse return error.MissingPendingDial;
                    try std.testing.expectEqualStrings("tcp", view.transport);
                    try std.testing.expect(view.designator.len != 0);
                    try dials.append(allocator, .{
                        .host = host,
                        .ticket = d.ticket,
                        .designator = try allocator.dupe(u8, view.designator),
                    });
                    did_work = true;
                },
                // An unlistened vow's completion; the tests in this file that
                // route completions drain `nextAction` by hand instead.
                .settled, .failed => {},
                // Only a budgeted host condemns and closes; no test in this
                // file sets a `local_turn_budget`.
                .close => {},
                // A finite host quantum can yield internal work without an
                // external effect; the next action drain is the continuation.
                .resume_work => {},
            }
        }
    }
    return did_work;
}

/// Pump shuttles and action drains until the whole network is quiescent.
fn pumpToQuiescence(
    allocator: std.mem.Allocator,
    hosts: []const *Host,
    pairs: []const Pair,
    dials: *std.ArrayList(ParkedDial),
) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const moved = try shuttleAll(pairs);
        const acted = try drainActions(allocator, hosts, dials);
        if (!moved and !acted) return;
    }
    return error.PumpDidNotQuiesce;
}

const CapturedRef = promise_capture.CapturedRef;
const CapturedString = promise_capture.CapturedString;

/// Open a dialed/accepted pair between two hosts and drive the keyed
/// handshake open over fed bytes.
fn openPair(
    allocator: std.mem.Allocator,
    dialer: *Host,
    acceptor: *Host,
    designator: []const u8,
    dials: *std.ArrayList(ParkedDial),
) !Pair {
    try dialer.ensureAdvertisedLocator("tcp");
    try acceptor.setAdvertisedLocator(tcpLocator(designator));
    const accepted = try acceptor.openAcceptedAdvertised("tcp");
    const dialed = try dialer.openDialedLocator(tcpLocator(designator));
    const pair = Pair{ .ah = dialer, .a = dialed, .bh = acceptor, .b = accepted };
    try pumpToQuiescence(allocator, &.{ dialer, acceptor }, &.{pair}, dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());
    return pair;
}

test "core host: listen refuses a foreign near target before routing" {
    const allocator = std.testing.allocator;
    var caller = test_host.init(allocator, [_]u8{0x38} ** 32, Host.Options.withFrameCap(frame_cap));
    defer caller.deinit();
    var owner = test_host.init(allocator, [_]u8{0x39} ** 32, Host.Options.withFrameCap(frame_cap));
    defer owner.deinit();
    var partner = test_host.init(allocator, [_]u8{0x3a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &owner, &partner, "127.0.0.1:7095", &dials);
    try std.testing.expectError(
        driver.core.HostError.ForeignSession,
        caller.listenTo(pair.a, .{ .near = model.NearRef.object(1) }),
    );
}

test "core host: publication refuses callback reentry before Vat spawn" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x3c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7096", &dials);

    var refused = false;
    _ = try pair.b.served.publish(&host.vat, "probe", PublicationProbe, .{
        .host = &host,
        .refused = &refused,
    });
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "probe"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &host }, &.{pair}, &dials);
    const probe = try fetched.require();
    _ = try client.send(pair.a, probe, .{ .verb = "publish", .args = &.{} });
    try pumpToQuiescence(allocator, &.{ &client, &host }, &.{pair}, &dials);

    try std.testing.expect(refused);
    try std.testing.expectEqual(@as(?u64, null), try host.publishedPosition(pair.b, "nested"));
}

test "core host: foreign release validates before trace close" {
    const allocator = std.testing.allocator;
    var caller = test_host.init(allocator, [_]u8{0x3d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer caller.deinit();
    var owner = test_host.init(allocator, [_]u8{0x3e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer owner.deinit();
    var partner = test_host.init(allocator, [_]u8{0x3f} ** 32, Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();
    var caller_log = TraceLog{};
    caller.setTrace(.{ .ctx = &caller_log, .emit = TraceLog.emit });
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &owner, &partner, "127.0.0.1:7097", &dials);
    try std.testing.expectError(driver.core.HostError.ForeignSession, caller.releaseSession(pair.a));
    try std.testing.expectEqual(@as(usize, 0), caller_log.n);
    try owner.releaseSession(pair.a);
    try partner.releaseSession(pair.b);
}

test "core host: two hosts complete the keyed handshake over fed bytes" {
    const allocator = std.testing.allocator;
    var a = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer a.deinit();
    var b = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer b.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    _ = try openPair(allocator, &a, &b, "127.0.0.1:7001", &dials);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
}

test "core host: keyed-tcp handshake leaves durable identity unauthenticated" {
    const allocator = std.testing.allocator;
    const acceptor_seed = [_]u8{0x2b} ** 32;
    var dialer = test_host.init(allocator, [_]u8{0x2a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    var acceptor = test_host.init(allocator, acceptor_seed, Host.Options.withFrameCap(frame_cap));
    defer acceptor.deinit();

    const designator = crypto.SecretKey.fromSeed(acceptor_seed).publicKey().toDesignator();
    const accepted = try publishAndOpenAccepted(&acceptor, "keyed-tcp", designator[0..], "127.0.0.1:7777");
    try dialer.ensureAdvertisedLocator("keyed-tcp");
    const dialed = try dialer.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    });
    const pair = Pair{ .ah = &dialer, .a = dialed, .bh = &acceptor, .b = accepted };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    try pumpToQuiescence(allocator, &.{ &dialer, &acceptor }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());
}

test "core host: a host that never listens still advertises its key on a key transport" {
    // The defect a WebRTC direct message showed: a browser Host never starts a
    // listener, so it never sets a self designator, and its dialing hello
    // signed the unreachable-client placeholder. That is a `tcp` *address*, on
    // a transport whose designator grammar is a key, so the far end could
    // attribute nothing and every consumer downstream honestly reported that
    // it knew nobody.
    //
    // There is exactly one legal value here and the host can derive it, so it
    // does (`sessions.advertisedDesignator`). Held over `webrtc` because that
    // is where it was found, and the same derivation serves `iroh`,
    // `keyed-tcp`, and `keyed-relay`.
    const allocator = std.testing.allocator;
    const client_seed = [_]u8{0x7a} ** 32;
    const server_seed = [_]u8{0x7b} ** 32;
    var client = test_host.init(allocator, client_seed, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    // The browser peer has no listener to publish an address from, and the
    // answering member is reached by signaling.
    const server_designator = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, "webrtc", &server_designator, &.{});
    try client.ensureAdvertisedLocator("webrtc");
    const dialed = try client.openDialedLocator(.{
        .transport = "webrtc",
        .designator = &server_designator,
        .hints = model.Hints.emptyFalse(),
    });
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());

    // The browser still advertises its key rather than an unreachable address,
    // but this byte-fed path supplies no channel proof for that claim.
    const client_designator = keyedDesignator(client_seed);
    const seen = try server.partnerIdentity(pair.b);
    try std.testing.expectEqualStrings(&client_designator, seen.designator);
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, seen.provenance);
    try std.testing.expect(!seen.durableIdentityAuthenticated());
}

test "core host: verified session directory authenticates an early handoff gifter" {
    const allocator = std.testing.allocator;
    var gifter = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var exporter = test_host.init(allocator, [_]u8{0x0d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7003", &dials);
    const exporter_peer = pair.b.served.port.peer;
    const gifter_key = exporter_peer.session_state.partnerSessionKey().?;
    const exporter_key = exporter_peer.session_state.localSessionKey().?;
    const gifter_side = try engine.handoff_names.sideName(gifter_key);
    const exporter_side = try engine.handoff_names.sideName(exporter_key);
    const session_name = engine.handoff_names.sessionName(gifter_side, exporter_side);

    const resolver = exporter.node.gifterSessionResolver().?;
    const resolved = resolver.resolve(resolver.ctx, gifter_side, &session_name) orelse
        return error.MissingGifterKey;
    try std.testing.expectEqualSlices(u8, gifter_key, &resolved.key);
    try std.testing.expectEqual(exporter_peer.giftRegistry(), resolved.gifts);
    var wrong_session = session_name;
    wrong_session[0] ^= 0xff;
    try std.testing.expect(resolver.resolve(resolver.ctx, gifter_side, &wrong_session) == null);

    try exporter.releaseSession(pair.b);
    try std.testing.expect(resolver.resolve(resolver.ctx, gifter_side, &session_name) == null);
    try gifter.releaseSession(pair.a);
}

test "session identity: an old handoff certificate cannot resolve against a session opened after reconnect" {
    // ADR-0097 evidence item 10, the property fresh per-session keys exist to
    // provide. A `desc:handoff-give` names its gifter–exporter session by the
    // side names derived from both ends' session keys. While every session in a
    // host reused that host's durable key those names were a function of the
    // two *hosts*, so reconnecting the same pair rebuilt the identical names
    // and a stale certificate resolved against the replacement session. With a
    // key per session the names are a function of the session, and the
    // old certificate resolves against nothing.
    //
    // Liveness is deliberately not what makes this pass: a live session
    // between the same durable peers exists throughout the final assertions.
    // The sibling test above already covers "the session closed"; this one
    // covers "a different session is open in its place", which is the case
    // reconnect actually produces and the one key reuse got wrong.
    //
    // Out of scope, and stated rather than implied: replaying a whole captured
    // keyed-TCP hello can revive its own static session claim on another
    // cleartext connection. Fresh keys isolate *honest* reconnects; they do not
    // make a cleartext channel replay-safe, which ADR-0075 records.
    const allocator = std.testing.allocator;
    const opts = Host.Options.withFrameCap(frame_cap);
    var gifter = test_host.init(allocator, [_]u8{0x0c} ** 32, opts);
    defer gifter.deinit();
    var exporter = test_host.init(allocator, [_]u8{0x0d} ** 32, opts);
    defer exporter.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    // The first connection, and the certificate names it would carry.
    const first = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7321", &dials);
    const first_peer = first.b.served.port.peer;
    const old_gifter_side = try engine.handoff_names.sideName(first_peer.session_state.partnerSessionKey().?);
    const old_exporter_side = try engine.handoff_names.sideName(first_peer.session_state.localSessionKey().?);
    const old_session = engine.handoff_names.sessionName(old_gifter_side, old_exporter_side);

    const resolver = exporter.node.gifterSessionResolver().?;
    try std.testing.expect(resolver.resolve(resolver.ctx, old_gifter_side, &old_session) != null);

    // Honest reconnect: both halves go away and the same two hosts, with the
    // same durable identities, open a fresh connection.
    try exporter.releaseSession(first.b);
    try gifter.releaseSession(first.a);
    const second = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7322", &dials);
    const second_peer = second.b.served.port.peer;
    const new_gifter_side = try engine.handoff_names.sideName(second_peer.session_state.partnerSessionKey().?);
    const new_exporter_side = try engine.handoff_names.sideName(second_peer.session_state.localSessionKey().?);
    const new_session = engine.handoff_names.sessionName(new_gifter_side, new_exporter_side);

    // The teeth: the replacement session really does have different names.
    // Without this the refusal below could pass for the wrong reason, and
    // under key reuse this is exactly the assertion that fails.
    try std.testing.expect(!std.mem.eql(u8, &old_gifter_side, &new_gifter_side));
    try std.testing.expect(!std.mem.eql(u8, &old_session, &new_session));

    // The property itself: the stale certificate's names resolve to nothing,
    // while a live session to the same durable peer is open and resolving.
    try std.testing.expect(resolver.resolve(resolver.ctx, old_gifter_side, &old_session) == null);
    try std.testing.expect(resolver.resolve(resolver.ctx, new_gifter_side, &new_session) != null);

    // Nor can the stale side name borrow the new session by naming it: the
    // resolver matches the pair, so neither half of an old certificate can be
    // mixed with a current one.
    try std.testing.expect(resolver.resolve(resolver.ctx, old_gifter_side, &new_session) == null);
    try std.testing.expect(resolver.resolve(resolver.ctx, new_gifter_side, &old_session) == null);

    // This is also the whole of "and must not consume a new deposit with the
    // same gift id" (ADR-0097 item 10). A withdrawal reaches a gift registry
    // only through this resolver — it is what hands back the `gifts` a
    // consuming withdraw operates on — so a certificate whose names resolve to
    // nothing never reaches any registry, and a gift deposited on the
    // replacement session under a reused id is unreachable by it rather than
    // defended against after the fact.
    const live = resolver.resolve(resolver.ctx, new_gifter_side, &new_session).?;
    try std.testing.expectEqual(second_peer.giftRegistry(), live.gifts);

    try exporter.releaseSession(second.b);
    try gifter.releaseSession(second.a);
}

test "core host: select-or-dial enlivens over a live session, and parks on a staged dial" {
    // ADR-0098 step 4 at the byte-fed tier: the same select-or-dial the native
    // HostRuntime performs, driven here by an embedder that only answers actions.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |d| allocator.free(d.designator);
        dials.deinit(allocator);
    }

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7801", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    // SELECT: the sturdyref names a peer this host already dialed, so the
    // enliven rides that session and no dial is ever staged.
    const selected = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7801", "widget"));
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
    var settled = CapturedRef{};
    try client.vowOn(selected, .{ .ctx = &settled, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    _ = try settled.require();
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);

    // DIAL: an unreached peer parks the enliven on a staged dial, which
    // reaches the embedder as the ordinary `dial` action — one ticket space,
    // so the embedder's dial arm is unchanged.
    var second = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer second.deinit();
    const parked_vow = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7802", "widget"));
    try std.testing.expect(parked_vow != selected);
    // The vow is parked, not rowed: an observer is refused exactly as it is
    // for a dedup-cache hit, and the outcome arrives as an action.
    try std.testing.expectError(
        driver.core.HostError.NoSuchVow,
        client.vowOn(parked_vow, .{ .ctx = &settled, .func = CapturedRef.record }),
    );
    _ = try drainActions(allocator, &.{ &client, &server }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    try std.testing.expectEqualStrings("127.0.0.1:7802", dials.items[0].designator);

    // The embedder opens the connection it was told to and reports it; the
    // parked enliven then runs over that fresh session.
    const accepted = try publishAndOpenAccepted(&second, "tcp", "127.0.0.1:7802", &.{});
    _ = try accepted.served.publish(&accepted.host.vat, "widget", Widget, .{});
    const dialed = try client.openDialedLocator(tcpLocator("127.0.0.1:7802"));
    const second_pair = Pair{ .ah = &client, .a = dialed, .bh = &second, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &second }, &.{second_pair}, &dials);
    const ticket = dials.items[0].ticket;
    allocator.free(dials.items[0].designator);
    _ = dials.orderedRemove(0);
    try client.exporterDialed(ticket, dialed);

    // The pre-minted vow settles through the action queue, naming the widget.
    // Drain by hand: the shared `drainActions` swallows completions, and this
    // one is the whole point.
    var saw_parked = false;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const moved = try shuttleAll(&.{ pair, second_pair });
        var acted = false;
        for ([_]*Host{ &client, &second }) |host| {
            while (try host.nextAction()) |action| {
                acted = true;
                switch (action) {
                    .settled => |s| if (s.vow_id == parked_vow) {
                        try std.testing.expect(s.value == .reference);
                        saw_parked = true;
                    },
                    else => {},
                }
            }
        }
        if (!moved and !acted) break;
    }
    try std.testing.expect(saw_parked);
}

test "core host: a select-or-dial enliven breaks when its staged dial fails" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |d| allocator.free(d.designator);
        dials.deinit(allocator);
    }

    const parked_vow = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7803", "widget"));
    _ = try drainActions(allocator, &.{&client}, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const ticket = dials.items[0].ticket;
    allocator.free(dials.items[0].designator);
    _ = dials.orderedRemove(0);

    // The embedder could not open it: the parked vow breaks rather than
    // stranding, and it breaks host-scoped — no session ever existed.
    try client.dialFailed(ticket, "connection refused");
    var broke = false;
    while (try client.nextAction()) |action| {
        switch (action) {
            .failed => |f| if (f.vow_id == parked_vow) {
                try std.testing.expect(f.peer_id == null);
                broke = true;
            },
            else => {},
        }
    }
    try std.testing.expect(broke);
}

test "core host: a failed pending path reuses its ticket for the next locator" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x0d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const alternative = try model.uri.writePeer(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:7811",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(alternative);
    var entries = [_]model.HintEntry{.{
        .name = model.transport.hint_alt_locators,
        .value = .{ .string = alternative },
    }};
    const sturdyref = model.SturdyRef{
        .peer = .{
            .transport = model.transport.tcp,
            .designator = "127.0.0.1:7810",
            .hints = .{ .entries = &entries },
        },
        .swissnum = "widget",
    };

    const vow_id = try host.enlivenSelectOrDial(sturdyref);
    const first = (try host.nextAction()).?;
    try std.testing.expect(first == .dial);
    const ticket = first.dial.ticket;
    try std.testing.expectEqualStrings("127.0.0.1:7810", host.pendingDial(ticket).?.designator);

    // The Host action remains transport-blind: reporting failure is enough for
    // Node to advance the active view and queue the same ticket again.
    try host.dialFailed(ticket, "primary unreachable");
    const retry = (try host.nextAction()).?;
    try std.testing.expect(retry == .dial);
    try std.testing.expectEqual(ticket, retry.dial.ticket);
    try std.testing.expectEqualStrings("127.0.0.1:7811", host.pendingDial(ticket).?.designator);

    try host.dialFailed(ticket, "alternative unreachable");
    const failed = (try host.nextAction()).?;
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqual(vow_id, failed.failed.vow_id);
    try std.testing.expectEqualStrings("alternative unreachable", failed.failed.message);
}

test "core host: sturdyref peer mismatch and accepted TCP assertion refuse before fetch" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);

    try std.testing.expectError(
        driver.core.HostError.PeerIdentityMismatch,
        client.enliven(pair.a, tcpSturdyref("127.0.0.1:7999", "same-swiss")),
    );
    try std.testing.expect((try pair.a.takeOutbound()) == null);

    const claimed = tcpSturdyref(driver.unreachable_client_designator, "same-swiss");
    try std.testing.expectError(
        driver.core.HostError.PeerIdentityUnverified,
        server.enliven(pair.b, claimed),
    );
    try std.testing.expect((try pair.b.takeOutbound()) == null);

    const opted = try server.enlivenWithPolicy(pair.b, claimed, .assertion_only);
    try std.testing.expectEqual(driver.core.PeerProvenance.assertion_only, opted.provenance);
    var fetch_frame = (try pair.b.takeOutbound()) orelse return error.MissingFetch;
    fetch_frame.deinit();
}

test "core host: feedBytes rejects an outer length over cap before its body" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(8));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7010", &.{});
    try std.testing.expectError(error.FrameTooLarge, host.feedBytes(session, "9:"));
}

test "core host: publish, fetch, and a settled send over fed bytes" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    // Fetch arrives already enrolled as a node-unique token; the in-process
    // listener chains onto the fetch's own vow.
    var fetched = CapturedRef{};
    const fetch_vow = try client.fetch(pair.a, "widget");
    try client.vowOn(fetch_vow, .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();

    // A send through the token settles with the exporter's reply.
    const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    var reply = CapturedString{};
    try client.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", reply.buf[0..reply.len]);
}

/// One generation of a host-wide giftable. The reply is the tag its row carries,
/// so a call says *which* registration answered rather than only that one did.
const Tagged = struct {
    row: *TaggedRow,

    pub fn clone(self: *const Tagged, allocator: std.mem.Allocator) !Tagged {
        _ = allocator;
        return .{ .row = self.row };
    }

    pub fn handle(self: *Tagged, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "mutate")) {
            self.row.tag = "mutated-original";
        } else if (!std.mem.eql(u8, msg.verb, "tag")) return error.NoSuchMethod;
        return .{ .string = self.row.tag };
    }

    pub fn deinit(self: *Tagged, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.row.freed.* = true;
    }
};

/// The `ctx` behind one giftable registration, which every actor it published
/// borrows. `free` records the release instead of doing one, so a test can say
/// when the host let go.
const TaggedRow = struct {
    tag: []const u8,
    freed: *bool,
};

test "core host: a replaced giftable keeps answering at the position it already granted" {
    // `publishGiftable` replacement changes discovery, not a live capability. The
    // displaced actor remains exported at its existing position and still
    // reads the state it was spawned with. Hence: hold a capability to the
    // first registration, replace the name, and call the capability.
    const allocator = std.testing.allocator;
    var first_freed = false;
    var second_freed = false;
    var first = TaggedRow{ .tag = "first", .freed = &first_freed };
    var second = TaggedRow{ .tag = "second", .freed = &second_freed };
    {
        var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
        defer client.deinit();
        var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(allocator);

        const pair = try openPair(allocator, &client, &server, "127.0.0.1:7061", &dials);
        _ = try server.publishGiftable("inbox", Tagged, .{ .row = &first });
        const first_position = (try server.publishedPosition(pair.b, "inbox")).?;

        // The client takes a routable capability to the first registration while
        // it is still the one the name resolves to.
        var held = CapturedRef{};
        const fetch_vow = try client.fetch(pair.a, "inbox");
        try client.vowOn(fetch_vow, .{ .ctx = &held, .func = CapturedRef.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        const first_cap = try held.require();

        _ = try server.publishGiftable("inbox", Tagged, .{ .row = &second });
        const second_position = (try server.publishedPosition(pair.b, "inbox")).?;
        try std.testing.expect(first_position != second_position);
        try std.testing.expect(!first_freed);

        // The held capability still reaches the first registration's actor, and
        // the actor still reads the ctx it was published with.
        const old_vow = try client.send(pair.a, first_cap, .{ .verb = "tag", .args = &.{} });
        var old_reply = CapturedString{};
        try client.vowOn(old_vow, .{ .ctx = &old_reply, .func = CapturedString.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        try std.testing.expectEqualStrings("first", old_reply.buf[0..old_reply.len]);

        // A fetch by name now resolves to the replacement, so the name moved even
        // though the capability did not.
        var fresh = CapturedRef{};
        const second_fetch = try client.fetch(pair.a, "inbox");
        try client.vowOn(second_fetch, .{ .ctx = &fresh, .func = CapturedRef.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        const second_cap = try fresh.require();
        const new_vow = try client.send(pair.a, second_cap, .{ .verb = "tag", .args = &.{} });
        var new_reply = CapturedString{};
        try client.vowOn(new_vow, .{ .ctx = &new_reply, .func = CapturedString.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        try std.testing.expectEqualStrings("second", new_reply.buf[0..new_reply.len]);
    }
    // Both Vat actors are released at Host teardown, including the one no
    // longer reachable through the alias.
    try std.testing.expect(first_freed);
    try std.testing.expect(second_freed);
}

test "core host: a deposited gift keeps its exact actor across alias replacement and a second exporter Port" {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var original_freed = false;
    var replacement_freed = false;
    var original = TaggedRow{ .tag = "original", .freed = &original_freed };
    var replacement = TaggedRow{ .tag = "replacement", .freed = &replacement_freed };
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &original });

    // Gifter dials the exporter and fetches the widget: the node records the
    // capability's foreign home, which is what the give will name. Fetch lazily
    // projects the Host-Vat actor onto this first exporter Port.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();

    // Mutate through the capability on the gifter-facing Port. The later call
    // through the recipient-facing Port must observe this same actor state.
    var mutated = CapturedString{};
    try gifter.vowOn(try gifter.send(g_to_e.a, widget_ref, .{ .verb = "mutate", .args = &.{} }), .{ .ctx = &mutated, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    try std.testing.expectEqualStrings("mutated-original", mutated.buf[0..mutated.len]);

    // Recipient dials the gifter and fetches the introducer.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    // The introduction: the gifter's reply fulfills with a foreign-homed
    // capability, the gifter host originates the give (gift-id entropy
    // answered through its action queue), and the recipient host claims the
    // give and surfaces exactly one dial action naming the exporter.
    const introduce_vow = try recipient.send(r_to_g.a, introducer_ref, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];
    try std.testing.expect(parked.host == &recipient);
    try std.testing.expect(std.mem.indexOf(u8, parked.designator, "127.0.0.1") != null);

    // The deposit has crossed the gifter-facing exporter Port and captured the
    // original actor. Move the public alias before the recipient opens its own
    // exporter Port. A withdraw-time name lookup would now redirect the gift.
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &replacement });

    // The test is the dial executor: open the recipient's own connection to
    // the exporter, drive it open, and report it back. The withdraw, its
    // settle, and the vow's fulfillment all pump inside the report. No alias is
    // projected on this Port until either the exact gift or a fresh fetch asks.
    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7001", &.{});
    // Production Bridge dials from pendingDial parts — no URI re-parse.
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(r_to_e.sessionOpen());
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    const token_ref = try redeemed.require();
    try std.testing.expect(token_ref == .far);

    // The redeemed capability reaches the actor deposited before replacement,
    // not whichever actor the alias names at withdrawal time.
    const exact_vow = try recipient.send(r_to_g.a, token_ref, .{ .verb = "tag", .args = &.{} });
    var exact = CapturedString{};
    try recipient.vowOn(exact_vow, .{ .ctx = &exact, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("mutated-original", exact.buf[0..exact.len]);

    // Discovery did move: a fresh fetch over that same recipient-facing Port
    // resolves the replacement. The test distinguishes capability identity
    // from the mutable public name in both directions.
    var discovered = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_e, "widget"), .{ .ctx = &discovered, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    const replacement_ref = try discovered.require();
    const replacement_vow = try recipient.send(r_to_e, replacement_ref, .{ .verb = "tag", .args = &.{} });
    var replacement_reply = CapturedString{};
    try recipient.vowOn(replacement_vow, .{ .ctx = &replacement_reply, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("replacement", replacement_reply.buf[0..replacement_reply.len]);
}

test "core host: unpublish removes discovery on every session while issued capabilities and deposited gifts keep the exact actor" {
    // The alias-only unpublish scenario (ADR-0096): all three required
    // outcomes in one production Host. Fresh lookup of the removed alias
    // fails — including on a Port that fetched it before, because the
    // registry is the one discovery authority and a fetch leaves no
    // per-session alias copy behind — while a capability issued before
    // removal remains callable and a gift deposited before removal still
    // redeems the exact (mutated) actor.
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x1e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x16} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x1c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var widget_freed = false;
    var widget_row = TaggedRow{ .tag = "original", .freed = &widget_freed };
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &widget_row });

    // Gifter dials the exporter, fetches the widget (issuing a capability and
    // projecting the actor on this Port), and mutates it.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7021", &dials);
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();
    var mutated = CapturedString{};
    try gifter.vowOn(try gifter.send(g_to_e.a, widget_ref, .{ .verb = "mutate", .args = &.{} }), .{ .ctx = &mutated, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    try std.testing.expectEqualStrings("mutated-original", mutated.buf[0..mutated.len]);

    // The introduction deposits the gift on the gifter-facing exporter Port.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7022", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introduce_vow = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    // Remove the alias after the deposit and before the recipient's own
    // exporter session exists. A second removal of the same name is a loud
    // miss, and the projection query observes the removal too.
    try exporter.unpublish("widget");
    try std.testing.expectError(error.UnknownPublication, exporter.unpublish("widget"));
    try std.testing.expectEqual(@as(?u64, null), try exporter.publishedPosition(g_to_e.b, "widget"));

    // Outcome 1a: a fresh fetch of the removed alias breaks on the Port that
    // fetched it before — discovery is registry-only, with no session copy.
    var stale_fetch = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &stale_fetch, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expect(stale_fetch.broken);

    // Outcome 2: the capability issued before removal remains callable and
    // still reads the mutated state.
    var issued = CapturedString{};
    try gifter.vowOn(try gifter.send(g_to_e.a, widget_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &issued, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqualStrings("mutated-original", issued.buf[0..issued.len]);

    // Outcome 3: the deposited gift still redeems the exact actor over the
    // recipient's own exporter session, opened after the removal.
    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7021", &.{});
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(r_to_e.sessionOpen());
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    const token_ref = try redeemed.require();
    var exact = CapturedString{};
    try recipient.vowOn(try recipient.send(r_to_g.a, token_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &exact, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("mutated-original", exact.buf[0..exact.len]);

    // Outcome 1b: the removed alias also misses on the fresh Port the redeem
    // opened, so no session ever resolves it again.
    var fresh_fetch = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_e, "widget"), .{ .ctx = &fresh_fetch, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(fresh_fetch.broken);

    // Alias-only: the actor survives the unpublish through its remaining
    // roots (the two exporter Ports' export bindings; the consumed gift's
    // root transferred to the withdraw projection).
    try std.testing.expect(!widget_freed);

    // A never-fetched alias has only its alias root: unpublish alone reclaims
    // it (ADR-0101), observed at the next Vat turn boundary.
    var unfetched_freed = false;
    var unfetched_row = TaggedRow{ .tag = "unfetched", .freed = &unfetched_freed };
    _ = try exporter.publishGiftable("unfetched", Tagged, .{ .row = &unfetched_row });
    try exporter.unpublish("unfetched");
    var boundary_freed = false;
    var boundary_row = TaggedRow{ .tag = "boundary", .freed = &boundary_freed };
    const boundary = try exporter.vat.spawn(Tagged, .{ .row = &boundary_row });
    _ = try exporter.vat.near(boundary, .{ .verb = "tag" });
    try std.testing.expect(unfetched_freed);

    // Closing the sessions that project the widget releases the last roots
    // (each session releases exactly its own retains), and the boundary turn
    // reclaims the actor before Host teardown.
    try exporter.releaseSession(g_to_e.b);
    try exporter.releaseSession(e_accepts_r);
    _ = try exporter.vat.near(boundary, .{ .verb = "tag" });
    try std.testing.expect(widget_freed);
}

/// Spawns one unnamed stateful actor per `make` and replies with it: how a
/// test obtains a capability to an actor no alias ever named (ADR-0096
/// evidence item 2).
const UnnamedMaker = struct {
    row: *TaggedRow,
    pub fn handle(self: *UnnamedMaker, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "make")) return error.NoSuchMethod;
        const cap = try driver.spawnAt(turn, Tagged, .{ .row = self.row });
        return cap.arg();
    }
};

test "core host: an unnamed local target deposits and withdraws as the exact mutated actor" {
    // ADR-0096 evidence item 2: no alias anywhere near the gifted object. The
    // exporter's maker spawns it unnamed inside a turn; the gifter reaches it
    // through an ordinary call reply, lifts and re-lowers it through its own
    // Host to make it routable, mutates it, and introduces it. Withdrawal
    // projects the exact actor.
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x2e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x26} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x2c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var widget_freed = false;
    var widget_row = TaggedRow{ .tag = "original", .freed = &widget_freed };
    _ = try exporter.publishGiftable("maker", UnnamedMaker, .{ .row = &widget_row });

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7031", &dials);
    var maker = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "maker"), .{ .ctx = &maker, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    // The unnamed widget arrives in an ordinary call reply, and the gifter
    // mutates it over that same session.
    var made = CapturedRef{};
    try gifter.vowOn(try gifter.send(g_to_e.a, try maker.require(), .{ .verb = "make", .args = &.{} }), .{ .ctx = &made, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const made_ref = try made.require();
    var mutated = CapturedString{};
    try gifter.vowOn(try gifter.send(g_to_e.a, made_ref, .{ .verb = "mutate", .args = &.{} }), .{ .ctx = &mutated, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    try std.testing.expectEqualStrings("mutated-original", mutated.buf[0..mutated.len]);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7032", &dials);

    // Lifting the bare reply reference and lowering it onto the
    // recipient-facing session is what makes it routable for re-gifting —
    // the same lift/lower seam the owning facade fuses into its argument
    // walk. The result is a Node token whose home is the exporter session.
    const lifted = try gifter.liftCapability(g_to_e.a, made_ref);
    const widget_ref = try gifter.lowerCapability(r_to_g.b, lifted);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    var redeemed = CapturedRef{};
    try recipient.vowOn(try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} }), .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7031", &.{});
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // The withdrawn capability is the exact unnamed actor, mutated state and
    // all. No alias existed for any lookup to consult.
    const token_ref = try redeemed.require();
    var exact = CapturedString{};
    try recipient.vowOn(try recipient.send(r_to_g.a, token_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &exact, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("mutated-original", exact.buf[0..exact.len]);
}

/// A persistent becomer: `bump` installs the next state through `become`, so
/// two Ports observing one history is the discriminating cross-Port claim
/// (ADR-0096 evidence item 5's `become` half).
const Becomer = struct {
    pub const snapshot_persistent = true;
    n: i64,

    pub fn handle(self: *const Becomer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "bump")) {
            try turn.become(Becomer, .{ .n = self.n + 1 });
            return .{ .integer = self.n + 1 };
        }
        return error.NoSuchMethod;
    }
};

test "core host: one actor's become history is observed across two Ports" {
    const allocator = std.testing.allocator;
    var server = test_host.init(allocator, [_]u8{0x3a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var alice = test_host.init(allocator, [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer alice.deinit();
    var bob = test_host.init(allocator, [_]u8{0x3c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer bob.deinit();
    const hosts = [_]*Host{ &server, &alice, &bob };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    _ = try server.publishGiftable("counter", Becomer, .{ .n = 0 });
    const a = try openPair(allocator, &alice, &server, "127.0.0.1:7041", &dials);
    const b = try openPair(allocator, &bob, &server, "127.0.0.1:7042", &dials);
    var a_cap = CapturedRef{};
    try alice.vowOn(try alice.fetch(a.a, "counter"), .{ .ctx = &a_cap, .func = CapturedRef.record });
    var b_cap = CapturedRef{};
    try bob.vowOn(try bob.fetch(b.a, "counter"), .{ .ctx = &b_cap, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);

    const CapturedInt = struct {
        value: ?i64 = null,
        fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (resolution == .fulfilled and resolution.fulfilled == .integer)
                self.value = resolution.fulfilled.integer;
        }
    };

    // Alice's bump becomes n=1; Bob reads the installed history, not a copy.
    var bumped = CapturedInt{};
    try alice.vowOn(try alice.send(a.a, try a_cap.require(), .{ .verb = "bump", .args = &.{} }), .{ .ctx = &bumped, .func = CapturedInt.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqual(@as(?i64, 1), bumped.value);
    var bob_read = CapturedInt{};
    try bob.vowOn(try bob.send(b.a, try b_cap.require(), .{ .verb = "get", .args = &.{} }), .{ .ctx = &bob_read, .func = CapturedInt.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqual(@as(?i64, 1), bob_read.value);

    // And the other direction: Bob's bump lands in the history Alice reads.
    var bob_bump = CapturedInt{};
    try bob.vowOn(try bob.send(b.a, try b_cap.require(), .{ .verb = "bump", .args = &.{} }), .{ .ctx = &bob_bump, .func = CapturedInt.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqual(@as(?i64, 2), bob_bump.value);
    var alice_read = CapturedInt{};
    try alice.vowOn(try alice.send(a.a, try a_cap.require(), .{ .verb = "get", .args = &.{} }), .{ .ctx = &alice_read, .func = CapturedInt.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqual(@as(?i64, 2), alice_read.value);
}

test "core host: a target reached directly and through handoff lifts to one Host identity" {
    // ADR-0096 evidence item 7, the positive remote half of target
    // pass-invariant equality: both paths explicitly use the same live
    // exporter session, so the canonical import row makes the two arrivals
    // one opaque identity.
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x4e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x46} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x4c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var widget_freed = false;
    var widget_row = TaggedRow{ .tag = "original", .freed = &widget_freed };
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &widget_row });

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7051", &dials);
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7052", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = try widget.require() });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    var redeemed = CapturedRef{};
    try recipient.vowOn(try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} }), .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7051", &.{});
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    const token_ref = try redeemed.require();

    // The same target, reached the other way: an ordinary fetch over the very
    // session the redeem opened.
    var direct = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_e, "widget"), .{ .ctx = &direct, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // Both arrivals lift to one canonical opaque identity and compare Equal.
    const via_handoff = try recipient.liftCapability(r_to_g.a, token_ref);
    const via_fetch = try recipient.liftCapability(r_to_e, try direct.require());
    try std.testing.expect(via_handoff.eql(via_fetch));
}

test "core host: restore under two live sessions breaks only the missing target's answers" {
    // ADR-0096 evidence item 10. The Vat state rewinds; sessions, positions,
    // and authority do not. A target created after the snapshot vanishes on
    // restore: an answered delivery to its export breaks with the typed
    // missing-actor reason, a fresh answered delivery does the same rather
    // than retargeting, and both sessions keep serving.
    const allocator = std.testing.allocator;
    var server = test_host.init(allocator, [_]u8{0x5a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var alice = test_host.init(allocator, [_]u8{0x5b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer alice.deinit();
    var bob = test_host.init(allocator, [_]u8{0x5c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer bob.deinit();
    const hosts = [_]*Host{ &server, &alice, &bob };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    var stable_freed = false;
    var stable_row = TaggedRow{ .tag = "stable", .freed = &stable_freed };
    _ = try server.publishGiftable("stable", Tagged, .{ .row = &stable_row });

    const a = try openPair(allocator, &alice, &server, "127.0.0.1:7043", &dials);
    const b = try openPair(allocator, &bob, &server, "127.0.0.1:7044", &dials);
    var stable_cap = CapturedRef{};
    try alice.vowOn(try alice.fetch(a.a, "stable"), .{ .ctx = &stable_cap, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);

    var snap = try server.vat.snapshot();
    defer snap.deinit();

    // Spawned after the snapshot and projected on Bob's Port.
    var late_freed = false;
    var late_row = TaggedRow{ .tag = "late", .freed = &late_freed };
    _ = try server.publishGiftable("late", Tagged, .{ .row = &late_row });
    var late_cap = CapturedRef{};
    try bob.vowOn(try bob.fetch(b.a, "late"), .{ .ctx = &late_cap, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    const late_ref = try late_cap.require();

    try server.vat.restore(&snap);

    // An answered delivery to the vanished target breaks its answer with the
    // typed reason; the session stays open.
    var broke = CapturedRef{};
    try bob.vowOn(try bob.send(b.a, late_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &broke, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expect(broke.broken);
    try std.testing.expect(std.mem.indexOf(u8, broke.reason_buf[0..broke.reason_len], "NoSuchActor") != null);
    try std.testing.expect(b.a.sessionOpen() and b.b.sessionOpen());

    // The position never retargets: a second delivery breaks the same way.
    var still_broke = CapturedRef{};
    try bob.vowOn(try bob.send(b.a, late_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &still_broke, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expect(still_broke.broken);

    // Both sessions keep serving: the surviving target answers on Alice's.
    var alive = CapturedString{};
    try alice.vowOn(try alice.send(a.a, try stable_cap.require(), .{ .verb = "tag", .args = &.{} }), .{ .ctx = &alive, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqualStrings("stable", alive.buf[0..alive.len]);
}

test "core host: durable and mutable swiss namespaces are disjoint, and a removed durable name misses across restart" {
    // ADR-0098 evidence item 5. The reserved prefix is the cross-restart
    // invariant: mutable binds refuse it structurally, the durable mint
    // produces only names inside it, removal reclaims the row, and a fresh
    // Host (the restart) simply misses — no tombstone anywhere.
    const allocator = std.testing.allocator;
    var server = test_host.init(allocator, [_]u8{0x6a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var client = test_host.init(allocator, [_]u8{0x6b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    // Structural refusal at every mutable bind: the host-wide alias verb and
    // the session-level bootstrap bind both refuse the reserved prefix.
    var decoy_freed = false;
    var decoy_row = TaggedRow{ .tag = "decoy", .freed = &decoy_freed };
    try std.testing.expectError(
        error.ReservedDurableNamespace,
        server.publishGiftable("pancake-durable-1-not-actually-minted", Tagged, .{ .row = &decoy_row }),
    );
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7071", &dials);
    try std.testing.expectError(
        error.ReservedDurableNamespace,
        pair.b.served.publish(&pair.b.host.vat, "pancake-durable-1-still-not-minted", Tagged, .{ .row = &decoy_row }),
    );

    // Mint a durable name and reach it over the wire like any published name.
    var kept_freed = false;
    var kept_row = TaggedRow{ .tag = "durable", .freed = &kept_freed };
    const minted = try server.publishDurable([_]u8{0xab} ** 16, Tagged, .{ .row = &kept_row });
    try std.testing.expect(pancake.ocapn.session.Session.isDurableSwiss(minted.slice()));
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, minted.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    _ = try fetched.require();

    // The two removal verbs refuse each other's namespace, and a durable
    // name is never reassignable: a second mint from the same entropy fails
    // loud instead of retargeting.
    try std.testing.expectError(error.ReservedDurableNamespace, server.unpublish(minted.slice()));
    try std.testing.expectError(error.NotDurableName, server.removeDurable("plain-alias"));
    var usurper_freed = false;
    var usurper_row = TaggedRow{ .tag = "usurper", .freed = &usurper_freed };
    try std.testing.expectError(
        error.DurableNameCollision,
        server.publishDurable([_]u8{0xab} ** 16, Tagged, .{ .row = &usurper_row }),
    );

    // Removal reclaims the row: a fresh fetch of the old sturdyref misses,
    // and a fresh mint does not reuse the removed bytes.
    try server.removeDurable(minted.slice());
    var missed = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, minted.slice()), .{ .ctx = &missed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(missed.broken);
    const reminted = try server.publishDurable([_]u8{0xcd} ** 16, Tagged, .{ .row = &kept_row });
    try std.testing.expect(!std.mem.eql(u8, reminted.slice(), minted.slice()));

    // The restart: a fresh Host with an empty durable registry. The old
    // sturdyref misses rather than retargets, and a mutable alias still
    // cannot squat the durable bytes.
    var restarted = test_host.init(allocator, [_]u8{0x6a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer restarted.deinit();
    var client2 = test_host.init(allocator, [_]u8{0x6c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client2.deinit();
    try std.testing.expectError(
        error.ReservedDurableNamespace,
        restarted.publishGiftable(minted.slice(), Tagged, .{ .row = &decoy_row }),
    );
    const pair2 = try openPair(allocator, &client2, &restarted, "127.0.0.1:7072", &dials);
    var restart_miss = CapturedRef{};
    try client2.vowOn(try client2.fetch(pair2.a, minted.slice()), .{ .ctx = &restart_miss, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client2, &restarted }, &.{pair2}, &dials);
    try std.testing.expect(restart_miss.broken);
}

const FailedRedeemListener = struct {
    host: *Host,
    session: ?*HostSession = null,
    adopt_exporter: bool,
    adopted: bool = false,
    captured: CapturedRef = .{},

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FailedRedeemListener = @ptrCast(@alignCast(ctx.?));
        CapturedRef.record(&self.captured, resolution);
        if (!self.adopt_exporter or resolution != .broken) return;
        const session = self.session orelse return;
        // `tell` is intentionally callback-safe. It claims application
        // ownership synchronously, while its encode work waits for the host
        // pump's outer unwind.
        self.host.tell(
            session,
            .{ .far = model.FarRef.object(0) },
            .{ .verb = "keep-open", .args = &.{} },
        ) catch return;
        self.adopted = true;
    }
};

fn runMissingGifterRedeem(adopt_in_failure_listener: bool) !void {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7011", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &gifter, &exporter }, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7012", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = try widget.require() });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &gifter, &recipient }, &.{r_to_g}, &dials);

    const introduction = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    var listener = FailedRedeemListener{
        .host = &recipient,
        .adopt_exporter = adopt_in_failure_listener,
    };
    try recipient.vowOn(introduction, .{ .ctx = &listener, .func = FailedRedeemListener.fire });

    // Deliver only the call to the gifter. Its reply cannot leave until the
    // embedder answers the gift-id request, at which point the two handoff legs
    // are independently queued on r_to_g and g_to_e.
    try std.testing.expect(try shuttle(r_to_g));
    const gift_id = [_]u8{0x5a} ** 32;
    var provided = false;
    while (try gifter.nextAction()) |action| switch (action) {
        .flush => {},
        .need_gift_id => |needed| {
            try gifter.provideGiftId(needed.ticket, &gift_id);
            provided = true;
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(provided);

    // Deliver the deposit, but hold back the signed give. The gift belongs to
    // the Exporter-side Peer for this Gifter–Exporter session.
    try std.testing.expect(try shuttle(g_to_e));
    try std.testing.expect(g_to_e.b.served.port.peer.giftRegistry().giftLive(&gift_id));

    const exporter_peer = g_to_e.b.served.port.peer;
    const gifter_key = exporter_peer.session_state.partnerSessionKey().?;
    const exporter_key = exporter_peer.session_state.localSessionKey().?;
    const gifter_side_name = try engine.handoff_names.sideName(gifter_key);
    const exporter_side_name = try engine.handoff_names.sideName(exporter_key);
    const session_name = engine.handoff_names.sessionName(gifter_side_name, exporter_side_name);

    // Closing the required session destroys its Peer-owned registry. The Host
    // directory can no longer resolve either the key or the gift table.
    try exporter.releaseSession(g_to_e.b);
    try gifter.releaseSession(g_to_e.a);
    const resolver = exporter.node.gifterSessionResolver().?;
    try std.testing.expect(resolver.resolve(resolver.ctx, gifter_side_name, &session_name) == null);

    // Now release the held give. The recipient can still connect to the
    // exporter, but redemption fails closed because OCapN requires the original
    // Gifter–Exporter session to remain open.
    try pumpToQuiescence(allocator, &.{ &gifter, &recipient }, &.{r_to_g}, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];
    const accepted = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7011", &.{});
    const pending = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const dialed = try recipient.openDialedLocator(.{
        .transport = pending.transport,
        .designator = pending.designator,
        .hints = model.Hints.emptyFalse(),
    });
    listener.session = dialed;
    const r_to_e = Pair{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &exporter, &gifter, &recipient }, &.{ r_to_g, r_to_e }, &dials);
    try recipient.exporterDialed(parked.ticket, dialed);
    try pumpToQuiescence(allocator, &.{ &exporter, &gifter, &recipient }, &.{ r_to_g, r_to_e }, &dials);

    try std.testing.expect(listener.captured.broken);
    try std.testing.expectEqualStrings(
        "handoff redeem failed: gifter session is not open",
        listener.captured.reason_buf[0..listener.captured.reason_len],
    );
    if (adopt_in_failure_listener) {
        try std.testing.expect(listener.adopted);
        try std.testing.expect(!dialed.condemned);
    } else {
        // The recipient opened r_to_e solely for this redemption. With no
        // capability produced, the Host retires it instead of leaving an
        // application-invisible session cached indefinitely.
        try std.testing.expect(dialed.condemned);
    }
}

test "core host: closing the gifter session destroys its deposited gifts and breaks later withdraw" {
    try runMissingGifterRedeem(false);
}

test "core host: failure-listener activity preserves a redeem-opened exporter" {
    try runMissingGifterRedeem(true);
}

const EarlyWithdrawOutcome = enum { deposit, close };

fn runEarlyWithdrawComposition(outcome: EarlyWithdrawOutcome) !void {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7021", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &gifter, &exporter }, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7022", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = try widget.require() });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &gifter, &recipient }, &.{r_to_g}, &dials);

    const introduction = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduction, .{ .ctx = &redeemed, .func = CapturedRef.record });

    // Let the gifter originate both legs, then deliver only the signed give.
    // The deposit remains queued on g_to_e while the recipient opens its own
    // exporter session and sends the withdrawal first.
    try std.testing.expect(try shuttle(r_to_g));
    const gift_id = [_]u8{0x6b} ** 32;
    var provided = false;
    while (try gifter.nextAction()) |action| switch (action) {
        .flush => {},
        .need_gift_id => |needed| {
            try gifter.provideGiftId(needed.ticket, &gift_id);
            provided = true;
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(provided);
    try pumpToQuiescence(allocator, &.{ &gifter, &recipient }, &.{r_to_g}, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);

    const parked = dials.items[0];
    const accepted = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7021", &.{});
    const pending = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const dialed = try recipient.openDialedLocator(.{
        .transport = pending.transport,
        .designator = pending.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const r_to_e = Pair{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &exporter, &recipient }, &.{r_to_e}, &dials);
    try recipient.exporterDialed(parked.ticket, dialed);
    try pumpToQuiescence(allocator, &.{ &exporter, &recipient }, &.{r_to_e}, &dials);

    try std.testing.expectEqual(@as(usize, 1), exporter.node.handoffWaiterCount(g_to_e.b.peer_id));
    try std.testing.expect(!g_to_e.b.served.port.peer.giftRegistry().giftLive(&gift_id));
    try std.testing.expect(!redeemed.broken);

    switch (outcome) {
        .deposit => {
            // Deliver the already-queued deposit on the distinct gifter Port.
            // Its inbound commit marks the exact Node dependency; the same
            // Host pump wakes the receiver Port, settles the parked withdraw,
            // and exposes the flush that carries the resolution.
            try pumpToQuiescence(
                allocator,
                &.{ &exporter, &gifter, &recipient },
                &.{ g_to_e, r_to_g, r_to_e },
                &dials,
            );
            try std.testing.expect((try redeemed.require()) == .far);
            try std.testing.expectEqual(@as(usize, 0), exporter.node.handoffWaiterCount(g_to_e.b.peer_id));
            try std.testing.expect(!g_to_e.b.served.port.peer.giftRegistry().giftLive(&gift_id));
        },
        .close => {
            // No deposit or unrelated frame follows. Removing the required
            // live Gifter–Exporter session is itself handoff progress:
            // releaseSession's pump re-drives the parked Receiver–Exporter
            // Peer, which re-resolves and breaks.
            try exporter.releaseSession(g_to_e.b);
            try gifter.releaseSession(g_to_e.a);
            try pumpToQuiescence(allocator, &.{ &exporter, &gifter, &recipient }, &.{ r_to_g, r_to_e }, &dials);

            try std.testing.expect(redeemed.broken);
            try std.testing.expectEqualStrings("handoff redeem failed: gifter session is not open", redeemed.reason_buf[0..redeemed.reason_len]);
        },
    }
}

test "core host: a distinct gifter deposit wakes and settles an early withdraw" {
    try runEarlyWithdrawComposition(.deposit);
}

test "core host: closing the gifter session wakes and breaks an early withdraw" {
    try runEarlyWithdrawComposition(.close);
}

test "core host: a redeem reuses a live exporter session instead of dialing a duplicate" {
    // Regression (ADR-0012): when the recipient already holds a live open
    // session to the exporter, redeeming a give that names that exporter must
    // REUSE the session, not surface a dial the Host's session-pair uniqueness
    // rule would then refuse and break the redeem on. The node's URI-keyed
    // exporter cache misses the pre-existing session; the Host's dial index is
    // the authority, consulted at the node-action seam before any dial is
    // surfaced.
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    // Gifter dials the exporter and fetches the widget (the give's future home).
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();

    // Recipient dials the gifter and fetches the introducer.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    // The trigger: the recipient already holds a live open session to the
    // exporter at the very designator the give will name. This lower-level
    // fixture projects the same actor on that Port before withdrawal.
    const r_to_e = try openPair(allocator, &recipient, &exporter, "127.0.0.1:7001", &dials);
    _ = try r_to_e.b.served.publish(&r_to_e.b.host.vat, "widget", Widget, .{});
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);

    const all_pairs = [_]Pair{ g_to_e, r_to_g, r_to_e };

    // Introduce: the give is minted and claimed, and because a live session to
    // the exporter already exists it redeems in place — no dial is surfaced.
    const introduce_vow = try recipient.send(r_to_g.a, introducer_ref, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // With the bug the redeem parks a dial that refuses `SessionPairExists` and
    // the vow never settles; the fix reuses the session, so zero dials surface.
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
    const token_ref = try redeemed.require();
    try std.testing.expect(token_ref == .far);

    // Crossing the new Host boundary consumes the redeemed Node token: one
    // stale-capable route becomes one import-incarnation-checked Host handle.
    const token = token_ref.far.import_position.int();
    const host_ref = try recipient.liftCapability(r_to_g.a, token_ref);
    try std.testing.expect(recipient.node.routeToken(token) == null);
    const lowered = try recipient.lowerCapability(r_to_e.a, host_ref);

    // The Host handle lowers through the reused exporter session to the widget.
    const poke_vow = try recipient.send(r_to_e.a, lowered, .{ .verb = "poke", .args = &.{} });
    var poked = CapturedString{};
    try recipient.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
}

/// True when `result` is exactly the reentry refusal — any success or other
/// error is a legality-classification bug.
fn refusedReentered(result: anytype) bool {
    if (result) |_| return false else |err| return err == driver.core.HostError.ReenteredHost;
}

/// A settle listener that probes the host from inside the callback window:
/// every top-level verb must refuse `ReenteredHost`, and every enqueueing
/// verb must succeed, its effects landing when the enclosing verb unwinds.
const ReentryProbe = struct {
    host: *Host,
    session: *HostSession,
    token: model.Reference,
    ran: bool = false,
    all_refused: bool = false,
    enqueued_ok: bool = false,
    nested_reply: CapturedString = .{},
    nested_listen: CapturedRef = .{},

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        _ = resolution;
        const self: *ReentryProbe = @ptrCast(@alignCast(ctx.?));
        self.ran = true;
        const host = self.host;
        const session = self.session;
        self.all_refused =
            refusedReentered(host.feed(session, .{ .bytes = "", .shape = .byte })) and
            refusedReentered(host.feedBytes(session, "x")) and
            refusedReentered(host.nextAction()) and
            refusedReentered(host.takeAction()) and
            refusedReentered(session.takeOutbound()) and
            refusedReentered(host.openDialedLocator(tcpLocator("127.0.0.1:7009"))) and
            refusedReentered(publishAndOpenAccepted(host, "tcp", "127.0.0.1:7009", &.{})) and
            refusedReentered(host.releaseSession(session)) and
            refusedReentered(host.exporterDialed(0, session)) and
            refusedReentered(host.dialFailed(0, "no")) and
            refusedReentered(host.provideGiftId(0, "")) and
            refusedReentered(host.breakFarVows(session, "no")) and
            refusedReentered(host.fetch(session, "widget")) and
            refusedReentered(host.enliven(session, tcpSturdyref("127.0.0.1:7001", "widget")));
        const vow = host.send(session, self.token, .{ .verb = "poke", .args = &.{} }) catch return;
        host.vowOn(vow, .{ .ctx = &self.nested_reply, .func = CapturedString.record }) catch return;
        host.tell(session, self.token, .{ .verb = "poke", .args = &.{} }) catch return;
        // A settle callback is where you learn a promise, so `listenTo` is
        // enqueueing, not top-level (ADR-0095).
        const listen_vow = host.listenTo(session, self.token) catch return;
        host.vowOn(listen_vow, .{ .ctx = &self.nested_listen, .func = CapturedRef.record }) catch return;
        host.setExporterLocation(session, null) catch return;
        self.enqueued_ok = true;
    }
};

test "core host: inside a callback every top-level verb refuses and every enqueueing verb lands at the unwind" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x2a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x2b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();

    // The probe fires inside the feed that settles this vow.
    var probe = ReentryProbe{ .host = &client, .session = pair.a, .token = widget_ref };
    const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    try client.vowOn(vow, .{ .ctx = &probe, .func = ReentryProbe.fire });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    try std.testing.expect(probe.ran);
    try std.testing.expect(probe.all_refused);
    try std.testing.expect(probe.enqueued_ok);
    // The nested send encoded at the unwind and settled through the pump.
    try std.testing.expectEqualStrings("poked over fed bytes", probe.nested_reply.buf[0..probe.nested_reply.len]);
    // So did the nested listen: the partner answered its `op:listen`.
    _ = try probe.nested_listen.require();
}

test "core host: a crossed-hellos loser refuses every verb condemned; release still works" {
    const allocator = std.testing.allocator;
    var a = test_host.init(allocator, [_]u8{0x3a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer a.deinit();
    var b = test_host.init(allocator, [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer b.deinit();

    // Both sides dial the same partner designator: a's outbound dial is
    // registered when b's hello (signing that same designator as its own
    // dialable address) arrives on a's accepted connection, so the tiebreak
    // condemns exactly one of a's two connections.
    const designator = "127.0.0.1:7001";
    try a.ensureAdvertisedLocator("tcp");
    try b.setAdvertisedLocator(tcpLocator(designator));
    const a_dialed = try a.openDialedLocator(tcpLocator(designator));
    const a_accepted = try publishAndOpenAccepted(&a, "tcp", "127.0.0.1:7002", &.{});
    const b_dialed = try b.openDialedLocator(tcpLocator("127.0.0.1:7002"));

    var hello = (try b_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try a.feed(a_accepted, hello.view());
    const condemned = if (a_accepted.condemned) a_accepted else a_dialed;
    try std.testing.expect(condemned.condemned);

    // Every verb that rides the condemned connection refuses, uniformly.
    const target = model.Reference{ .far = model.FarRef.object(1) };
    const condemned_err = driver.core.HostError.SessionCondemned;
    try std.testing.expectError(condemned_err, a.feed(condemned, .{ .bytes = "", .shape = .byte }));
    try std.testing.expectError(condemned_err, a.feedBytes(condemned, "x"));
    try std.testing.expectError(condemned_err, a.send(condemned, target, .{ .verb = "poke", .args = &.{} }));
    try std.testing.expectError(condemned_err, a.tell(condemned, target, .{ .verb = "poke", .args = &.{} }));
    try std.testing.expectError(condemned_err, a.fetch(condemned, "widget"));
    try std.testing.expectError(condemned_err, a.enliven(condemned, tcpSturdyref(designator, "widget")));
    try std.testing.expectError(condemned_err, a.exporterDialed(0, condemned));
    try std.testing.expectError(condemned_err, a.breakFarVows(condemned, "gone"));
    try std.testing.expectError(condemned_err, a.setExporterLocation(condemned, null));

    // The queued typed abort still drains — the embedder writes it before
    // closing — and the release path stays ungated.
    var abort_frame = (try condemned.takeOutbound()) orelse return error.MissingAbort;
    abort_frame.deinit();
    try a.releaseSession(condemned);
}

test "core host: a second dial to the same partner refuses SessionPairExists" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x3c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const designator = "127.0.0.1:7011";
    try host.ensureAdvertisedLocator("tcp");
    const first = try host.openDialedLocator(tcpLocator(designator));
    try std.testing.expectError(driver.core.HostError.SessionPairExists, host.openDialedLocator(tcpLocator(designator)));

    // Crossed hellos may still open an accepted session beside the dial.
    _ = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7012", &.{});

    // After release, a fresh dial to the same partner is admitted again.
    try host.releaseSession(first);
    const again = try host.openDialedLocator(tcpLocator(designator));
    try host.releaseSession(again);
}

test "core host: equal designators on different transports remain distinct dials" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x5c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    _ = try host.defineTransport(.{ .symbol = "test-alt", .designator_scheme = .address });

    const designator = "shared-endpoint";
    try host.ensureAdvertisedLocator("tcp");
    try host.ensureAdvertisedLocator("test-alt");
    const tcp = try host.openDialedLocator(.{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    const alternate = try host.openDialedLocator(.{
        .transport = "test-alt",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });

    try std.testing.expectEqual(tcp, host.dialedSessionFor("tcp", designator).?);
    try std.testing.expectEqual(alternate, host.dialedSessionFor("test-alt", designator).?);
    try host.releaseSession(tcp);
    try host.releaseSession(alternate);
}

test "core host: accepted tcp session's declared designator does not squat dial availability" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x3d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x3e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    try client.setAdvertisedLocator(tcpLocator("127.0.0.1:7013"));
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7014", &dials);
    // Server learned the client's self-declared tcp designator; that claim is
    // not verified ownership of the address, so a dial to it is admitted.
    // Post-handshake partner-key refuse settles the duplicate when the new
    // session's start-session arrives (ADR-0012).
    const back = try server.openDialedLocator(tcpLocator("127.0.0.1:7013"));
    try std.testing.expect(!back.condemned);
    try client.releaseSession(pair.a);
    try server.releaseSession(pair.b);
    try server.releaseSession(back);
}

test "core host: keyed dial to a verified partner session key refuses SessionPairExists" {
    const allocator = std.testing.allocator;

    const partner_seed = [_]u8{0x51} ** 32;
    const partner_key = crypto.SecretKey.fromSeed(partner_seed).publicKey();
    const designator = partner_key.toDesignator();
    var uri_buf: [96]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "ocapn://{s}.iroh", .{designator[0..]});

    var dialer = test_host.init(allocator, [_]u8{0x52} ** 32, Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    var acceptor = test_host.init(allocator, partner_seed, Host.Options.withFrameCap(frame_cap));
    defer acceptor.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const accepted = try publishAndOpenAccepted(&acceptor, "iroh", designator[0..], &.{});
    try dialer.ensureAdvertisedLocator("iroh");
    const loc = try model.uri.parsePeer(allocator, uri);
    defer model.freePeerLocator(allocator, loc);
    const first = try dialer.openDialedLocator(loc);
    const pair = Pair{ .ah = &dialer, .a = first, .bh = &acceptor, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &dialer, &acceptor }, &.{pair}, &dials);
    try std.testing.expect(first.sessionOpen());

    // Same key designator while the verified session is live: dial-time refuse.
    const loc_again = try model.uri.parsePeer(allocator, uri);
    defer model.freePeerLocator(allocator, loc_again);
    try std.testing.expectError(
        driver.core.HostError.SessionPairExists,
        dialer.openDialedLocator(loc_again),
    );
    try dialer.releaseSession(first);
    try acceptor.releaseSession(accepted);
}

test "core host: dual accept settlement condemns the second session to the same partner key" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x3f} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = test_host.init(allocator, [_]u8{0x40} ** 32, Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();

    const first = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7015", &.{});
    const second = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7016", &.{});
    // One peer hello fed to both accepted sessions: the first keeps the
    // partner key; the second is condemned at start-session (ADR-0012).
    try peer.ensureAdvertisedLocator("tcp");
    const peer_dialed = try peer.openDialedLocator(tcpLocator("127.0.0.1:7015"));
    var hello = (try peer_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try host.feed(first, hello.view());
    try std.testing.expect(!first.condemned);
    try std.testing.expect(first.sessionOpen());
    try host.feed(second, hello.view());
    try std.testing.expect(second.condemned);
    try std.testing.expect(!second.sessionOpen());
    try host.releaseSession(first);
    try host.releaseSession(second);
    try peer.releaseSession(peer_dialed);
}

test "core host: partner-side index empties after enroll, learn, condemn, and release" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x53} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = test_host.init(allocator, [_]u8{0x54} ** 32, Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();

    const first = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7020", &.{});
    const second = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7021", &.{});
    try peer.ensureAdvertisedLocator("tcp");
    const peer_dialed = try peer.openDialedLocator(tcpLocator("127.0.0.1:7020"));
    var hello = (try peer_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try host.feed(first, hello.view());
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_side.count());
    try host.feed(second, hello.view());
    try std.testing.expect(second.condemned);
    try host.releaseSession(second);
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_side.count());
    try host.releaseSession(first);
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), host.dialed_by_target.count());
    try peer.releaseSession(peer_dialed);
}

test "core host: a burst of accepts before any start-session indexes every partner side without overflow" {
    // Regression (ADR-0012): `partner_by_side` reserves at its own insert
    // (`indexPartnerKey`), not at mint. A partner key is unknown until that
    // partner's `op:start-session` arrives, so every session minted before a
    // single start-session is fed stays un-indexed — a mint-time reservation
    // would never grow the map across those mints and would overflow
    // `putAssumeCapacity` once the burst passed the map's usable capacity.
    const allocator = std.testing.allocator;
    const n = 8; // past AutoHashMap's minimal usable capacity, the old overflow point
    var host = test_host.init(allocator, [_]u8{0x60} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var peers: [n]Host = undefined;
    var peers_inited: usize = 0;
    defer for (peers[0..peers_inited]) |*p| p.deinit();

    var accepted: [n]*HostSession = undefined;
    var dialed: [n]*HostSession = undefined;

    // Mint every accepted session (and its dialing partner) first: the whole
    // burst is un-indexed before one start-session is fed.
    for (0..n) |i| {
        peers[i] = test_host.init(allocator, [_]u8{@as(u8, @intCast(0x61 + i))} ** 32, Host.Options.withFrameCap(frame_cap));
        peers_inited += 1;
        var buf: [24]u8 = undefined;
        const designator = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{7100 + i});
        accepted[i] = try publishAndOpenAccepted(&host, "tcp", designator, &.{});
        try peers[i].ensureAdvertisedLocator("tcp");
        dialed[i] = try peers[i].openDialedLocator(tcpLocator(designator));
    }
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());

    // Feed each partner's hello: each learns a distinct partner key and indexes
    // a fresh row. Under the mint-reservation bug the 7th insert overflowed the
    // 6 usable slots the single effective reservation had pinned.
    for (0..n) |i| {
        var hello = (try dialed[i].takeOutbound()) orelse return error.MissingHello;
        defer hello.deinit();
        try host.feed(accepted[i], hello.view());
        try std.testing.expect(accepted[i].sessionOpen());
        try std.testing.expect(!accepted[i].condemned);
    }
    try std.testing.expectEqual(@as(usize, n), host.partner_by_side.count());

    for (0..n) |i| {
        try host.releaseSession(accepted[i]);
        try peers[i].releaseSession(dialed[i]);
    }
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());
}

test "session identity: crossed-hello ordering is per session over one advertised snapshot" {
    // ADR-0097 evidence item 9. The tiebreak is two operations over two
    // different identities, and fresh session keys are what force them apart:
    //
    //   * matching asks *which two attempts are racing*, and that is a
    //     question about the durable peer — both attempts name the same one;
    //   * ordering asks *which one survives*, and that is a question about
    //     session identity — the two sessions' own keys.
    //
    // While every session reused its host's durable key one value answered
    // both, so the split was invisible and a wrong reading still worked. Here
    // each host draws per-session keys, so the durable identities are equal on
    // both racing attempts and cannot order anything; only the session ids
    // can. Both ends must still converge on the same survivor.
    const allocator = std.testing.allocator;
    const a_opts = Host.Options.withFrameCap(frame_cap);
    const b_opts = Host.Options.withFrameCap(frame_cap);
    var a = test_host.init(allocator, [_]u8{0x01} ** 32, a_opts);
    defer a.deinit();
    var b = test_host.init(allocator, [_]u8{0xff} ** 32, b_opts);
    defer b.deinit();

    // Each side accepts on the address the other dials, so both crossed-hellos
    // tables match by durable peer and each end runs the tiebreak itself.
    const a_accept = try publishAndOpenAccepted(&a, "tcp", "127.0.0.1:9100", &.{});
    const b_accept = try publishAndOpenAccepted(&b, "tcp", "127.0.0.1:9101", &.{});
    const a_dialed = try a.openDialedLocator(tcpLocator("127.0.0.1:9101"));
    const b_dialed = try b.openDialedLocator(tcpLocator("127.0.0.1:9100"));

    // The teeth: no session's signing key is its host's durable key, so a
    // tiebreak reading durable keys would be comparing values this race never
    // uses — and, being equal across both of a host's sessions, could not
    // order them anyway. These assertions fail under key reuse.
    const a_durable = crypto.derivePublicIdentifier(a.node.secretKey().publicKey());
    const b_durable = crypto.derivePublicIdentifier(b.node.secretKey().publicKey());
    const a_dial_id = crypto.derivePublicIdentifier(a_dialed.sessionSecret().publicKey());
    const b_dial_id = crypto.derivePublicIdentifier(b_dialed.sessionSecret().publicKey());
    try std.testing.expect(!std.mem.eql(u8, &a_dial_id.bytes, &a_durable.bytes));
    try std.testing.expect(!std.mem.eql(u8, &b_dial_id.bytes, &b_durable.bytes));
    // And a host's own two connections differ from each other, which is what
    // makes "which session" a real question rather than a restatement of
    // "which host".
    const a_accept_id = crypto.derivePublicIdentifier(a_accept.sessionSecret().publicKey());
    try std.testing.expect(!std.mem.eql(u8, &a_dial_id.bytes, &a_accept_id.bytes));

    var a_hello = (try a_dialed.takeOutbound()) orelse return error.MissingAHello;
    defer a_hello.deinit();
    var b_hello = (try b_dialed.takeOutbound()) orelse return error.MissingBHello;
    defer b_hello.deinit();
    var a_accept_hello = (try a_accept.takeOutbound()) orelse return error.MissingAAcceptHello;
    defer a_accept_hello.deinit();
    var b_accept_hello = (try b_accept.takeOutbound()) orelse return error.MissingBAcceptHello;
    defer b_accept_hello.deinit();

    // Each dialed hello lands on the peer's accepted session. Because dial and
    // accept now advertise the same Node snapshot, both crossed-hello tables
    // match and independently condemn the same physical connection. Only a
    // surviving dialed half may consume its partner's accepted hello.
    try b.feed(b_accept, a_hello.view());
    try a.feed(a_accept, b_hello.view());
    if (!b_dialed.condemned) try b.feed(b_dialed, a_accept_hello.view());
    if (!a_dialed.condemned) try a.feed(a_dialed, b_accept_hello.view());

    try std.testing.expect(a_accept.condemned != a_dialed.condemned);
    try std.testing.expect(b_accept.condemned != b_dialed.condemned);
    try std.testing.expectEqual(a_accept.condemned, b_dialed.condemned);
    try std.testing.expectEqual(a_dialed.condemned, b_accept.condemned);

    try a.releaseSession(a_accept);
    try a.releaseSession(a_dialed);
    try b.releaseSession(b_accept);
    try b.releaseSession(b_dialed);
}

test "core host: crossed hellos match the advertised route across different channel transports" {
    const allocator = std.testing.allocator;
    const a_opts = Host.Options.withFrameCap(frame_cap);
    const b_opts = Host.Options.withFrameCap(frame_cap);
    var a = test_host.init(allocator, [_]u8{0x11} ** 32, a_opts);
    defer a.deinit();
    var b = test_host.init(allocator, [_]u8{0xee} ** 32, b_opts);
    defer b.deinit();
    _ = try a.defineTransport(.{ .symbol = "test-alt", .designator_scheme = .address });
    _ = try b.defineTransport(.{ .symbol = "test-alt", .designator_scheme = .address });

    const a_locator: model.PeerLocator = .{
        .transport = "test-alt",
        .designator = "a-alt",
        .hints = model.Hints.emptyFalse(),
    };
    const b_locator = tcpLocator("127.0.0.1:9111");
    try a.setAdvertisedLocator(a_locator);
    try b.setAdvertisedLocator(b_locator);

    // A reaches B over TCP while B reaches A over test-alt. Each inbound
    // channel therefore differs from the transport in the partner's hello.
    const a_dialed = try a.openDialedLocator(b_locator);
    const b_accept = try b.openAcceptedAdvertised("tcp");
    const b_dialed = try b.openDialedLocator(a_locator);
    const a_accept = try a.openAcceptedAdvertised("test-alt");

    var a_hello = (try a_dialed.takeOutbound()) orelse return error.MissingAHello;
    defer a_hello.deinit();
    var b_hello = (try b_dialed.takeOutbound()) orelse return error.MissingBHello;
    defer b_hello.deinit();
    var a_accept_hello = (try a_accept.takeOutbound()) orelse return error.MissingAAcceptHello;
    defer a_accept_hello.deinit();
    var b_accept_hello = (try b_accept.takeOutbound()) orelse return error.MissingBAcceptHello;
    defer b_accept_hello.deinit();

    try a.feed(a_accept, b_hello.view());
    try b.feed(b_accept, a_hello.view());
    if (!a_dialed.condemned) try a.feed(a_dialed, b_accept_hello.view());
    if (!b_dialed.condemned) try b.feed(b_dialed, a_accept_hello.view());

    try std.testing.expect(a_accept.condemned != a_dialed.condemned);
    try std.testing.expect(b_accept.condemned != b_dialed.condemned);
    try std.testing.expectEqual(a_accept.condemned, b_dialed.condemned);
    try std.testing.expectEqual(a_dialed.condemned, b_accept.condemned);

    try a.releaseSession(a_accept);
    try a.releaseSession(a_dialed);
    try b.releaseSession(b_accept);
    try b.releaseSession(b_dialed);
}

const CrossedPairProof = enum { none, authenticated_channel };

/// Exercise the same fresh-key crossed pair with and without realizer proof.
/// Four distinct session keys make the durable-peer directory the only possible
/// cross-connection match; a bare key designator cannot populate it, while a
/// channel-authenticated durable key can.
fn expectFreshKeyCrossedPair(transport: []const u8, proof: CrossedPairProof) !void {
    const allocator = std.testing.allocator;
    const a_seed = [_]u8{0x01} ** 32;
    const b_seed = [_]u8{0xff} ** 32;
    const a_opts = Host.Options.withFrameCap(frame_cap);
    const b_opts = Host.Options.withFrameCap(frame_cap);
    var a = test_host.init(allocator, a_seed, a_opts);
    defer a.deinit();
    var b = test_host.init(allocator, b_seed, b_opts);
    defer b.deinit();

    const a_designator = crypto.SecretKey.fromSeed(a_seed).publicKey().toDesignator();
    const b_designator = crypto.SecretKey.fromSeed(b_seed).publicKey().toDesignator();

    const a_direct: []const u8 = if (std.mem.eql(u8, transport, "keyed-tcp")) "127.0.0.1:9200" else &.{};
    const b_direct: []const u8 = if (std.mem.eql(u8, transport, "keyed-tcp")) "127.0.0.1:9201" else &.{};
    const a_accept = try publishAndOpenAccepted(&a, transport, a_designator[0..], a_direct);
    const b_accept = try publishAndOpenAccepted(&b, transport, b_designator[0..], b_direct);
    const a_dialed = try a.openDialedLocator(.{
        .transport = transport,
        .designator = b_designator[0..],
        .hints = model.Hints.emptyFalse(),
    });
    const b_dialed = try b.openDialedLocator(.{
        .transport = transport,
        .designator = a_designator[0..],
        .hints = model.Hints.emptyFalse(),
    });

    if (proof == .authenticated_channel) {
        try a.bindVerifiedChannelKey(a_accept, &b_designator);
        try a.bindVerifiedChannelKey(a_dialed, &b_designator);
        try b.bindVerifiedChannelKey(b_accept, &a_designator);
        try b.bindVerifiedChannelKey(b_dialed, &a_designator);
    }

    const ids = [_][32]u8{
        crypto.derivePublicIdentifier(a_accept.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(a_dialed.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(b_accept.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(b_dialed.sessionSecret().publicKey()).bytes,
    };
    for (ids, 0..) |left, i| {
        for (ids[i + 1 ..]) |right| try std.testing.expect(!std.mem.eql(u8, &left, &right));
    }

    var a_hello = (try a_dialed.takeOutbound()) orelse return error.MissingAHello;
    defer a_hello.deinit();
    var b_hello = (try b_dialed.takeOutbound()) orelse return error.MissingBHello;
    defer b_hello.deinit();
    var a_accept_hello = (try a_accept.takeOutbound()) orelse return error.MissingAAcceptHello;
    defer a_accept_hello.deinit();
    var b_accept_hello = (try b_accept.takeOutbound()) orelse return error.MissingBAcceptHello;
    defer b_accept_hello.deinit();

    try b.feed(b_accept, a_hello.view());
    try a.feed(a_accept, b_hello.view());
    try b.feed(b_dialed, a_accept_hello.view());
    try a.feed(a_dialed, b_accept_hello.view());

    switch (proof) {
        .none => {
            try std.testing.expect(!a_accept.condemned and !a_dialed.condemned);
            try std.testing.expect(!b_accept.condemned and !b_dialed.condemned);
        },
        .authenticated_channel => {
            try std.testing.expect(a_accept.condemned != a_dialed.condemned);
            try std.testing.expect(b_accept.condemned != b_dialed.condemned);
            try std.testing.expectEqual(a_accept.condemned, b_dialed.condemned);
            try std.testing.expectEqual(a_dialed.condemned, b_accept.condemned);
        },
    }

    try a.releaseSession(a_accept);
    try a.releaseSession(a_dialed);
    try b.releaseSession(b_accept);
    try b.releaseSession(b_dialed);
}

test "session identity: raw keyed transport cannot collapse crossed locator claims" {
    try expectFreshKeyCrossedPair("keyed-tcp", .none);
}

test "session identity: authenticated channel collapses a crossed pair to one shared survivor" {
    try expectFreshKeyCrossedPair("iroh", .authenticated_channel);
}

test "durable publication: a sturdyref issued before a restart still names a live object after it" {
    // What "durable bootstrap" actually requires of the library, and where the
    // storage belongs. The core is sync and no-I/O, so it cannot own a file;
    // what it owes instead is that a durable name be *reproducible*, and
    // `mintDurableSwiss` is a pure function of the caller's 16 entropy bytes.
    // An embedder that keeps those bytes therefore rebuilds the identical
    // sturdyref after a restart, and re-binds it to a freshly spawned actor.
    // The persistence is the embedder's, which is the only place it can be.
    const allocator = std.testing.allocator;
    const seed = [_]u8{0x7d} ** 32;
    const entropy = [_]u8{0x5e} ** engine.durable_swiss_entropy_len;

    // Before the restart: publish, and keep the sturdyref a caller was handed.
    var issued: [engine.durable_swiss_len]u8 = undefined;
    {
        var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
        defer host.deinit();
        const swiss = try host.publishDurable(entropy, Widget, .{});
        issued = swiss.bytes;
    }

    // The restart: a new process, the same durable identity, the same stored
    // entropy, a new actor behind the name.
    var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const rebound = try host.publishDurable(entropy, Widget, .{});

    // The name a caller is still holding resolves to the rebound object.
    try std.testing.expectEqualSlices(u8, &issued, &rebound.bytes);

    // And it is a live publication on this host, not merely an equal string:
    // a partner session fetching that swiss reaches the actor.
    var client = test_host.init(allocator, [_]u8{0x7e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7331", &dials);
    var captured = CapturedRef{};
    const vow = try client.fetch(pair.a, &issued);
    try client.vowOn(vow, .{ .ctx = &captured, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &host }, &.{pair}, &dials);
    _ = try captured.require();
}

test "core host: vow rows retire on settle; the map stays empty and release frees the rest" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x4a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x4b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());

    // Settlement retires each row, listener or not: the map never grows with
    // completed calls.
    for (0..4) |i| {
        const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
        var reply = CapturedString{};
        if (i % 2 == 0) try client.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        if (i % 2 == 0) try std.testing.expectEqualStrings("poked over fed bytes", reply.buf[0..reply.len]);
    }
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());

    // One listener per vow, and a settled id is simply gone.
    const observed = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    var first = CapturedString{};
    var second = CapturedString{};
    try client.vowOn(observed, .{ .ctx = &first, .func = CapturedString.record });
    try std.testing.expectError(actors.Error.AlreadyListening, client.vowOn(observed, .{ .ctx = &second, .func = CapturedString.record }));
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectError(driver.core.HostError.NoSuchVow, client.vowOn(observed, .{ .ctx = &second, .func = CapturedString.record }));
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());

    // A vow whose resolve never arrives is freed at release: the connection
    // break fires it broken through the retire chain.
    const parked = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    var broken = CapturedRef{};
    try client.vowOn(parked, .{ .ctx = &broken, .func = CapturedRef.record });
    try client.releaseSession(pair.a);
    try std.testing.expect(broken.broken);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
}

test "core host: a failed dial breaks the redeeming vow with the reason" {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget.ref.? });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    const introduce_vow = try recipient.send(r_to_g.a, introducer.ref.?, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);

    // The exporter is unreachable: the dial's failure breaks the vow.
    try recipient.dialFailed(dials.items[0].ticket, "exporter unreachable");
    try std.testing.expect(redeemed.broken);
    try std.testing.expect(redeemed.ref == null);
}

/// Open a pair, publish the widget, and fetch it with an in-process listener —
/// the shared preamble of the queue-drain scenarios below.
fn openWidgetPair(
    allocator: std.mem.Allocator,
    client: *Host,
    server: *Host,
    dials: *std.ArrayList(ParkedDial),
) !struct { pair: Pair, widget: model.Reference } {
    const pair = try openPair(allocator, client, server, "127.0.0.1:7001", dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ client, server }, &.{pair}, dials);
    return .{ .pair = pair, .widget = try fetched.require() };
}

test "core host: an unlistened settle rides the action queue owned, valid until the next nextAction frees it" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x5a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x5b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const opened = try openWidgetPair(allocator, &client, &server, &dials);

    // No listener anywhere: the settle must surface as a queued completion.
    const vow = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    _ = try shuttleAll(&.{opened.pair}); // the deliver reaches the server
    _ = try shuttleAll(&.{opened.pair}); // the resolve settles the vow

    // Drain by hand: the popped completion's deep-cloned value stays valid
    // across this whole iteration — the next `nextAction` call frees it —
    // and the row is already retired.
    var settle_count: usize = 0;
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .settled => |s| {
                try std.testing.expectEqual(vow, s.vow_id);
                try std.testing.expect(s.value == .string);
                try std.testing.expectEqualStrings("poked over fed bytes", s.value.string);
                settle_count += 1;
            },
            else => return error.UnexpectedAction,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), settle_count);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    try std.testing.expectError(driver.core.HostError.NoSuchVow, client.vowOn(vow, .{ .ctx = null, .func = CapturedString.record }));

    // An unlistened break rides the queue too: the reply can never arrive
    // once the far vows break, and the completion carries the reason owned.
    const parked = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    try client.breakFarVows(opened.pair.a, "transport gone");
    var fail_count: usize = 0;
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .failed => |f| {
                try std.testing.expectEqual(parked, f.vow_id);
                try std.testing.expect(std.mem.indexOf(u8, f.message, "transport gone") != null);
                fail_count += 1;
            },
            else => return error.UnexpectedAction,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fail_count);
}

test "core host: an unlistened fetch completion carries the node-enrolled token" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x6a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x6b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    // No listener: the enrollment mapping still runs before the completion is
    // queued, so the drained value is the routable token, never a raw import.
    const fetch_vow = try client.fetch(pair.a, "widget");
    _ = try shuttleAll(&.{pair});
    _ = try shuttleAll(&.{pair});
    var token: ?model.Reference = null;
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .settled => |s| {
                try std.testing.expectEqual(fetch_vow, s.vow_id);
                try std.testing.expect(s.value == .reference);
                token = s.value.reference;
            },
            else => return error.UnexpectedAction,
        }
    }
    const reference = token orelse return error.FetchDidNotSettle;
    try std.testing.expect(reference == .far);
    try std.testing.expect(reference.far.import_position.int() >= pancake.ocapn.engine.Node.REDEEMED_TOKEN_BASE);
}

test "core host: a burst of unlistened settles never strands — every completion lands on the reserved queue" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x7a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x7b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const opened = try openWidgetPair(allocator, &client, &server, &dials);

    // Queue the whole burst before a single reply frame moves, so every
    // settle fires inside one feed window against a queue already carrying
    // that feed's flush actions.
    const burst = 8;
    var vows: [burst]u64 = undefined;
    for (&vows) |*slot| {
        slot.* = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    }
    _ = try shuttleAll(&.{opened.pair});
    _ = try shuttleAll(&.{opened.pair});

    var seen = [_]bool{false} ** burst;
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .settled => |s| {
                for (vows, 0..) |id, i| {
                    if (id == s.vow_id) {
                        try std.testing.expect(!seen[i]);
                        seen[i] = true;
                    }
                }
                try std.testing.expectEqualStrings("poked over fed bytes", s.value.string);
            },
            else => return error.UnexpectedAction,
        }
    }
    for (seen) |hit| try std.testing.expect(hit);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
}

test "core host: a settle under OOM never strands a vow and never trips the reserved completion queue" {
    // Sweep a failing allocator across every allocation index of the settle
    // window: the setup (handshake, publish, fetch, the burst of sends) runs
    // unarmed, then the reply frames are fed with the allocator armed to
    // fail at `offset` and every allocation after it. For every offset the
    // invariant is the same: no `appendAssumeCapacity` panic (the completion
    // queue is reserved at mint) and every minted vow stays accounted — its
    // completion drained, or its row still live because the feed failed
    // before the resolve applied. A silently vanished vow is a strand.
    var offset: usize = 0;
    while (true) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var saw_oom = false;
        {
            var client = test_host.init(allocator, [_]u8{0x9a} ** 32, Host.Options.withFrameCap(frame_cap));
            defer client.deinit();
            var server = test_host.init(allocator, [_]u8{0x9b} ** 32, Host.Options.withFrameCap(frame_cap));
            defer server.deinit();
            var dials: std.ArrayList(ParkedDial) = .empty;
            defer dials.deinit(std.testing.allocator);
            const opened = try openWidgetPair(std.testing.allocator, &client, &server, &dials);

            const burst = 4;
            var vows: [burst]u64 = undefined;
            for (&vows) |*slot| {
                slot.* = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
            }

            // Arm: the next `offset` allocations succeed, everything after
            // fails — the replies are fed (and the settles fire) inside this
            // window.
            failing.fail_index = failing.alloc_index + offset;
            var failed_run = false;
            _ = shuttleAll(&.{opened.pair}) catch {
                failed_run = true;
            };
            if (!failed_run) _ = shuttleAll(&.{opened.pair}) catch {
                failed_run = true;
            };
            // A run may only fail because the sweep induced it.
            if (failed_run) try std.testing.expect(failing.has_induced_failure);
            saw_oom = failing.has_induced_failure;

            // Disarm and account for every vow: a drained completion or a
            // still-live row, never neither.
            failing.fail_index = std.math.maxInt(usize);
            var seen = [_]bool{false} ** burst;
            while (try client.nextAction()) |action| {
                switch (action) {
                    .settled => |s| for (vows, 0..) |id, i| {
                        if (id == s.vow_id) seen[i] = true;
                    },
                    .failed => |f| for (vows, 0..) |id, i| {
                        if (id == f.vow_id) seen[i] = true;
                    },
                    else => {},
                }
            }
            for (vows, seen) |id, hit| {
                if (!hit) try std.testing.expect(client.vows.contains(id));
            }
        }
        if (!saw_oom) break;
        // The window is a bounded handful of allocations; a sweep that never
        // completes means something regressed into an allocation storm.
        try std.testing.expect(offset < 512);
    }
}

test "core host: fetch allocation failures are pre-commit and a committed vow id is never lost" {
    var offset: usize = 0;
    var saw_precommit_oom = false;
    while (true) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var client = test_host.init(allocator, [_]u8{0xa8} ** 32, Host.Options.withFrameCap(frame_cap));
        defer client.deinit();
        var server = test_host.init(std.testing.allocator, [_]u8{0xa9} ** 32, Host.Options.withFrameCap(frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(std.testing.allocator);
        const pair = try openPair(std.testing.allocator, &client, &server, "127.0.0.1:7106", &dials);

        try std.testing.expectEqual(@as(usize, 0), pair.a.served.queuedOutboundBytes());
        const held_bootstrap_before = pair.a.served.port.peer.session_state.holdsImport(.from(engine.BOOTSTRAP_POSITION));
        failing.fail_index = failing.alloc_index + offset;

        const result = client.fetch(pair.a, "allocation-transaction");
        if (result) |vow_id| {
            // An allocation may have failed while the post-commit encode pump
            // ran. The operation still succeeds with its live id; callers must
            // never be invited to replay a committed fetch.
            try std.testing.expect(client.vows.contains(vow_id));
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            saw_precommit_oom = true;
            // Every returned OOM precedes the fetch: no carrier, Host vow, or
            // bootstrap-import retain crossed the transaction boundary.
            try std.testing.expectEqual(@as(usize, 0), pair.a.served.queuedOutboundBytes());
            try std.testing.expectEqual(@as(usize, 0), client.vows.count());
            try std.testing.expectEqual(
                held_bootstrap_before,
                pair.a.served.port.peer.session_state.holdsImport(.from(engine.BOOTSTRAP_POSITION)),
            );
        }

        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(offset < 64);
    }
    try std.testing.expect(saw_precommit_oom);
}

test "Host transport profiles own extension semantics and refuse ambiguity" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x5d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try std.testing.expectError(error.UnknownTransport, host.designatorScheme("custom-key"));
    try std.testing.expectError(error.TransportSemanticsConflict, host.defineTransport(.{ .symbol = "tcp", .designator_scheme = .key }));
    try std.testing.expectError(error.InvalidTransportName, host.defineTransport(.{ .symbol = "", .designator_scheme = .address }));

    var mutable_name = [_]u8{ 'c', 'u', 's', 't', 'o', 'm', '-', 'k', 'e', 'y' };
    const defined = try host.defineTransport(.{ .symbol = &mutable_name, .designator_scheme = .key });
    mutable_name[0] = 'x';
    try std.testing.expectEqual(model.transport.DesignatorScheme.key, try host.designatorScheme("custom-key"));
    try std.testing.expectError(error.UnknownTransport, host.designatorScheme(&mutable_name));
    try std.testing.expectEqualStrings(defined, try host.defineTransport(.{ .symbol = "custom-key", .designator_scheme = .key }));
    try std.testing.expectError(error.TransportSemanticsConflict, host.defineTransport(.{ .symbol = "custom-key", .designator_scheme = .address }));

    const remote = crypto.SecretKey.fromSeed([_]u8{0x61} ** 32).publicKey();
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
    var dialer = test_host.init(allocator, [_]u8{0x62} ** 32, Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    var acceptor = test_host.init(allocator, [_]u8{0x63} ** 32, Host.Options.withFrameCap(frame_cap));
    defer acceptor.deinit();
    _ = try dialer.defineTransport(.{ .symbol = "custom-key", .designator_scheme = .key });
    _ = try acceptor.defineTransport(.{ .symbol = "custom-key", .designator_scheme = .key });

    try dialer.ensureAdvertisedLocator("custom-key");
    try acceptor.ensureAdvertisedLocator("custom-key");
    const demanded = crypto.SecretKey.fromSeed([_]u8{0x64} ** 32).publicKey().toDesignator();
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
    var host = test_host.init(allocator, [_]u8{0x65} ** 32, options);
    defer host.deinit();
    _ = try host.defineTransport(.{
        .symbol = "private-noise-stream",
        .designator_scheme = .key,
        .dial_shape = .host_port,
        .address_source = .direct_addresses_hint,
        .sealed_channel = true,
    });
    try host.ensureAdvertisedLocator("private-noise-stream");

    const remote = crypto.SecretKey.fromSeed([_]u8{0x66} ** 32).publicKey().toDesignator();
    const session = try host.openDialedLocator(.{
        .transport = "private-noise-stream",
        .designator = &remote,
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expect(session.sealed != null);
    try host.releaseSession(session);
}

test "byte-fed iroh dial pin: a hello claiming another identity is refused; a same-name forgery is unproven" {
    const allocator = std.testing.allocator;

    const honest_seed = [_]u8{0x41} ** 32;
    const honest = crypto.SecretKey.fromSeed(honest_seed);
    const designator = honest.publicKey().toDesignator();
    var uri_buf: [96]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "ocapn://{s}.iroh", .{designator[0..]});

    // Happy path: the acceptor advertises the dialed identity, so the dialer's
    // claim pin holds and the session opens.
    {
        var dialer = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
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
    // before the session opens — the claim pin, which is what survives fresh
    // session keys (ADR-0097).
    {
        const other_seed = [_]u8{0x43} ** 32;
        const other_designator = crypto.SecretKey.fromSeed(other_seed).publicKey().toDesignator();
        var dialer = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
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
    // (ADR-0105). The forgery is refused at the squatter's own side, by the
    // seam that would have signed the hello, so it never reaches the wire.
    {
        const squatter_seed = [_]u8{0x42} ** 32;
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
        const squatter_seed = [_]u8{0x42} ** 32;
        var dialer = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
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
    var host = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const a_session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7101", &.{});
    const b_session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7102", &.{});
    const a = a_session.peer_id;
    const b = b_session.peer_id;
    try host.testingQueueUniqueSessionAction(.flush, a);
    try host.testingQueueUniqueSessionAction(.flush, a);
    try host.testingQueueUniqueSessionAction(.close, a);
    try host.testingQueueUniqueSessionAction(.close, a);
    try host.testingQueueUniqueSessionAction(.flush, b);
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
    var host = test_host.init(failing.allocator(), [_]u8{0x2b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7103", &.{});

    // A queued frame and a terminal verdict can both need notification after
    // protocol ownership has moved. Mint reserved these two slots; neither
    // enqueue may consult the allocator in that irreversible window.
    failing.fail_index = failing.alloc_index;
    try host.testingQueueUniqueSessionAction(.flush, session.peer_id);
    try host.testingQueueUniqueSessionAction(.close, session.peer_id);
    try std.testing.expect(!failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect((try host.takeAction()).? == .flush);
    try std.testing.expect((try host.takeAction()).? == .close);

    // A reservation is reusable capacity, not a one-shot tail index. Repeated
    // pop/push cycles must compact the dead prefix without allocating or ever
    // reaching appendAssumeCapacity at the physical end of the backing.
    failing.fail_index = failing.alloc_index;
    for (0..256) |_| {
        try host.testingQueueUniqueSessionAction(.flush, session.peer_id);
        try std.testing.expect((try host.takeAction()).? == .flush);
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "abort encode OOM still closes authority and exposes close notification" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = test_host.init(failing.allocator(), [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7104", &.{});

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        host.testingCondemn(session, .resource_exhausted, "allocation pressure"),
    );
    try std.testing.expect(session.condemned);
    try std.testing.expectEqual(pancake.ocapn.session.State.closed, session.served.port.peer.session_state.state);

    failing.fail_index = std.math.maxInt(usize);
    var saw_close = false;
    while (try host.takeAction()) |action| switch (action) {
        .close => |peer_id| {
            try std.testing.expectEqual(session.peer_id, peer_id);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
}

test "partner abort immediately retires a byte-fed session without an echo" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x5b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x6b} ** 32, Host.Options.withFrameCap(frame_cap));
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
    try pair.b.served.port.peer.sendCopying(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = diagnostic,
    } });
    try pair.b.served.port.peer.stepToIdle();
    var abort_frame = (try pair.b.takeOutbound()) orelse return error.MissingAbort;
    defer abort_frame.deinit();

    try client.feed(pair.a, abort_frame.view());
    try std.testing.expect(pair.a.condemned);
    try std.testing.expect(pair.a.ingress_cancelled);
    try std.testing.expect(captured.broken);
    try std.testing.expectEqualStrings(diagnostic, captured.reason_buf[0..captured.reason_len]);
    try std.testing.expect((try pair.a.takeOutbound()) == null);
    try std.testing.expectError(error.SessionCondemned, client.feed(pair.a, abort_frame.view()));

    const action = (try client.takeAction()) orelse return error.MissingClose;
    try std.testing.expect(action == .close);
    try std.testing.expectEqual(pair.a.peer_id, action.close);
    try std.testing.expect((try client.takeAction()) == null);
}

test "partner abort before start-session retires an accepted session without an echo" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x7b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7108", &.{});

    // Accepted sessions project their own hello immediately. Remove it so any
    // later outbound frame would be an improper abort echo.
    var hello = (try session.takeOutbound()) orelse return error.MissingHello;
    hello.deinit();
    const hello_action = (try host.takeAction()) orelse return error.MissingFlush;
    try std.testing.expect(hello_action == .flush);
    try std.testing.expectEqual(session.peer_id, hello_action.flush);
    try std.testing.expect((try host.takeAction()) == null);

    var abort_frame = try pancake.ocapn.codec.syrup.encodeMessage(allocator, .{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "partner stopped during negotiation",
    } });
    defer abort_frame.deinit();

    try host.feed(session, abort_frame.view());
    try std.testing.expect(session.condemned);
    try std.testing.expect(session.ingress_cancelled);
    try std.testing.expect(!session.sessionOpen());
    try std.testing.expect((try session.takeOutbound()) == null);

    const action = (try host.takeAction()) orelse return error.MissingClose;
    try std.testing.expect(action == .close);
    try std.testing.expectEqual(session.peer_id, action.close);
    try std.testing.expect((try host.takeAction()) == null);
}

test "release cleanup OOM remains resumable through the action drain" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = test_host.init(failing.allocator(), [_]u8{0x4b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const remaining = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7105", &.{});
    const released = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7106", &.{});

    try remaining.served.port.peer.sendCopying(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "queued before release",
    } });
    host.testingMarkDirty(remaining.peer_id);

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
    try std.testing.expectEqual(remaining.peer_id, action.flush);
    var frame = (try remaining.takeOutbound()) orelse return error.MissingRetriedFrame;
    frame.deinit();
}

test "a keyed dial to a malformed designator refuses without freeing it twice" {
    // `keyed-tcp` pins the session to the key its designator names, so a
    // designator that is not canonical Ed25519 hex is refused after the shell
    // has been minted. The refusal path unwinds the mint, and the dialed
    // designator has exactly one owner, so this is a plain error rather than a
    // second free of bytes the shell already released. Reachable straight from
    // `pancake_host_session_open_dialed_locator`, which passes an embedder's
    // transport and designator through untouched.
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x21} ** 32, .{});
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
/// A capability names one object on one session. The wire says so with an
/// integer export position, and that integer means nothing outside the session
/// that minted it — so handing a partner a capability that belongs to a
/// different session is not a shorthand for anything, it is a category error.
///
/// The suite below crosses sessions deliberately, because every other test in
/// this tree drives one session at a time and therefore cannot see this class
/// at all. `sendRedeeming` is what made crossing natural: it hands an
/// application a second session beside a reply, and hosting the reply inbox on
/// the wrong one of the two is a one-word mistake.
const Pad = struct {
    pub fn handle(self: *Pad, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return .{ .string = "pad" };
    }
};

test "cross-session: a capability minted on one session is refused as an argument on another" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var other = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer other.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const first = try openPair(allocator, &client, &server, "127.0.0.1:7401", &dials);
    const second = try openPair(allocator, &client, &other, "127.0.0.1:7402", &dials);
    _ = try first.b.served.publish(&first.b.host.vat, "widget", Widget, .{});

    // Mint a capability on the SECOND session, then pad the FIRST session's
    // export table so the same integer position is occupied there too. The
    // padding is what turns a loud refusal into a silent substitution: without
    // a colliding row the position is simply absent and any existence check
    // catches it, which is why this class hides.
    const foreign = try second.a.served.spawn(&second.a.host.vat, Pad, .{});
    var pads: [8]driver.core.Exported = undefined;
    for (&pads) |*p| p.* = try first.a.served.spawn(&first.a.host.vat, Pad, .{});

    // The property being proven: no pad on this session can ever wear the
    // foreign capability's number, so the reference is absent here rather than
    // ambiguous, and the held-export check refuses it. Assert that rather than
    // trusting it, since a stride that stopped being applied would make this
    // test pass for the wrong reason.
    for (pads) |p| {
        try std.testing.expect(p.position != foreign.position);
    }

    const widget_ref = blk: {
        var fetched = CapturedRef{};
        const fetch_vow = try client.fetch(first.a, "widget");
        try client.vowOn(fetch_vow, .{ .ctx = &fetched, .func = CapturedRef.record });
        try pumpToQuiescence(allocator, &.{ &client, &server, &other }, &.{ first, second }, &dials);
        break :blk try fetched.require();
    };

    // Hand the far side a capability that lives on the other session. There is
    // no reading of this that is correct: the position names one of the first
    // session's pads, never the object the caller is holding. It must be
    // refused rather than quietly redirected.
    const result = client.send(first.a, widget_ref, .{
        .verb = "poke",
        .args = &.{.{ .reference = foreign.nearRef() }},
    });
    try std.testing.expectError(error.SendRejected, result);
}

test "cross-session: a capability minted on one session is refused as a send target on another" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var other = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer other.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const first = try openPair(allocator, &client, &server, "127.0.0.1:7411", &dials);
    const second = try openPair(allocator, &client, &other, "127.0.0.1:7412", &dials);

    // Addressing the other session's object is the same category error as
    // passing it: the position names one of this session's own objects, or
    // nothing. Either way it is not the actor being held.
    const foreign = try second.a.served.spawn(&second.a.host.vat, Pad, .{});
    var pads: [4]driver.core.Exported = undefined;
    for (&pads) |*p| p.* = try first.a.served.spawn(&first.a.host.vat, Pad, .{});

    try std.testing.expectError(
        error.NoSuchActor,
        client.send(first.a, foreign.nearRef(), .{ .verb = "poke", .args = &.{} }),
    );
}

test "cross-session: a capability minted under one host is refused on another host's session" {
    const allocator = std.testing.allocator;
    // Two hosts in one process is the ordinary shape, not an exotic one: a
    // binding's `connect` with no explicit host mints a fresh one per call, so
    // an application that dials twice holds capabilities from two hosts.
    var left = test_host.init(allocator, [_]u8{0x11} ** 32, Host.Options.withFrameCap(frame_cap));
    defer left.deinit();
    var left_partner = test_host.init(allocator, [_]u8{0x12} ** 32, Host.Options.withFrameCap(frame_cap));
    defer left_partner.deinit();
    var right = test_host.init(allocator, [_]u8{0x13} ** 32, Host.Options.withFrameCap(frame_cap));
    defer right.deinit();
    var right_partner = test_host.init(allocator, [_]u8{0x14} ** 32, Host.Options.withFrameCap(frame_cap));
    defer right_partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const l = try openPair(allocator, &left, &left_partner, "127.0.0.1:7421", &dials);
    const r = try openPair(allocator, &right, &right_partner, "127.0.0.1:7422", &dials);

    const under_left = try l.a.served.spawn(&l.a.host.vat, Pad, .{});
    var pads: [4]driver.core.Exported = undefined;
    for (&pads) |*p| p.* = try r.a.served.spawn(&r.a.host.vat, Pad, .{});
    for (pads) |p| {
        try std.testing.expect(p.position != under_left.position);
    }

    try std.testing.expectError(
        error.NoSuchActor,
        right.send(r.a, under_left.nearRef(), .{ .verb = "poke", .args = &.{} }),
    );
}

test "cross-session: an adopted peer gets its own export range too" {
    const allocator = std.testing.allocator;
    // The completion loop owns its peers inline and hands them to the host
    // through `publishAndOpenAcceptedOver`, so an adopted session never passes through
    // the owned mint. That is the path with the most connections on it, and
    // the one an application most plausibly holds two sessions of at once — so
    // it is the path a session-numbering fix least affords to miss.
    var host = test_host.init(allocator, [_]u8{0x50} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();

    const a = try publishAndOpenAcceptedOver(&host, &first, "tcp", "127.0.0.1:7451", &.{});
    const b = try publishAndOpenAcceptedOver(&host, &second, "tcp", "127.0.0.1:7452", &.{});

    const from_a = try a.served.spawn(&a.host.vat, Pad, .{});
    const from_b = try b.served.spawn(&b.host.vat, Pad, .{});
    try std.testing.expect(from_a.position != from_b.position);

    // And neither session holds the other's position, which is what makes the
    // held-export check refuse a capability offered to the wrong one.
    try std.testing.expect(a.served.refForExport(from_b.position) == null);
    try std.testing.expect(b.served.refForExport(from_a.position) == null);
}

test "cross-session: a released session's export range comes back for reuse" {
    const allocator = std.testing.allocator;
    // The ranges are carved out of one integer, so they are a fixed budget. A
    // host that never took a released session's range back would spend its
    // whole slot just by churning connections, and an attacker who can open and
    // close them reaches that on purpose. Reuse is what makes the slot a bound
    // on how many sessions are live at once rather than on how many the host
    // may ever open.
    var host = test_host.init(allocator, [_]u8{0x51} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    const a = try publishAndOpenAcceptedOver(&host, &first, "tcp", "127.0.0.1:7461", &.{});
    const released_base = first.session_state.export_base;
    const counter_after_first = host.node.next_export_base;
    try host.releaseSession(a);

    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();
    _ = try publishAndOpenAcceptedOver(&host, &second, "tcp", "127.0.0.1:7462", &.{});
    try std.testing.expectEqual(released_base, second.session_state.export_base);
    // And the counter did not move: the reuse is what paid for this session.
    try std.testing.expectEqual(counter_after_first, host.node.next_export_base);
}

test "cross-session: a reused export range is the oldest freed, not the newest" {
    const allocator = std.testing.allocator;
    // Reusing the range just freed would put a new session on a released one's
    // numbers immediately, which is the narrowest possible gap between a stale
    // capability and a live object wearing its position. Oldest-first puts
    // every other freed range in between.
    var host = test_host.init(allocator, [_]u8{0x52} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();
    const a = try publishAndOpenAcceptedOver(&host, &first, "tcp", "127.0.0.1:7463", &.{});
    const b = try publishAndOpenAcceptedOver(&host, &second, "tcp", "127.0.0.1:7464", &.{});
    const oldest = first.session_state.export_base;
    const newer = second.session_state.export_base;
    try host.releaseSession(a);
    try host.releaseSession(b);

    var third = engine.Peer.initNegotiating(allocator);
    defer third.deinit();
    var fourth = engine.Peer.initNegotiating(allocator);
    defer fourth.deinit();
    _ = try publishAndOpenAcceptedOver(&host, &third, "tcp", "127.0.0.1:7465", &.{});
    _ = try publishAndOpenAcceptedOver(&host, &fourth, "tcp", "127.0.0.1:7466", &.{});
    try std.testing.expectEqual(oldest, third.session_state.export_base);
    try std.testing.expectEqual(newer, fourth.session_state.export_base);
}

test "cross-session: a host that has spent its export slot refuses rather than naming the next host's" {
    const allocator = std.testing.allocator;
    // The counter walks one range at a time through a slot the host's identity
    // picked. Carrying past the end would hand this host the *next* host's
    // numbers, which aliases that host's sessions one for one — the very thing
    // the ranges exist to stop — and at the last slot would run export
    // positions into the range the node keeps for its own redeemed tokens, so a
    // position would read as a token. Refusing the mint is the fail-closed
    // answer; reuse above is what keeps an honest host from ever arriving here.
    var host = test_host.init(allocator, [_]u8{0x53} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    // Every position this node can hand out stays under its own token base.
    try std.testing.expect(host.node.export_base_end <= engine.Node.REDEEMED_TOKEN_BASE);

    host.node.next_export_base = host.node.export_base_end;
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    try std.testing.expectError(
        error.ExportRangeExhausted,
        publishAndOpenAcceptedOver(&host, &peer, "tcp", "127.0.0.1:7467", &.{}),
    );
    // Refused, not carried: the counter is still inside this node's slot.
    try std.testing.expectEqual(host.node.export_base_end, host.node.next_export_base);
}

test "core host: a claimed designator cannot condemn our own dial to it" {
    const allocator = std.testing.allocator;

    // The tiebreak matches an inbound partner's *claimed* location against the
    // dials we have outstanding. A signature proves the partner holds its
    // session key; it proves nothing about where the partner says it lives. On
    // a transport whose designator is a key, the two must agree, or any peer
    // that can open a connection could name a designator we are dialing and
    // make us condemn our own verified outbound session to it, repeatedly, for
    // an exporter it never has to reach or hold a key for.
    var victim = test_host.init(allocator, [_]u8{0x77} ** 32, Host.Options.withFrameCap(frame_cap));
    defer victim.deinit();
    var us = test_host.init(allocator, [_]u8{0x01} ** 32, Host.Options.withFrameCap(frame_cap));
    defer us.deinit();
    var attacker = test_host.init(allocator, [_]u8{0xff} ** 32, Host.Options.withFrameCap(frame_cap));
    defer attacker.deinit();

    // The attacker only wins the tiebreak when our identifier sorts lower, so
    // the scenario needs that ordering to be the interesting one.
    const our_pid = crypto.derivePublicIdentifier(us.node.secretKey().publicKey());
    const attacker_pid = crypto.derivePublicIdentifier(attacker.node.secretKey().publicKey());
    try std.testing.expect(std.mem.order(u8, &our_pid.bytes, &attacker_pid.bytes) == .lt);

    // The victim's keyed designator: the identity we are dialing.
    var victim_designator: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&victim_designator, "{x}", .{victim.node.secretKey().publicKey().bytes});

    const keyed_locator: pancake.ocapn.model.PeerLocator = .{
        .transport = "keyed-tcp",
        .designator = &victim_designator,
        .hints = pancake.ocapn.model.Hints.emptyFalse(),
    };
    const our_designator = us.node.secretKey().publicKey().toDesignator();
    var our_hint = [_]model.HintEntry{.{
        .name = model.transport.hint_direct_addresses,
        .value = .{ .string = "127.0.0.1:9200" },
    }};
    try us.setAdvertisedLocator(.{
        .transport = "keyed-tcp",
        .designator = &our_designator,
        .hints = .{ .entries = &our_hint },
    });
    try us.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:9100",
        .hints = model.Hints.emptyFalse(),
    });
    const our_dial = try us.openDialedLocator(keyed_locator);

    // A host of ours will not publish that locator: a key-designator transport
    // may name only the durable identity this node holds (ADR-0105).
    var attacker_hint = [_]model.HintEntry{.{
        .name = model.transport.hint_direct_addresses,
        .value = .{ .string = "127.0.0.1:9201" },
    }};
    try std.testing.expectError(
        error.UnheldIdentity,
        attacker.setAdvertisedLocator(.{
            .transport = "keyed-tcp",
            .designator = &victim_designator,
            .hints = .{ .entries = &attacker_hint },
        }),
    );

    // A hostile peer is not bound by our seams, so the attack is built by
    // hand: an `op:start-session` claiming the victim's designator as its own
    // location, signed with the attacker's own session key.
    const our_accepted = try us.openAcceptedAdvertised("tcp");
    var claim = try handshake_support.signedHelloFrame(
        allocator,
        attacker.node.secretKey(),
        "keyed-tcp",
        &victim_designator,
        pancake.ocapn.model.Hints.emptyFalse(),
    );
    defer claim.deinit();

    try us.feed(our_accepted, claim.view());

    // Crossed-hello matching does not treat a key-shaped designator as a peer
    // identity unless it is the session key that signed the hello, so this
    // unproved claim cannot condemn the dial to the real victim.
    try std.testing.expect(!our_dial.condemned);

    try us.releaseSession(our_accepted);
    try us.releaseSession(our_dial);
}

test "core host: a key-shaped address remains an address for crossed hellos" {
    const allocator = std.testing.allocator;
    var us = test_host.init(allocator, [_]u8{0x01} ** 32, Host.Options.withFrameCap(frame_cap));
    defer us.deinit();
    var partner = test_host.init(allocator, [_]u8{0xff} ** 32, Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();

    const our_pid = crypto.derivePublicIdentifier(us.node.secretKey().publicKey());
    const partner_pid = crypto.derivePublicIdentifier(partner.node.secretKey().publicKey());
    try std.testing.expect(std.mem.order(u8, &our_pid.bytes, &partner_pid.bytes) == .lt);

    const address = partner.node.secretKey().publicKey().toDesignator();
    try us.setAdvertisedLocator(tcpLocator("127.0.0.1:9120"));
    const dialed = try us.openDialedLocator(tcpLocator(&address));
    const accepted = try us.openAcceptedAdvertised("tcp");

    // Byte shape cannot change an address transport into a key transport. The
    // signed claim matches the address we dialed, so ordinary crossed-hello
    // ordering applies even though a different session key signed it.
    var hello = try handshake_support.signedHelloFrame(
        allocator,
        partner.node.secretKey(),
        "tcp",
        &address,
        model.Hints.emptyFalse(),
    );
    defer hello.deinit();
    try us.feed(accepted, hello.view());
    try std.testing.expect(dialed.condemned);
    try std.testing.expect(!accepted.condemned);

    try us.releaseSession(accepted);
    try us.releaseSession(dialed);
}

/// `Host.partnerIdentity` keeps three facts distinct: the session key verified
/// by the `op:start-session` signature, the designator claimed by the partner's
/// acceptable location, and the provenance of any durable identity proof.
/// Success means the handshake signature was verified; it does not make the
/// advertised designator an authenticated durable identity. Only provenance
/// from an authenticated channel establishes that stronger fact.
///
/// The tests below cover the verified-session requirement, the claimed locator
/// representation, and the provenance distinction. Transport-specific channel
/// proof is covered separately by the verified-channel tests.
///
/// The designator for the host built on `seed`: that host's Ed25519 public key
/// in canonical hexadecimal form.
fn keyedDesignator(seed: [32]u8) [crypto.PeerKey.designator_len]u8 {
    return crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
}

test "partner identity: a verified tcp session reports the key its handshake proved" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = [_]u8{0x0b} ** 32;
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);

    // The dialer learned the acceptor's per-session key by verifying its
    // signature. It is distinct from the server's durable identity seed.
    const seen = try client.partnerIdentity(pair.a);
    const expected_key = pair.b.sessionSecret().publicKey();
    try std.testing.expectEqualSlices(u8, expected_key.asBytes(), seen.session_key);
    try std.testing.expect(!expected_key.eql(crypto.SecretKey.fromSeed(server_seed).publicKey()));
    try std.testing.expectEqualStrings("127.0.0.1:7001", seen.designator);

    // `tcp` designates a socket address. The signature covers it, but the key
    // does not determine it, so the key question has no claim to make here and
    // false is the correct answer rather than a failure.
    try std.testing.expect(!seen.designatorIsSessionKey());

    // And the three facts stay distinct (ADR-0097): an address transport
    // proves no durable identity, so provenance says so rather than the
    // caller inferring it from the diagnostic above.
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, seen.provenance);
    try std.testing.expect(!seen.durableIdentityAuthenticated());
}

test "onion identity: a dial authenticates the sturdyref target, not a durable CapTP peer" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x5a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x5b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const service_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";
    try client.ensureAdvertisedLocator(model.transport.onion);
    try server.setAdvertisedLocator(onionLocator(service_id));
    const accepted = try server.openAcceptedAdvertised(model.transport.onion);
    const dialed = try client.openDialedLocator(onionLocator(service_id));
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // Tor proved the service named by the dial target. It did not prove that
    // the service's forwarded endpoint owns the durable identity in the CapTP
    // hello, so the two facts stay distinct.
    const identity = try client.partnerIdentity(dialed);
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, identity.provenance);

    const enlivened = try client.enlivenWithPolicy(
        dialed,
        onionSturdyref(service_id, "durable-widget"),
        .checked,
    );
    try std.testing.expectEqual(driver.core.PeerProvenance.dial_target, enlivened.provenance);
    var fetch = (try dialed.takeOutbound()) orelse return error.MissingFetch;
    fetch.deinit();
}

test "partner identity: keyed-tcp reports its claimed designator without authenticating it" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x1a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = [_]u8{0x1b} ** 32;
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const designator = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, "keyed-tcp", &designator, "127.0.0.1:7002");
    try client.ensureAdvertisedLocator("keyed-tcp");
    const dialed = try client.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    });
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());

    // The advertised durable name and the fresh session key remain separately
    // observable.
    const seen = try client.partnerIdentity(pair.a);
    try std.testing.expectEqualStrings(&designator, seen.designator);
    try std.testing.expect(!seen.designatorIsSessionKey());

    // The comparison is over canonical hex, not raw key bytes: the designator
    // is twice the key's length, so a raw-bytes comparison cannot match.
    try std.testing.expectEqual(seen.session_key.len * 2, seen.designator.len);

    // keyed-tcp supplies no channel proof, so the claimed key remains
    // unauthenticated.
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, seen.provenance);
    try std.testing.expect(!seen.durableIdentityAuthenticated());
}

test "session identity: a host signs each session with that session's own key" {
    // ADR-0097 step 4's structural half. Which key signs a session comes from
    // the Host's required session root, and every consumer — the keyed hello
    // and the handoff records naming the session — reads it through the
    // session rather than reaching for the node's durable key. Pointing the
    // source at distinct per-session seeds is the whole of the fresh-key
    // switch, so this drives it to prove the seam actually carries.
    const allocator = std.testing.allocator;

    const opts = Host.Options.withFrameCap(frame_cap);
    const durable_seed = [_]u8{0x4a} ** 32;
    var host = test_host.init(allocator, durable_seed, opts);
    defer host.deinit();

    // Two connections accepted on one listener, which is the simultaneous case
    // a real host sees: same advertised identity, different sessions.
    const first = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7301", &.{});
    const second = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7301", &.{});

    // Two sessions in one host, two different signing keys — and neither is
    // the host's durable key, which stays the node's own identity.
    const durable = crypto.SecretKey.fromSeed(durable_seed).publicKey();
    const first_key = first.sessionSecret().publicKey();
    const second_key = second.sessionSecret().publicKey();
    try std.testing.expect(!first_key.eql(second_key));
    try std.testing.expect(!first_key.eql(durable));
    try std.testing.expect(!second_key.eql(durable));

    // And the hello each session signed carries its own key, so the seam
    // reaches the wire rather than stopping at the accessor.
    var frame = first.served.port.peer.takeOutbound().?;
    defer frame.deinit();
    const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
    try std.testing.expectEqualSlices(u8, first_key.asBytes(), view.start_session.session_pubkey);

    // Both sessions are open at once, so this is the simultaneous case and not
    // two successive ones reusing a slot (ADR-0097 item 1). What stays equal
    // across them is the durable identity: each advertises the host's own
    // designator, which is the name a partner knows this host by, while the
    // keys above differ per connection.
    var second_frame = second.served.port.peer.takeOutbound().?;
    defer second_frame.deinit();
    const second_view = try pancake.ocapn.codec.syrup.decodeBody(second_frame.view());
    try std.testing.expectEqualSlices(u8, second_key.asBytes(), second_view.start_session.session_pubkey);
    try std.testing.expectEqualStrings(
        view.start_session.acceptable_location.designator,
        second_view.start_session.acceptable_location.designator,
    );
}

test "session identity: a give is signed by its session's key, not the host's durable key" {
    // The deepest coupling ADR-0097 step 4 has to move. A `desc:handoff-give`
    // names the gifter-exporter *session*, so its `gifter_side` must derive
    // from that session's key. While every session reuses its host's durable
    // key the two are the same bytes and a durable-key signature looks
    // correct; under distinct per-session keys they diverge, and only a
    // genuinely session-scoped signer still names the side the exporter
    // derives from the key it verified.
    const allocator = std.testing.allocator;

    const opts = Host.Options.withFrameCap(frame_cap);
    const durable_seed = [_]u8{0x4b} ** 32;
    var gifter = test_host.init(allocator, durable_seed, opts);
    defer gifter.deinit();
    var exporter = test_host.init(allocator, [_]u8{0x4c} ** 32, opts);
    defer exporter.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7311", &dials);

    // The gifter's side of this session, as the exporter will derive it: from
    // the key that signed the hello it verified.
    const session_key = pair.b.served.port.peer.session_state.partnerSessionKey().?;
    const from_session = try engine.handoff_names.sideName(session_key);
    const durable = crypto.SecretKey.fromSeed(durable_seed).publicKey();
    const from_durable = try engine.handoff_names.sideName(durable.asBytes());

    // The two really are different names here, so the assertion below has
    // teeth rather than passing on coincidence.
    try std.testing.expect(!std.mem.eql(u8, &from_session, &from_durable));

    // And the key the node signs this session's handoff records with is the
    // session's own, so the side it writes is `from_session`.
    const signer = pair.a.sessionSecret().publicKey();
    try std.testing.expectEqualSlices(u8, session_key, signer.asBytes());
}

test "partner identity: each leg reports the fact it holds, not the transport's name" {
    // Provenance is selected by the evidence one session holds, never by its
    // transport symbol (ADR-0105). Both legs below run `iroh` and neither
    // reports the same thing, because they hold different evidence: the dialer
    // was handed a verified remote by the code that realized the connection,
    // and the acceptor has no channel proof.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x3c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = [_]u8{0x3d} ** 32;
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const designator = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, "iroh", &designator, &.{});
    try client.ensureAdvertisedLocator("iroh");
    const dialed = try client.openDialedLocator(.{
        .transport = "iroh",
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    });
    // What the iroh adapter installs off the QUIC handshake; the byte-fed core
    // is handed the proof rather than inferring one.
    dialed.served.port.peer.bindVerifiedChannelKey(crypto.SecretKey.fromSeed(server_seed).publicKey());
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());

    const bound = try client.partnerIdentity(pair.a);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, bound.provenance);
    try std.testing.expect(bound.durableIdentityAuthenticated());

    // The acceptor had no realizer to hand it a verified remote, so the
    // dialer's key-shaped claim remains unauthenticated.
    const unproved = try server.partnerIdentity(pair.b);
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, unproved.provenance);
    try std.testing.expect(!unproved.durableIdentityAuthenticated());
    try std.testing.expectEqualStrings(&keyedDesignator([_]u8{0x3c} ** 32), unproved.designator);
}

test "verified channel key: an embedder's testimony reaches provenance on both legs" {
    // The test above is this topology with nobody to speak for the acceptor.
    // Here the embedder says what its own transport proved, which is what a binding
    // hosting its own iroh listener holds and had no way to state. Both legs,
    // because the proof belongs to the connection rather than to a direction.
    const allocator = std.testing.allocator;
    const client_seed = [_]u8{0x4c} ** 32;
    var client = test_host.init(allocator, client_seed, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = [_]u8{0x4d} ** 32;
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const server_designator = keyedDesignator(server_seed);
    const client_designator = keyedDesignator(client_seed);
    const accepted = try publishAndOpenAccepted(&server, "iroh", &server_designator, &.{});
    try client.ensureAdvertisedLocator("iroh");
    const dialed = try client.openDialedLocator(.{
        .transport = "iroh",
        .designator = &server_designator,
        .hints = model.Hints.emptyFalse(),
    });

    try client.bindVerifiedChannelKey(dialed, &server_designator);
    try server.bindVerifiedChannelKey(accepted, &client_designator);
    // The same statement made twice is still that statement.
    try server.bindVerifiedChannelKey(accepted, &client_designator);
    // One connection has one far end, so a second name for it is refused
    // rather than allowed to overwrite the first.
    try std.testing.expectError(
        error.ChannelKeyConflict,
        server.bindVerifiedChannelKey(accepted, &server_designator),
    );
    // A realizer's proof names a key; an address transport has none to give.
    try std.testing.expectError(
        error.InvalidChannelKey,
        server.bindVerifiedChannelKey(accepted, "127.0.0.1:9000"),
    );

    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());

    // The acceptor now reports the channel proof.
    const accepted_identity = try server.partnerIdentity(pair.b);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, accepted_identity.provenance);
    const bound = try client.partnerIdentity(pair.a);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, bound.provenance);

    // Too late to be the evidence it was for: the chokepoint that weighs a
    // partner's claim has already run.
    try std.testing.expectError(
        error.HandshakeAlreadyApplied,
        server.bindVerifiedChannelKey(accepted, &client_designator),
    );
}

test "partner identity: a session that does not verify its partner reports no identity" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x2a} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .verify_partner = false,
    });
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x2b} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .verify_partner = false,
    });
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7003", &dials);

    try std.testing.expectEqual(@as(usize, 0), client.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), client.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), server.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), server.partner_by_side.count());

    // The handshake completed and a key did arrive, so there are bytes here to
    // hand back. They are refused anyway: nothing checked them, and a caller
    // that could read them would have no way to tell them from proof.
    try std.testing.expectError(error.PartnerUnverified, client.partnerIdentity(pair.a));
}

test "partner identity: a session whose partner has not spoken yet reports no identity" {
    const allocator = std.testing.allocator;
    var server = test_host.init(allocator, [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();

    // Accepted, but no partner bytes have been fed, so no `op:start-session`
    // has arrived and there is no key yet.
    const accepted = try publishAndOpenAccepted(&server, "tcp", "127.0.0.1:7004", "");
    try std.testing.expectError(error.HandshakeIncomplete, server.partnerIdentity(accepted));
}

test "enroll: only a capability this session actually holds gets a routing token" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7601", &dials);
    const widget = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });

    // Come by a capability the way `fetch` does not cover: ask for one and
    // hold what the reply hands back.
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    var made = CapturedRef{};
    const make_vow = try client.send(pair.a, try vendor.require(), .{ .verb = "make", .args = &.{} });
    try client.vowOn(make_vow, .{ .ctx = &made, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    const raw = try made.require();
    try std.testing.expect(raw == .far);
    const position = raw.far.import_position.int();
    try std.testing.expect(model.ImportName.classify(position) == .wire);

    const token = try client.enrollCapability(pair.a, position, .object);
    try std.testing.expect(model.ImportName.classify(token) == .token);

    // Idempotent per import: one object keeps one identity, so a caller that
    // enrolls twice cannot hand two tokens for the same capability to two
    // recipients and have them compare unequal.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, position, .object));

    // A token is already routable. Enrolling it again would double-wrap it
    // into a reference no session can lower, so it passes through unchanged.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, token, .object));

    // A position with no import row names nothing here. Minting a token for it
    // would route a later gift to a capability the partner never exported, and
    // there would be nowhere to remember the token, so a second enroll would
    // mint a second identity for one object.
    try std.testing.expectError(error.ForeignArgument, client.enrollCapability(pair.a, 9_999, .object));

    // The rule is the row, not reachability. The partner's bootstrap is
    // addressable on a session that has never fetched, and is still refused
    // there; the fetch above is what gave *this* session its row for it, and
    // that same position enrolls fine here.
    var stranger = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer stranger.deinit();
    const fresh = try openPair(allocator, &client, &stranger, "127.0.0.1:7602", &dials);
    try std.testing.expectError(error.ForeignArgument, client.enrollCapability(fresh.a, 0, .object));
    try std.testing.expect(try client.enrollCapability(pair.a, 0, .object) != 0);
}

test "enroll: the kind the caller names is what routing reads off the token" {
    // A partner can hand over a promise it has not settled, and only as a
    // delivered argument or a reply — the position arrives with no record of
    // being unsettled, because a far reference goes on the wire the same way
    // either way. So the kind is the caller's to supply, and this is what
    // depends on it: the introducing-session proxy claims a fulfilled *promise*
    // token and declines everything else, so a promise enrolled as an object
    // would reach a third party as a bare position it cannot wait on.
    const allocator = std.testing.allocator;
    var introducer_host = test_host.init(allocator, [_]u8{0x1a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer introducer_host.deinit();
    var exporter = test_host.init(allocator, [_]u8{0x1b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x1c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &introducer_host, &exporter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    // Two distinct capabilities on one session, so the two enrollments differ
    // in kind rather than in position.
    const i_to_e = try openPair(allocator, &introducer_host, &exporter, "127.0.0.1:7621", &dials);
    const first = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "first", Widget, .{});
    const second = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "second", Widget, .{});
    _ = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "vend-first", Vendor, .{ .widget = first.nearRef() });
    _ = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "vend-second", Vendor, .{ .widget = second.nearRef() });

    var as_promise = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.fetch(i_to_e.a, "vend-first"),
        .{ .ctx = &as_promise, .func = CapturedRef.record },
    );
    var as_object = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.fetch(i_to_e.a, "vend-second"),
        .{ .ctx = &as_object, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{i_to_e}, &dials);

    var promise_held = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.send(i_to_e.a, try as_promise.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &promise_held, .func = CapturedRef.record },
    );
    var object_held = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.send(i_to_e.a, try as_object.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &object_held, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{i_to_e}, &dials);

    const promise_token = try introducer_host.enrollCapability(
        i_to_e.a,
        (try promise_held.require()).far.import_position.int(),
        .promise,
    );
    const object_token = try introducer_host.enrollCapability(
        i_to_e.a,
        (try object_held.require()).far.import_position.int(),
        .object,
    );

    // A recipient session to introduce onto: the proxy needs a session that is
    // not the capability's home.
    const r_to_i = try openPair(allocator, &recipient, &introducer_host, "127.0.0.1:7622", &dials);

    // The promise-kind token is claimed and rewritten to a near promise the
    // recipient can listen on; the object-kind token is left for the gifter
    // intercept beside it.
    const proxied = try introducer_host.node.proxyForeignPromiseFulfill(r_to_i.b.peer_id, promise_token);
    try std.testing.expect(proxied != null);
    try std.testing.expect(proxied.? == .near);
    try std.testing.expectEqual(model.RefKind.promise, proxied.?.near.kind);
    try std.testing.expect(try introducer_host.node.proxyForeignPromiseFulfill(r_to_i.b.peer_id, object_token) == null);
}

test "enroll: one position cannot be enrolled under both kinds" {
    // Enrolling is idempotent per import, so a second enroll of one position is
    // answered with the first one's token. The kind, though, lives on the row
    // that token names, and routing reads it there. So a second caller naming
    // the same position with the other kind cannot be given what it asked for,
    // and it must not be handed the row's kind under its own spelling either:
    // that would tell an application its promise had been enrolled as a promise
    // when the row says object, and the introducing-session proxy would then
    // decline the token it was told to expect a settlement through. The
    // disagreement is refused instead.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x2a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x2b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7631", &dials);
    const widget = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    var made = CapturedRef{};
    try client.vowOn(
        try client.send(pair.a, try vendor.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &made, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const position = (try made.require()).far.import_position.int();

    // A fresh enroll cannot conflict: the row is created with the kind asked
    // for, so the first call decides what this position is.
    const token = try client.enrollCapability(pair.a, position, .promise);

    // Same position, same kind: still idempotent, still one token.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, position, .promise));

    // Same position, the other kind: refused, and typed, so an embedder can
    // tell this apart from a position it does not hold.
    try std.testing.expectError(
        error.EnrolledKindConflict,
        client.enrollCapability(pair.a, position, .object),
    );

    // The refusal changed nothing. The row still holds the kind it was created
    // with, and the token still answers to it.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, position, .promise));

    // A token passes through unchanged whatever kind accompanies it: it is
    // already routable, and the row it was minted from holds the kind, so there
    // is nothing here to record or to disagree with.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, token, .object));
}

test "enroll: a capability from a call reply gifts once it is enrolled" {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    // The exporter hosts a widget and a vendor that hands it out. The gifter
    // reaches the widget through an ordinary call to the vendor, which is the
    // shape `fetch` does not cover: a capability returned from a call, or
    // lifted from a delivered argument, arrives with no routing token.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7611", &dials);
    const hosted = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "vendor", Vendor, .{ .widget = hosted.nearRef() });

    var vendor = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const vendor_ref = try vendor.require();

    var made = CapturedRef{};
    const make_vow = try gifter.send(g_to_e.a, vendor_ref, .{ .verb = "make", .args = &.{} });
    try gifter.vowOn(make_vow, .{ .ctx = &made, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    // The premise this verb exists for, asserted rather than assumed: a call
    // reply settles with a plain wire position. Nothing recorded its home, so
    // the gifter intercept has nothing to look it up by.
    const raw = try made.require();
    try std.testing.expect(raw == .far);
    const raw_position = raw.far.import_position.int();
    try std.testing.expect(model.ImportName.classify(raw_position) == .wire);

    // Enrolling records the home, which is the whole of what was missing.
    const token = try gifter.enrollCapability(g_to_e.a, raw_position, .object);
    try std.testing.expect(model.ImportName.classify(token) == .token);
    const token_arg: model.Reference = .{ .far = model.FarRef.object(token) };

    // From here the existing three-party machinery runs untouched: the
    // gifter's ordinary reply with a foreign-homed capability becomes a signed
    // give, and the recipient redeems it.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7612", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = token_arg });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    var redeemed = CapturedRef{};
    const introduce_vow = try recipient.send(r_to_g.a, introducer_ref, .{ .verb = "introduce", .args = &.{} });
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    // One dial, naming the exporter: the give carried a real home because the
    // enrollment gave it one.
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];
    try std.testing.expect(parked.host == &recipient);

    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7611", &.{});
    _ = try e_accepts_r.served.publish(&e_accepts_r.host.vat, "widget", Widget, .{});
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // The capability the recipient ends up holding reaches the exporter's own
    // object, over the recipient's own connection. That is the claim: a
    // capability that never came from `fetch` was handed to a third party.
    const redeemed_ref = try redeemed.require();
    var poked = CapturedString{};
    const poke_vow = try recipient.send(r_to_g.a, redeemed_ref, .{ .verb = "poke", .args = &.{} });
    try recipient.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
}

test "enroll: forgetting to enroll breaks the one reply, not the whole session" {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7621", &dials);
    const hosted = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "vendor", Vendor, .{ .widget = hosted.nearRef() });
    var vendor = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    var made = CapturedRef{};
    const make_vow = try gifter.send(g_to_e.a, try vendor.require(), .{ .verb = "make", .args = &.{} });
    try gifter.vowOn(make_vow, .{ .ctx = &made, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const raw = try made.require();

    // The introducer replies with the capability *without* enrolling it, so
    // the node was never told its home and the gifter intercept declines. The
    // reply is then a position that means nothing on the recipient's session.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7622", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = raw });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    var broke = false;
    const introduce_vow = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    try recipient.vowOn(introduce_vow, .{ .ctx = &broke, .func = promise_capture.captureBroken });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    // The caller learns this introduction failed, and nothing was gifted.
    try std.testing.expect(broke);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);

    // The session survives it. Refusing the one reply is what keeps a
    // forgotten enrollment from becoming an `InvalidReference` that tears the
    // whole session down: the next call on that session still works.
    try std.testing.expect(r_to_g.a.sessionOpen());
    var poked = CapturedString{};
    const poke_vow = try gifter.send(g_to_e.a, raw, .{ .verb = "poke", .args = &.{} });
    try gifter.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
}

test "listen: a host vow settles on the partner's notification, and is spent once" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7701", &dials);
    const widget = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });

    // Come by a reference through a reply, so the client holds a raw wire
    // position rather than a token: that is what a listen target looks like.
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    var made = CapturedRef{};
    try client.vowOn(
        try client.send(pair.a, try vendor.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &made, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const held = try made.require();

    // Listening on it asks the partner how it settles. CapTP answers a listen
    // on an already-settled capability at once, so the notification comes back
    // naming the same object — proof the round trip ran, not that a promise
    // stayed pending.
    var settled = CapturedRef{};
    const vow = try client.listenTo(pair.a, held);
    try client.vowOn(vow, .{ .ctx = &settled, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const notified = try settled.require();
    try std.testing.expect(notified == .far);
    try std.testing.expectEqual(held.far.import_position, notified.far.import_position);

    // The vow is spent: its row retired when it settled, so a late observer is
    // refused rather than parked on a fire that already happened.
    try std.testing.expectError(
        error.NoSuchVow,
        client.vowOn(vow, .{ .ctx = &settled, .func = CapturedRef.record }),
    );

    // A target this session does not hold names nothing here, refused before
    // anything reaches the wire.
    try std.testing.expectError(
        error.InvalidReference,
        client.listenTo(pair.a, .{ .far = model.FarRef.promise(9_999) }),
    );
}

test "listen: an unsettled listen vow breaks when its session goes" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7702", &dials);
    const widget = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    var made = CapturedRef{};
    try client.vowOn(
        try client.send(pair.a, try vendor.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &made, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // Listen, but never shuttle the frame: the partner never answers, so the
    // vow is still outstanding when the session goes, and releasing it must
    // break the vow rather than strand its observer.
    var broke = false;
    const vow = try client.listenTo(pair.a, try made.require());
    try client.vowOn(vow, .{ .ctx = &broke, .func = promise_capture.captureBroken });
    try client.releaseSession(pair.a);
    try std.testing.expect(broke);
    try server.releaseSession(pair.b);
}

/// A behavior that defers its answer onto a resolver vow (ADR-0102) and
/// parks the resolver id for the test body — the stand-in for a worker that
/// completes off-turn.
const Deferring = struct {
    host: *Host,
    session: *HostSession,
    out_resolver: *u64,

    pub fn handle(self: *Deferring, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "work")) return error.NoSuchMethod;
        self.out_resolver.* = try self.host.deferTurn(self.session, turn);
        return .{ .void = {} };
    }
};

test "core host: a behavior defers onto a resolver vow and the settle re-enters top-level (ADR-0102)" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x2a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x2b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |d| allocator.free(d.designator);
        dials.deinit(allocator);
    }
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7821", &dials);

    var minted_resolver: u64 = 0;
    _ = try pair.b.served.publish(&pair.b.host.vat, "worker", Deferring, .{
        .host = &server,
        .session = pair.b,
        .out_resolver = &minted_resolver,
    });

    var worker = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "worker"), .{ .ctx = &worker, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const worker_ref = try worker.require();

    var reply = CapturedString{};
    try client.vowOn(
        try client.send(pair.a, worker_ref, .{ .verb = "work", .args = &.{} }),
        .{ .ctx = &reply, .func = CapturedString.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // The behavior returned and every wire quiesced, yet the answer is still
    // open: the deferral holds it for the resolver.
    try std.testing.expect(minted_resolver != 0);
    try std.testing.expect(reply.len == 0 and !reply.broken);

    // Direct Zig callers obey the same plain-data boundary as the C binding
    // and worker mailbox. Rejection happens before settlement, so the one-shot
    // resolver remains usable by the eventual plain result.
    const foreign_ref = model.Argument{ .reference = .{ .far = model.FarRef.object(1) } };
    try std.testing.expectError(error.ForeignArgument, server.resolverFulfill(minted_resolver, foreign_ref));
    const nested = [_]model.Argument{.{ .list = &.{foreign_ref} }};
    try std.testing.expectError(
        error.ForeignArgument,
        server.resolverFulfill(minted_resolver, .{ .tagged = .{ .tag = "nested", .value = &nested } }),
    );
    var handoff = model.Handoff{ .give = .{
        .recipient_key = "",
        .exporter = .{ .transport = "tcp", .designator = "127.0.0.1:1" },
        .gifter_exporter_session = "",
        .gifter_side = "",
        .gift_id = "",
        .signature = "",
    } };
    try std.testing.expectError(
        error.ForeignArgument,
        server.resolverFulfill(minted_resolver, .{ .handoff = &handoff }),
    );

    // The worker completes: the settle re-enters at the top level, the
    // deferred wire answer resolves, and the partner hears it.
    try server.resolverFulfill(minted_resolver, .{ .string = "computed" });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqualStrings("computed", reply.text());

    // One attempt: the resolver and its hidden vow row are consumed.
    try std.testing.expectError(actors.Error.AlreadySettled, server.resolverBreak(minted_resolver, "late"));
}

test "core host: local and foreign deferrals publish no Host or Vat authority" {
    const Refusing = struct {
        host: *Host,
        session: *HostSession,
        expected: anyerror,
        refused: *bool,

        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Message) !model.Argument {
            _ = msg;
            _ = self.host.deferTurn(self.session, turn) catch |err| {
                if (err != self.expected) return err;
                self.refused.* = true;
                return .{ .void = {} };
            };
            return error.UnexpectedDeferral;
        }
    };

    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x42} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x43} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7822", &dials);

    const next_vow = server.next_vow;
    const next_resolver = server.next_resolver;
    var local_refused = false;
    const local = try server.vat.spawn(Refusing, .{
        .host = &server,
        .session = pair.b,
        .expected = actors.Error.NotLocal,
        .refused = &local_refused,
    });
    _ = try server.vat.near(local, .{ .verb = "local", .args = &.{} });
    try std.testing.expect(local_refused);
    try std.testing.expectEqual(next_vow, server.next_vow);
    try std.testing.expectEqual(next_resolver, server.next_resolver);
    try std.testing.expectEqual(@as(usize, 0), server.vows.count());
    try std.testing.expectEqual(@as(usize, 0), server.resolver_index.count());

    var foreign_refused = false;
    const foreign = try server.vat.spawn(Refusing, .{
        .host = &client,
        .session = pair.b,
        .expected = error.ForeignTurn,
        .refused = &foreign_refused,
    });
    _ = try server.vat.near(foreign, .{ .verb = "foreign", .args = &.{} });
    try std.testing.expect(foreign_refused);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    try std.testing.expectEqual(@as(usize, 0), client.resolver_index.count());
}

test "core host: a served tell cannot mint resolver authority" {
    const RefusingTell = struct {
        host: *Host,
        session: *HostSession,
        refused: *bool,

        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Message) !model.Argument {
            _ = msg;
            _ = self.host.deferTurn(self.session, turn) catch |err| {
                if (err != error.NoAnswer) return err;
                self.refused.* = true;
                return .{ .void = {} };
            };
            return error.UnexpectedDeferral;
        }
    };

    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x44} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x45} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7823", &dials);

    var refused = false;
    _ = try pair.b.served.publish(&server.vat, "tell-worker", RefusingTell, .{
        .host = &server,
        .session = pair.b,
        .refused = &refused,
    });
    var worker = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "tell-worker"), .{ .ctx = &worker, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const next_vow = server.next_vow;
    const next_resolver = server.next_resolver;
    try client.tell(pair.a, try worker.require(), .{ .verb = "tell", .args = &.{} });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    try std.testing.expect(refused);
    try std.testing.expectEqual(next_vow, server.next_vow);
    try std.testing.expectEqual(next_resolver, server.next_resolver);
    try std.testing.expectEqual(@as(usize, 0), server.vows.count());
    try std.testing.expectEqual(@as(usize, 0), server.resolver_index.count());
}

test "core host: the action-queue ceiling covers parked enlivens, a fresh session, and every vow with no drain between" {
    // The reservation ceiling has one owner (`Host.reserveActions`), and this
    // is what it is for: pile up every class of already-promised notification
    // at once — two parked select-or-dial enlivens, a session minted after
    // them, and live vows on top — with no action drain in between to relieve
    // the queue. Every settle must still land, because each was reserved
    // before its promise existed.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x5a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x5b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |d| allocator.free(d.designator);
        dials.deinit(allocator);
    }

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7841", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    // Two enlivens for peers this host has never dialed: both park, both
    // pre-mint a vow id, and both reserve their own completion slot.
    const parked_one = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7842", "widget"));
    const parked_two = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7843", "widget"));
    try std.testing.expect(parked_one != parked_two);

    // A live vow on the open session, and a session minted while both
    // enlivens are still parked — the mint reserves the two notifications its
    // own session owes without disturbing what the parked pair already hold.
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    var third = test_host.init(allocator, [_]u8{0x5c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer third.deinit();
    const spare = try publishAndOpenAccepted(&third, "tcp", "127.0.0.1:7844", &.{});
    const spare_dialed = try client.openDialedLocator(tcpLocator("127.0.0.1:7844"));
    const spare_pair = Pair{ .ah = &client, .a = spare_dialed, .bh = &third, .b = spare };

    // Only now drain. Both dials surface, and answering them settles both
    // parked vows through the queue that was reserved for them all along.
    try pumpToQuiescence(allocator, &.{ &client, &server, &third }, &.{ pair, spare_pair }, &dials);
    _ = try fetched.require();
    try std.testing.expectEqual(@as(usize, 2), dials.items.len);

    for (dials.items) |d| allocator.free(d.designator);
    const tickets = [_]pancake.ocapn.engine.Node.PendingId{ dials.items[0].ticket, dials.items[1].ticket };
    dials.clearRetainingCapacity();
    // Fail both dials: the break is the same queued completion a success
    // would take, and it needs the same reserved slot.
    for (tickets) |ticket| try client.dialFailed(ticket, "unreachable in this scenario");

    var settled_ids: [2]bool = .{ false, false };
    while (try client.nextAction()) |action| {
        switch (action) {
            .failed => |f| {
                if (f.vow_id == parked_one) settled_ids[0] = true;
                if (f.vow_id == parked_two) settled_ids[1] = true;
            },
            else => {},
        }
    }
    try std.testing.expect(settled_ids[0] and settled_ids[1]);
}

// ── The live trace tap (driver_core.trace) ───────────────────────────────────
// One sink per host hears the open (with the real codec and the partner's
// name), the message verbs both directions, and the close, with no sink
// installed costing every emit site one null check. The bindings' enable_trace
// veneers stand on this seam, so this scenario is the family's root proof.

/// Records each message's verb, direction, and wire tag, so a test can ask
/// whether two hosts tagged one frame the same way.
const DigestLog = struct {
    const Row = struct { verb: [32]u8 = undefined, verb_len: usize = 0, outbound: bool = false, digest: [driver.core.trace.digest_bytes]u8 = undefined };
    rows: [32]Row = undefined,
    n: usize = 0,

    fn emit(ctx: ?*anyopaque, event: driver.core.trace.Event) void {
        const self: *DigestLog = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .message => |m| {
                if (self.n == self.rows.len) return;
                var row = Row{ .outbound = m.outbound, .digest = m.digest };
                row.verb_len = @min(m.verb.len, row.verb.len);
                @memcpy(row.verb[0..row.verb_len], m.verb[0..row.verb_len]);
                self.rows[self.n] = row;
                self.n += 1;
            },
            else => {},
        }
    }

    fn find(self: *const DigestLog, verb: []const u8, outbound: bool) ?[driver.core.trace.digest_bytes]u8 {
        for (self.rows[0..self.n]) |row| {
            if (row.outbound != outbound) continue;
            if (!std.mem.eql(u8, row.verb[0..row.verb_len], verb)) continue;
            return row.digest;
        }
        return null;
    }

    /// The first two outbound tags for `verb`, or null when fewer than two
    /// were recorded.
    fn bothOutbound(self: *const DigestLog, verb: []const u8) ?[2][driver.core.trace.digest_bytes]u8 {
        var out: [2][driver.core.trace.digest_bytes]u8 = undefined;
        var seen: usize = 0;
        for (self.rows[0..self.n]) |row| {
            if (!row.outbound) continue;
            if (!std.mem.eql(u8, row.verb[0..row.verb_len], verb)) continue;
            out[seen] = row.digest;
            seen += 1;
            if (seen == 2) return out;
        }
        return null;
    }
};

const TraceLog = struct {
    /// Compact rows: kind letter + detail, enough to assert order and facts.
    buf: [16][96]u8 = undefined,
    lens: [16]usize = .{0} ** 16,
    n: usize = 0,
    /// Each open's wire name, kept whole rather than folded into the row
    /// above: the claim it carries is an equality between two hosts, not an
    /// order or a spelling.
    wires: [8][64]u8 = undefined,
    wire_lens: [8]usize = .{0} ** 8,
    wire_n: usize = 0,

    fn emit(ctx: ?*anyopaque, event: driver.core.trace.Event) void {
        const self: *TraceLog = @ptrCast(@alignCast(ctx.?));
        if (event == .session_open and self.wire_n < self.wires.len) {
            const wire = event.session_open.session_id;
            if (wire.len <= self.wires[self.wire_n].len) {
                @memcpy(self.wires[self.wire_n][0..wire.len], wire);
                self.wire_lens[self.wire_n] = wire.len;
                self.wire_n += 1;
            }
        }
        if (self.n == self.buf.len) return;
        const line = switch (event) {
            .session_open => |open| std.fmt.bufPrint(
                &self.buf[self.n],
                "open codec={s} captp={s} designator={s} transport={s} provenance={s}",
                .{
                    @tagName(open.codec),
                    @tagName(open.captp_version),
                    open.designator,
                    open.transport,
                    @tagName(open.provenance),
                },
            ) catch return,
            .message => |msg| std.fmt.bufPrint(
                &self.buf[self.n],
                "msg {s} {s}",
                .{ if (msg.outbound) "out" else "in", msg.verb },
            ) catch return,
            .session_close => std.fmt.bufPrint(&self.buf[self.n], "close", .{}) catch return,
        };
        self.lens[self.n] = line.len;
        self.n += 1;
    }

    fn row(self: *const TraceLog, i: usize) []const u8 {
        return self.buf[i][0..self.lens[i]];
    }

    fn contains(self: *const TraceLog, needle: []const u8) bool {
        for (0..self.n) |i| {
            if (std.mem.indexOf(u8, self.row(i), needle) != null) return true;
        }
        return false;
    }

    /// The one wire name this log saw, for a host holding exactly one session.
    fn onlyWire(self: *const TraceLog) []const u8 {
        std.debug.assert(self.wire_n == 1);
        return self.wires[0][0..self.wire_lens[0]];
    }

    fn sawWire(self: *const TraceLog, needle: []const u8) bool {
        for (0..self.wire_n) |i| {
            if (std.mem.eql(u8, self.wires[i][0..self.wire_lens[i]], needle)) return true;
        }
        return false;
    }
};

test "core host: the live trace reports open, both message directions, and close" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x5a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x5b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var client_log = TraceLog{};
    var server_log = TraceLog{};
    client.setTrace(.{ .ctx = &client_log, .emit = TraceLog.emit });
    server.setTrace(.{ .ctx = &server_log, .emit = TraceLog.emit });
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7009", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    var fetched = CapturedRef{};
    const fetch_vow = try client.fetch(pair.a, "widget");
    try client.vowOn(fetch_vow, .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();

    const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    var reply = CapturedString{};
    try client.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", reply.buf[0..reply.len]);

    // The dialer's first row is its open, naming the codec the core actually
    // negotiated and the designator it dialed; the send traced outbound.
    try std.testing.expect(client_log.n > 0);
    try std.testing.expect(std.mem.startsWith(u8, client_log.row(0), "open codec=syrup"));
    try std.testing.expect(client_log.contains("designator=127.0.0.1:7009"));
    // A designator alone does not name a location: the spec requires the
    // transport beside it. Provenance says whether the channel proved it.
    try std.testing.expect(client_log.contains("transport=tcp"));
    try std.testing.expect(client_log.contains("provenance=unauthenticated"));
    try std.testing.expect(client_log.contains("msg out poke"));

    // The acceptor heard the same verb inbound, on its own open session.
    try std.testing.expect(server_log.contains("open codec=syrup"));
    try std.testing.expect(server_log.contains("msg in poke"));

    // Release pairs the close with the open, exactly once per side.
    try client.releaseSession(pair.a);
    try server.releaseSession(pair.b);
    try std.testing.expect(client_log.contains("close"));
    try std.testing.expect(server_log.contains("close"));
}

test "core host: deinit closes every traced open exactly once" {
    const allocator = std.testing.allocator;
    var peer = test_host.init(allocator, [_]u8{0x40} ** 32, Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();
    var host = test_host.init(allocator, [_]u8{0x41} ** 32, Host.Options.withFrameCap(frame_cap));
    var log = TraceLog{};
    host.setTrace(.{ .ctx = &log, .emit = TraceLog.emit });
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    _ = try openPair(allocator, &peer, &host, "127.0.0.1:7098", &dials);
    host.deinit();
    var closes: usize = 0;
    for (0..log.n) |i| {
        if (std.mem.eql(u8, log.row(i), "close")) closes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), closes);
}

test "core host: a pancake-to-pancake pair holds the next profile over capnp" {
    // The native pancake job — `engine.negotiation.Offer.native` prefers
    // `next` and Cap'n Proto together — run at the Host tier for the first
    // time. Only `engine.pairing` (in-process, no Host) had ever exercised
    // `next`, because `Host.Options` carried no version and every socket
    // session took the v1.0 floor. The profile is a wire difference, not a
    // label: on `next` an answer settles through a resolve, where V1.0 has
    // no native `op:resolve` and settles through a `resolve_me_desc`
    // callback. A handshake that completes here is both ends agreeing on
    // the version they put in `op:start-session` and on the grammar that
    // framed it.
    const allocator = std.testing.allocator;
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.codec = .capnp;
    opts.captp_version = .next;
    var a = test_host.init(allocator, [_]u8{0x4a} ** 32, opts);
    defer a.deinit();
    var b = test_host.init(allocator, [_]u8{0x4b} ** 32, opts);
    defer b.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &a, &b, "127.0.0.1:7010", &dials);
    try std.testing.expect(pair.a.sessionOpen());
    try std.testing.expect(pair.b.sessionOpen());
    // Both ends recorded the negotiated profile, not the floor.
    try std.testing.expectEqual(
        model.CaptpVersion.next,
        pair.a.served.port.peer.session_state.captp_version,
    );
    try std.testing.expectEqual(
        model.CodecId.capnp,
        pair.b.served.port.peer.session_state.codec,
    );
}

test "core host: one host holds a next capnp session and a baseline session at once" {
    // The shape `apps/ocapnviz/src/fixtures/three-vat-handoff-mixed.ts` draws:
    // a pancake peer talking Cap'n Proto to another pancake peer while talking
    // the v1.0 Syrup baseline to a peer that speaks only that, on the same host
    // at the same time. Nothing in the tree could do this before: a host's
    // profile was stamped onto every session it minted, so a partner that
    // disagreed was refused rather than met where it stood.
    //
    // Neither side is told anything out of band. Each hello states what its
    // sender prefers, and each session settles its own pair from the two.
    const allocator = std.testing.allocator;
    var native_opts = Host.Options.withFrameCap(frame_cap);
    native_opts.codec = .capnp;
    native_opts.captp_version = .next;

    var hub = test_host.init(allocator, [_]u8{0x5a} ** 32, native_opts);
    defer hub.deinit();
    var native_peer = test_host.init(allocator, [_]u8{0x5b} ** 32, native_opts);
    defer native_peer.deinit();
    // A peer that knows only the baseline: the profile a Goblins vat speaks.
    var baseline_peer = test_host.init(allocator, [_]u8{0x5c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer baseline_peer.deinit();

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const native = try openPair(allocator, &hub, &native_peer, "127.0.0.1:7011", &dials);
    const baseline = try openPair(allocator, &hub, &baseline_peer, "127.0.0.1:7012", &dials);

    try std.testing.expect(native.a.sessionOpen());
    try std.testing.expect(baseline.a.sessionOpen());

    // Two sessions on one host, each on the profile its pair reached.
    const native_state = &native.a.served.port.peer.session_state;
    try std.testing.expectEqual(model.CaptpVersion.next, native_state.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, native_state.codec);

    const baseline_state = &baseline.a.served.port.peer.session_state;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, baseline_state.captp_version);
    try std.testing.expectEqual(model.CodecId.syrup, baseline_state.codec);

    // The hub asked for the same thing on both, and got what each partner
    // could follow. That difference is the point: the preference is a
    // property of this peer, the active pair a property of the two.
    try std.testing.expectEqual(model.CaptpVersion.next, baseline_state.preferred.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, baseline_state.preferred.codec);

    // And the partner that knows only the baseline recorded the same session.
    const far_state = &baseline.b.served.port.peer.session_state;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, far_state.captp_version);
    try std.testing.expectEqual(model.CodecId.syrup, far_state.codec);
}

test "core host: feature offers are carried by the signed hello and intersected" {
    const allocator = std.testing.allocator;
    var limited_opts = Host.Options.withFrameCap(frame_cap);
    limited_opts.features = model.FeatureSet.minimum();
    var limited = test_host.init(allocator, [_]u8{0x6d} ** 32, limited_opts);
    defer limited.deinit();

    var full = test_host.init(allocator, [_]u8{0x6e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer full.deinit();

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &limited, &full, "127.0.0.1:7015", &dials);
    try std.testing.expectEqual(model.FeatureSet.minimum(), pair.a.served.port.peer.session_state.features);
    try std.testing.expectEqual(model.FeatureSet.minimum(), pair.b.served.port.peer.session_state.features);
}

test "core host: the live trace reports each session's settled profile, not the host's preference" {
    // What a viewer draws has to be what the two peers agreed, or it draws the
    // configuration and calls it the wire. The ordering this depends on is not
    // obvious: a session reaches `open` inside apply, while the settle runs
    // just after it, so an open fact emitted between the two would carry the
    // preference. Both sessions here are opened by one host that prefers
    // `next` over Cap'n Proto, and only one partner can follow it.
    const allocator = std.testing.allocator;
    var native_opts = Host.Options.withFrameCap(frame_cap);
    native_opts.codec = .capnp;
    native_opts.captp_version = .next;

    var hub = test_host.init(allocator, [_]u8{0x6a} ** 32, native_opts);
    defer hub.deinit();
    var native_peer = test_host.init(allocator, [_]u8{0x6b} ** 32, native_opts);
    defer native_peer.deinit();
    var baseline_peer = test_host.init(allocator, [_]u8{0x6c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer baseline_peer.deinit();

    var hub_log = TraceLog{};
    hub.setTrace(.{ .ctx = &hub_log, .emit = TraceLog.emit });

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const native = try openPair(allocator, &hub, &native_peer, "127.0.0.1:7013", &dials);
    const baseline = try openPair(allocator, &hub, &baseline_peer, "127.0.0.1:7014", &dials);
    try pumpToQuiescence(allocator, &.{ &hub, &native_peer, &baseline_peer }, &.{ native, baseline }, &dials);

    // The open fact is emitted the first time a session is *observed* open,
    // which is its first traffic rather than the handshake itself, so an idle
    // session contributes no row. One fetch each is enough to observe both.
    _ = try native.b.served.publish(&native.b.host.vat, "widget", Widget, .{});
    _ = try baseline.b.served.publish(&baseline.b.host.vat, "widget", Widget, .{});
    _ = try hub.fetch(native.a, "widget");
    _ = try hub.fetch(baseline.a, "widget");
    try pumpToQuiescence(allocator, &.{ &hub, &native_peer, &baseline_peer }, &.{ native, baseline }, &dials);

    // One host, two opens, two different profiles on the wire.
    try std.testing.expect(hub_log.contains("open codec=capnp captp=next"));
    try std.testing.expect(hub_log.contains("open codec=syrup captp=v1_0"));
}

test "core host: both peers of one session report the same wire name" {
    // The name a consumer merges two producers' feeds on. A session id is
    // host-local — every host starts counting at one — so two peers tracing
    // the same conversation say nothing to each other by it. The wire name is
    // the OCapN session identifier, derived from both session public keys with
    // the pair sorted, so the dialer and the accepter compute the same digits
    // and a viewer can tell one wire watched twice from two wires.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x71} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x72} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var third = test_host.init(allocator, [_]u8{0x73} ** 32, Host.Options.withFrameCap(frame_cap));
    defer third.deinit();

    var client_log = TraceLog{};
    var server_log = TraceLog{};
    var third_log = TraceLog{};
    client.setTrace(.{ .ctx = &client_log, .emit = TraceLog.emit });
    server.setTrace(.{ .ctx = &server_log, .emit = TraceLog.emit });
    third.setTrace(.{ .ctx = &third_log, .emit = TraceLog.emit });

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7031", &dials);
    const other = try openPair(allocator, &client, &third, "127.0.0.1:7032", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try other.b.served.publish(&other.b.host.vat, "widget", Widget, .{});
    _ = try client.fetch(pair.a, "widget");
    _ = try client.fetch(other.a, "widget");
    try pumpToQuiescence(allocator, &.{ &client, &server, &third }, &.{ pair, other }, &dials);

    // The dialer saw both sessions; each accepter saw its own. Every accepter's
    // name is one the dialer also reported, which is the whole claim: two
    // producers watching one session say the same word for it.
    try std.testing.expectEqual(@as(usize, 2), client_log.wire_n);
    try std.testing.expect(client_log.sawWire(server_log.onlyWire()));
    try std.testing.expect(client_log.sawWire(third_log.onlyWire()));
    // Two sessions are two names, or election would fold unrelated wires.
    try std.testing.expect(!std.mem.eql(u8, server_log.onlyWire(), third_log.onlyWire()));
    try std.testing.expectEqual(@as(usize, 64), server_log.onlyWire().len);
    for (server_log.onlyWire()) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }
}

test "core host: a three-vat handoff holds native between the pancake pair and baseline with the third" {
    // The cast `apps/ocapnviz/src/fixtures/three-vat-handoff-mixed.ts` draws:
    // a pancake gifter introduces a peer that speaks only the v1.0 Syrup
    // baseline — a Goblins vat's profile — to a pancake exporter. Three
    // sessions, and the profile each runs on is a property of its pair:
    // gifter-to-exporter is native because both ends can be, and both of the
    // recipient's sessions are the baseline because it cannot.
    //
    // The handoff itself has to survive that split, and this is the case
    // `codec.signed` exists for: a give is minted on one session and redeemed
    // on another that negotiated independently, so its signed envelope is
    // Syrup whatever each session settled.
    const allocator = std.testing.allocator;
    var native_opts = Host.Options.withFrameCap(frame_cap);
    native_opts.codec = .capnp;
    native_opts.captp_version = .next;

    var exporter = test_host.init(allocator, [_]u8{0x7e} ** 32, native_opts);
    defer exporter.deinit();
    var gifter = test_host.init(allocator, [_]u8{0x76} ** 32, native_opts);
    defer gifter.deinit();
    // The Goblins-shaped peer: it knows only the baseline.
    var recipient = test_host.init(allocator, [_]u8{0x7c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();

    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var row_freed = false;
    var row = TaggedRow{ .tag = "greeter", .freed = &row_freed };
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &row });

    // Gifter to exporter: both prefer native, so the session is native.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7021", &dials);
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();

    // Recipient to gifter: the recipient can only do the baseline.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7022", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    const introduce_vow = try recipient.send(r_to_g.a, introducer_ref, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    // The redeem dial: two pancake hosts on the wire, but the recipient still
    // cannot do native, so this session settles on the baseline too.
    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7021", &.{});
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(r_to_e.sessionOpen());
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // The handoff completed across the profile split.
    const token_ref = try redeemed.require();
    try std.testing.expect(token_ref == .far);
    const reached = try recipient.send(r_to_g.a, token_ref, .{ .verb = "tag", .args = &.{} });
    var tag = CapturedString{};
    try recipient.vowOn(reached, .{ .ctx = &tag, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("greeter", tag.buf[0..tag.len]);

    // Each session runs the profile its own pair could reach.
    const pancake_pair = &g_to_e.a.served.port.peer.session_state;
    try std.testing.expectEqual(model.CaptpVersion.next, pancake_pair.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, pancake_pair.codec);

    inline for (.{ r_to_g.a, r_to_e }) |with_recipient| {
        const state = &with_recipient.served.port.peer.session_state;
        try std.testing.expectEqual(model.CaptpVersion.v1_0, state.captp_version);
        try std.testing.expectEqual(model.CodecId.syrup, state.codec);
    }

    // The exporter asked for native on every session it holds and got it on
    // one of the two. That difference is the point.
    try std.testing.expectEqual(
        model.CaptpVersion.next,
        e_accepts_r.served.port.peer.session_state.preferred.captp_version,
    );
    try std.testing.expectEqual(
        model.CaptpVersion.v1_0,
        e_accepts_r.served.port.peer.session_state.captp_version,
    );
}

test "core host: both ends of a wire tag one message identically" {
    // The property the whole merge rests on. A frame crosses one wire, so the
    // sender and the receiver hold the same bytes and derive the same tag
    // with no coordination — which is what lets a consumer recognise two
    // observers' records as one message instead of drawing it twice, and why
    // the endpoint need not pick a winner and throw the other view away.
    //
    // Derived, not claimed: a producer cannot assert that some other message
    // is this one without holding its bytes.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x8a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x8b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();

    var client_log = DigestLog{};
    var server_log = DigestLog{};
    client.setTrace(.{ .ctx = &client_log, .emit = DigestLog.emit });
    server.setTrace(.{ .ctx = &server_log, .emit = DigestLog.emit });

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7030", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget = try fetched.require();
    var reply = CapturedString{};
    try client.vowOn(
        try client.send(pair.a, widget, .{ .verb = "poke", .args = &.{} }),
        .{ .ctx = &reply, .func = CapturedString.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // The dialer sent `poke` outbound; the acceptor saw the same frame
    // inbound. Two records of one message, and the tags agree.
    const sent = client_log.find("poke", true) orelse return error.NoOutboundPoke;
    const heard = server_log.find("poke", false) orelse return error.NoInboundPoke;
    try std.testing.expectEqualSlices(u8, &sent, &heard);

    // And the tag must cover the frame, not something coarser that happens to
    // agree across ends. Two sends of the SAME verb carrying different
    // arguments are different messages, and a tag over the verb alone — which
    // both ends would also agree on — cannot tell them apart.
    var second = CapturedString{};
    try client.vowOn(
        try client.send(pair.a, widget, .{ .verb = "poke", .args = &.{.{ .string = "again" }} }),
        .{ .ctx = &second, .func = CapturedString.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const both = client_log.bothOutbound("poke") orelse return error.OnlyOnePoke;
    try std.testing.expect(!std.mem.eql(u8, &both[0], &both[1]));
}
