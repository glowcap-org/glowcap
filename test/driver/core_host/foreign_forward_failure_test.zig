//! Wire reply admission under allocation refusal. The destination reply is
//! already an engine Event before the failing Host allocation window opens.
const std = @import("std");
const glowcap = @import("glowcap");
const core = glowcap.driver.core;
const model = glowcap.ocapn.model;
const support = @import("../../support/core_host.zig");
const h = @import("harness.zig");
const a = std.testing.allocator;
const Shape = enum { nested, root };

const Leaf = struct {
    pub fn handle(_: *Leaf, turn: *core.HostTurn, _: ?[]const u8, args: core.Args) !core.Value {
        defer turn.releaseArguments(args);
        return .{ .integer = 17 };
    }
};

const Reply = struct {
    values: [2]core.Value,
    calls: *usize,
    shape: Shape,
    pub fn handle(self: *Reply, turn: *core.HostTurn, _: ?[]const u8, args: core.Args) !core.Value {
        defer turn.releaseArguments(args);
        self.calls.* += 1;
        return if (self.shape == .root) self.values[1] else .{ .list = &self.values };
    }
};

const Hop = struct {
    target: core.Capability,
    pub fn handle(self: *Hop, turn: *core.HostTurn, verb: ?[]const u8, args: core.Args) !core.Value {
        defer turn.releaseArguments(args);
        return turn.forward(self.target, verb, try args.values());
    }
};

const Result = struct {
    callbacks: usize = 0,
    returned: ?model.FarRef = null,
    broken: bool = false,
    malformed: bool = false,

    fn record(ctx: ?*anyopaque, resolution: glowcap.actors.Resolution) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.callbacks += 1;
        switch (resolution) {
            .broken => self.broken = true,
            .give => self.malformed = true,
            .fulfilled => |value| {
                if (value != .list or value.list.len != 2 or
                    value.list[0] != .reference or value.list[0].reference != .far or
                    value.list[1] != .handoff or value.list[1].handoff.* != .give)
                {
                    self.malformed = true;
                    return;
                }
                // A raw observer consumes the nested give as data; redemption
                // is independent of the reply admission measured here.
                self.returned = value.list[0].reference.far;
            },
        }
    }
};

fn spawn(host: *core.Host, comptime B: type, initial: B) !core.Capability {
    const reservation = try host.reserveFreshCapability(null);
    const actor = try host.vat.spawn(core.Hosting(B), .{ .inner = initial });
    return host.adoptReservedLocalCapability(reservation, actor);
}

fn fetch(host: *core.Host, pair: h.Pair, swiss: []const u8, dials: *std.ArrayList(h.ParkedDial)) !core.Capability {
    var found: h.CapturedRef = .{};
    try host.vowOn(try host.fetch(pair.a, swiss), .{ .ctx = &found, .func = h.CapturedRef.record });
    try h.pumpToQuiescence(a, &.{ pair.ah, pair.bh }, &.{pair}, dials);
    return host.liftCapability(pair.a, try found.require());
}

/// Leave root replies unconsumed so the receiving Host cannot redeem a give.
/// It may still release the original answer through its public vow owner.
fn rootDrive(source: h.Pair, destination: h.Pair, dials: *std.ArrayList(h.ParkedDial)) !void {
    _ = try source.ah.flushHeldReleases();
    while (try source.a.takeOutbound()) |value| {
        var frame = value;
        defer frame.deinit();
        if (source.b.sessionOpen()) try source.bh.feed(source.b, frame.view());
    }
    try h.pumpToQuiescence(a, &.{ destination.ah, destination.bh }, &.{destination}, dials);
    while (try source.b.takeOutbound()) |value| {
        var frame = value;
        frame.deinit();
    }
}

test "core host wire forwarding reply allocation refusals retire projection receipts and completion owners" {
    try sweep(.nested);
}

test "core host wire forwarding root allocation refusals retire private actors and canonical targets" {
    try sweep(.root);
}

fn sweep(shape: Shape) !void {
    for (0..192) |index| if (!try run(shape, index)) return;
    return error.AllocationSweepDidNotComplete;
}

fn run(shape: Shape, failure_index: usize) !bool {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var client = support.init(a, @splat(0xC1), h.nextRouteOptions());
    defer client.deinit();
    var middle = support.init(failing.allocator(), @splat(0xC2), h.nextRouteOptions());
    defer middle.deinit();
    var exporter = support.init(a, @splat(0xC3), h.nextRouteOptions());
    defer exporter.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer h.deinitParked(a, &dials);
    const destination = try h.openPair(a, &middle, &exporter, "127.0.0.1:7971", &dials);
    const source = try h.openPair(a, &client, &middle, "127.0.0.1:7972", &dials);
    const hosts = [_]*core.Host{ &client, &middle, &exporter };
    const pairs = [_]h.Pair{ source, destination };

    // A near reply needs a fresh source Port export receipt. Its sibling is
    // a fresh foreign observation needing a wire lift, route and staging lease.
    const local = try middle.sessionPublish(destination.a, "back", core.Hosting(Leaf), .{ .inner = .{} });
    defer middle.releaseCapabilityTerminal(local, null);
    const local_actor = middle.capabilities.resolve(local).?.local;
    const reversed = h.Pair{ .ah = &exporter, .a = destination.b, .bh = &middle, .b = destination.a };
    const back = try fetch(&exporter, reversed, "back", &dials);
    defer exporter.releaseCapabilityTerminal(back, null);
    const gifted = try spawn(&exporter, Leaf, .{});
    defer exporter.releaseCapabilityTerminal(gifted, null);
    var calls: usize = 0;
    const returning = try spawn(&exporter, Reply, .{
        .values = .{ .{ .capability = back }, .{ .capability = gifted } },
        .calls = &calls,
        .shape = shape,
    });
    defer exporter.releaseCapabilityTerminal(returning, null);
    const returning_name = try exporter.publishDurableCapability(@splat(0x82), returning);
    const imported = try fetch(&middle, destination, returning_name.slice(), &dials);
    defer middle.releaseCapabilityTerminal(imported, null);
    const hop = try spawn(&middle, Hop, .{ .target = imported });
    defer middle.releaseCapabilityTerminal(hop, null);
    const hop_name = try middle.publishDurableCapability(@splat(0x83), hop);
    const remote = try fetch(&client, source, hop_name.slice(), &dials);
    defer client.releaseCapabilityTerminal(remote, null);
    const registry_count = middle.capabilities.by_id.count();
    const source_exports = source.b.served.port.exports.count();
    const actor_roots = middle.vat.actors.get(local_actor).?.roots;
    const local_retains = middle.capabilities.retainCount(local).?;
    const boundary = try middle.vat.spawn(h.Widget, .{});
    defer middle.vat.releaseActor(boundary.local);

    var result: Result = .{};
    const vow = try client.sendValues(source.a, remote, "reply", &.{}, a);
    if (shape == .nested) try client.vowOn(vow, .{ .ctx = &result, .func = Result.record });
    _ = try h.shuttle(source);
    while (try destination.a.takeOutbound()) |outbound| {
        var frame = outbound;
        defer frame.deinit();
        try exporter.feed(destination.b, frame.view());
    }
    while (try destination.b.takeOutbound()) |frame|
        try destination.a.served.port.peer.feedOwned(frame);
    try destination.a.served.port.peer.stepToIdle();
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 1), middle.vows.count());

    // Pop the batch first: serving an event can drain its queued siblings.
    var events: std.ArrayList(glowcap.ocapn.engine.Event) = .empty;
    defer {
        for (events.items) |*event| event.deinit();
        events.deinit(a);
    }
    while (destination.a.served.port.peer.pollEvent()) |event| try events.append(a, event);
    var reply: ?*glowcap.ocapn.engine.Event = null;
    for (events.items) |*event| {
        if (event.kind() == .resolve) {
            if (reply != null) return error.ExtraReply;
            reply = event;
        } else try middle.serveEvent(destination.a, event);
    }
    const event = reply orelse return error.MissingReply;
    const value = event.view().resolve.resolution.fulfill;
    const foreign = (if (shape == .root) value else try value.list.at(1)).reference.far.import_position;
    const state = &destination.a.served.port.peer.session_state;
    try std.testing.expectEqual(@as(u64, 1), state.importRefcount(foreign));
    try std.testing.expect(state.hostImportIdentity(foreign) == null);
    failing.fail_index = failing.alloc_index + failure_index;
    const served = middle.serveEvent(destination.a, event);
    const induced = failing.has_induced_failure;
    failing.fail_index = std.math.maxInt(usize);
    try served;

    if (shape == .root) {
        try rootDrive(source, destination, &dials);
        var pipelines: usize = 0;
        var answers = source.b.served.port.peer.session_state.inbound_answers.rows.valueIterator();
        while (answers.next()) |row| if (row.payload) |payload| if (payload.pipeline_target) |target| {
            pipelines += 1;
            const actor_id = source.b.served.port.exports.get(target.near.export_position.int()).?;
            try std.testing.expectEqual(@as(u32, 1), middle.vat.actors.get(actor_id).?.roots);
            const canonical = middle.capabilities.refForRaw(state.hostImportIdentity(foreign).?.ref).?;
            try std.testing.expectEqual(@as(?u64, 1), middle.capabilities.retainCount(canonical));
        };
        if (!induced) try std.testing.expectEqual(@as(usize, 1), pipelines);
        try client.vowRelease(vow);
        try rootDrive(source, destination, &dials);
    } else {
        try h.pumpToQuiescence(a, &hosts, &pairs, &dials);
        // Exhaustion can also prevent encoding an abort. The simulated
        // transport must deliver the actual CLOSE action as physical loss.
        // An active source with an abandoned answer cannot take this path.
        if (result.callbacks == 0 and middle.sessionCloseActionDelivered(source.b)) {
            try client.transportClosed(source.a, "middle closed the forwarding session");
            while (try h.drainActions(a, &.{&client}, &dials)) {}
        }
        try std.testing.expectEqual(@as(usize, 1), result.callbacks);
        try std.testing.expect(!result.malformed);
        try std.testing.expect(result.broken or result.returned != null);
        if (!induced) try std.testing.expect(result.returned != null);
        if (result.returned) |returned| {
            try source.a.served.port.peer.sendBorrowed(.{ .gc_export = .{
                .positions = &.{returned.import_position.int()},
                .deltas = &.{1},
            } });
            try source.a.served.port.peer.stepToIdle();
            try h.pumpToQuiescence(a, &hosts, &pairs, &dials);
        }
    }
    // Destructors for retired actor boxes run at an outermost turn boundary.
    _ = try middle.vat.near(boundary, .{ .verb = "poke", .args = &.{} });
    // Feed cleanup GC to the actual exporter too: a locally balanced count
    // must not conceal an invented release rejected by the partner.
    try h.pumpToQuiescence(a, &.{ &middle, &exporter }, &.{destination}, &dials);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
    try std.testing.expectEqual(@as(usize, 0), middle.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), middle.pendingVowCount());
    try std.testing.expectEqual(@as(usize, 0), middle.vows.count());
    try std.testing.expectEqual(@as(usize, 0), destination.a.served.port.far_listeners.count());
    try std.testing.expectEqual(@as(usize, 0), middle.node.pendingGiftEffects());
    if (result.returned) |returned| {
        // A committed ordinary export keeps its Port binding for reuse after
        // wire GC. It is exactly one root, released by that Port's teardown.
        try std.testing.expectEqual(source_exports + 1, source.b.served.port.exports.count());
        try std.testing.expectEqual(@as(u64, 0), source.b.served.port.peer.session_state.exports.wireHeld(.from(returned.import_position.int())));
        try middle.releaseSession(source.b);
    } else if (source.b.sessionOpen()) {
        try std.testing.expectEqual(source_exports, source.b.served.port.exports.count());
    } else try middle.releaseSession(source.b);
    const home_closed = !destination.a.sessionOpen();
    if (home_closed) {
        // A condemned home owns wire observations whose cleanup could not
        // allocate. Teardown must retire them, never fabricate extra GC.
        try middle.releaseSession(destination.a);
    } else {
        try std.testing.expect(!state.holdsImport(foreign));
        try std.testing.expect(state.hostImportIdentity(foreign) == null);
    }
    try std.testing.expectEqual(registry_count, middle.capabilities.by_id.count());
    try std.testing.expectEqual(@as(?u64, local_retains), middle.capabilities.retainCount(local));
    try std.testing.expectEqual(actor_roots - @as(u32, if (home_closed) 1 else 0), middle.vat.actors.get(local_actor).?.roots);
    return induced;
}
