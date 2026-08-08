const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const core = pancake.driver.core;
const actors = pancake.actors;
const host_pair = @import("../support/host_pair.zig");
const CapturedRef = @import("../support/capture.zig").CapturedRef;
const publishAndOpenAccepted = host_pair.publishAndOpenAccepted;

const LocalActor = struct {
    pub fn handle(_: *LocalActor, _: *actors.Turn, _: actors.Message) !model.Argument {
        return .{ .void = {} };
    }
};

const Vendor = struct {
    offered: model.Reference,

    pub fn handle(self: *Vendor, _: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "make")) return error.NoSuchMethod;
        return .{ .reference = self.offered };
    }
};

const LiftCapture = struct {
    ref: ?core.Capability = null,
    position: ?u64 = null,
};

const LiftSink = struct {
    host: *core.Host,
    session: *core.HostSession,
    capture: *LiftCapture,

    pub fn handle(self: *LiftSink, _: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "take") or msg.args.len != 1 or msg.args[0] != .reference)
            return error.BadArguments;
        const reference = msg.args[0].reference;
        if (reference != .far) return error.BadArguments;
        self.capture.position = reference.far.import_position.int();
        self.capture.ref = try self.host.liftCapability(self.session, reference);
        return .{ .void = {} };
    }
};

test "Host lift keeps equal import positions scoped to their owning sessions" {
    var host = core.Host.init(std.testing.allocator, [_]u8{0x41} ** 32, .{});
    defer host.deinit();
    const a = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9101", &.{});
    const b = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9102", &.{});
    try a.served.port.peer.importObject(7);
    try b.served.port.peer.importObject(7);

    const a_ref = try host.liftCapability(a, .{ .far = model.FarRef.object(7) });
    const b_ref = try host.liftCapability(b, .{ .far = model.FarRef.object(7) });
    try std.testing.expect(!a_ref.eql(b_ref));
    try std.testing.expectEqual(model.Reference{ .far = model.FarRef.object(7) }, try host.lowerCapability(a, a_ref));
    try std.testing.expectEqual(model.Reference{ .far = model.FarRef.object(7) }, try host.lowerCapability(b, b_ref));
    const projected = try host.lowerCapability(b, a_ref);
    try std.testing.expect(projected == .far);
    try std.testing.expect(model.ImportName.classify(projected.far.import_position.int()) == .token);
}

test "Host local capability identity survives Port closure and reprojects lazily" {
    var host = core.Host.init(std.testing.allocator, [_]u8{0x42} ** 32, .{});
    defer host.deinit();
    const owner = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9201", &.{});
    const survivor = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9202", &.{});
    const owner_cap = try owner.served.publish(&owner.host.vat, "local", LocalActor, .{});
    const survivor_cap = try survivor.served.publish(&survivor.host.vat, "local", LocalActor, .{});

    const owner_ref = try host.liftCapability(owner, owner_cap.nearRef());
    const survivor_ref = try host.liftCapability(survivor, survivor_cap.nearRef());
    try std.testing.expect(!owner_ref.eql(survivor_ref));
    try std.testing.expectEqual(owner_cap.nearRef(), try host.lowerCapability(owner, owner_ref));
    try host.releaseSession(owner);

    const projected = try host.lowerCapability(survivor, owner_ref);
    try std.testing.expect(projected == .near);
    try std.testing.expectEqual(projected, try host.lowerCapability(survivor, owner_ref));
    try std.testing.expectEqual(owner_ref, try host.liftCapability(survivor, projected));
    try std.testing.expectEqual(survivor_cap.nearRef(), try host.lowerCapability(survivor, survivor_ref));

    try host.releaseSession(survivor);
    const replacement = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9203", &.{});
    const reprojected = try host.lowerCapability(replacement, owner_ref);
    try std.testing.expect(reprojected == .near);
    try std.testing.expectEqual(owner_ref, try host.liftCapability(replacement, reprojected));
}

test "reserved fresh local capability lift cannot allocate after publication" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = core.Host.init(failing.allocator(), [_]u8{0x4b} ** 32, .{});
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9251", &.{});

    // The C publish/spawn boundary reserves identity storage before it makes
    // the actor or bootstrap mapping observable.
    try host.reserveFreshCapability(session);
    const cap = try session.served.publish(&session.host.vat, "local", LocalActor, .{});

    const before = failing.alloc_index;
    failing.fail_index = before;
    const ref = try host.liftCapability(session, cap.nearRef());
    try std.testing.expectEqual(before, failing.alloc_index);
    try std.testing.expectEqual(cap.nearRef(), try host.lowerCapability(session, ref));
    failing.fail_index = std.math.maxInt(usize);
}

test "failed projection rolls back a lift with an exact wire release" {
    var host = core.Host.init(std.testing.allocator, [_]u8{0x4c} ** 32, .{});
    defer host.deinit();
    var partner = core.Host.init(std.testing.allocator, [_]u8{0x4d} ** 32, .{});
    defer partner.deinit();
    const pair = try host_pair.openPair(&host, &partner, "127.0.0.1:9252");
    const session = pair.a;
    try session.served.port.peer.importObject(7);

    const lifted = try host.liftCapabilityTracked(session, .{ .far = model.FarRef.object(7) });
    try std.testing.expect(lifted.claimed_wire_retain);
    try std.testing.expectEqual(@as(usize, 1), host.capabilities.liveCount());
    host.rollbackCapabilityLift(lifted);

    try std.testing.expectEqual(@as(usize, 0), host.capabilities.liveCount());
    try std.testing.expect(!session.served.port.peer.session_state.hasImport(.from(7)));
    try std.testing.expectEqual(@as(?u64, null), session.served.port.peer.session_state.hostCapabilityFor(.from(7)));

    try session.served.port.peer.importObject(7);
    const retried = try host.liftCapabilityTracked(session, .{ .far = model.FarRef.object(7) });
    try std.testing.expect(retried.claimed_wire_retain);
    try std.testing.expectError(error.UnknownCapability, host.lowerCapability(session, lifted.ref));
    try std.testing.expectEqual(model.Reference{ .far = model.FarRef.object(7) }, try host.lowerCapability(session, retried.ref));
}

test "repeated lift is canonical and partial then final release tracks wire retains" {
    var host = core.Host.init(std.testing.allocator, [_]u8{0x43} ** 32, .{});
    defer host.deinit();
    var partner = core.Host.init(std.testing.allocator, [_]u8{0x44} ** 32, .{});
    defer partner.deinit();
    const pair = try host_pair.openPair(&host, &partner, "127.0.0.1:9301");
    const session = pair.a;
    try session.served.port.peer.importObject(7);
    try session.served.port.peer.importObject(7);
    const first = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    const repeated = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    try std.testing.expectEqual(first, repeated);
    try std.testing.expectError(error.ImportLifted, host.releaseImport(session, 7, 1));

    try host.releaseCapability(first, 1);
    try std.testing.expect(session.served.port.peer.session_state.hasImport(.from(7)));
    try std.testing.expectEqual(model.Reference{ .far = model.FarRef.object(7) }, try host.lowerCapability(session, first));
    try host.releaseCapability(first, 1);
    try std.testing.expect(!session.served.port.peer.session_state.hasImport(.from(7)));
    try std.testing.expectError(error.UnknownCapability, host.lowerCapability(session, first));
    try std.testing.expectError(error.UnknownCapability, host.releaseCapability(first, 1));
}

test "repeated lift reuses identity without inventing a wire retain" {
    var host = core.Host.init(std.testing.allocator, [_]u8{0x45} ** 32, .{});
    defer host.deinit();
    var partner = core.Host.init(std.testing.allocator, [_]u8{0x46} ** 32, .{});
    defer partner.deinit();
    const pair = try host_pair.openPair(&host, &partner, "127.0.0.1:9401");
    const session = pair.a;

    try session.served.port.peer.importObject(7);
    const stale = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    const alias = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    try std.testing.expectEqual(stale, alias);
    try std.testing.expectEqual(@as(u64, 1), session.served.port.peer.session_state.importRefcount(.from(7)));
    try host.releaseCapability(stale, 1);
    try std.testing.expect(session.served.port.peer.session_state.hasImport(.from(7)));
    try std.testing.expectEqual(model.Reference{ .far = model.FarRef.object(7) }, try host.lowerCapability(session, alias));
    try host.releaseCapability(alias, 1);
    try std.testing.expect(!session.served.port.peer.session_state.hasImport(.from(7)));
    try session.served.port.peer.importObject(7);
    const replacement = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });

    try std.testing.expect(!stale.eql(replacement));
    try std.testing.expectError(error.UnknownCapability, host.lowerCapability(session, stale));
    try std.testing.expectEqual(model.Reference{ .far = model.FarRef.object(7) }, try host.lowerCapability(session, replacement));
}

test "bootstrap without an import row cannot become a retained Host capability" {
    var host = core.Host.init(std.testing.allocator, [_]u8{0x4b} ** 32, .{});
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9451", &.{});
    try std.testing.expectError(
        error.ForeignArgument,
        host.liftCapability(session, .{ .far = model.FarRef.object(0) }),
    );
}

test "reclaimed Host slot receives a new public id before reuse" {
    var host = core.Host.init(std.testing.allocator, [_]u8{0x47} ** 32, .{});
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9501", &.{});
    const first_cap = try session.served.publish(&session.host.vat, "first", LocalActor, .{});
    const stale = try host.liftCapability(session, first_cap.nearRef());
    try host.releaseCapability(stale, 1);

    const second_cap = try session.served.publish(&session.host.vat, "second", LocalActor, .{});
    const replacement = try host.liftCapability(session, second_cap.nearRef());
    try std.testing.expect(!stale.eql(replacement));
    try std.testing.expectError(error.UnknownCapability, host.lowerCapability(session, stale));
    try std.testing.expectEqual(second_cap.nearRef(), try host.lowerCapability(session, replacement));
}

test "Host capability verbs refuse a session owned by another Host" {
    var a = core.Host.init(std.testing.allocator, [_]u8{0x48} ** 32, .{});
    defer a.deinit();
    var b = core.Host.init(std.testing.allocator, [_]u8{0x49} ** 32, .{});
    defer b.deinit();
    const a_session = try publishAndOpenAccepted(&a, "tcp", "127.0.0.1:9601", &.{});
    const b_session = try publishAndOpenAccepted(&b, "tcp", "127.0.0.1:9602", &.{});
    try a_session.served.port.peer.importObject(7);
    try b_session.served.port.peer.importObject(7);
    const ref = try a.liftCapability(a_session, .{ .far = model.FarRef.object(7) });
    const b_ref = try b.liftCapability(b_session, .{ .far = model.FarRef.object(7) });
    // Native refs carry the Registry pointer as their scope proof, so two core
    // Hosts may use the same local scalar without aliasing. The C adapter's
    // process-wide keyed issuer separates opaque ABI-visible scalars across
    // live and retired Hosts; its boundary test lives in c_abi/host_test.zig.
    try std.testing.expectEqual(ref.raw(), b_ref.raw());

    try std.testing.expectError(error.ForeignSession, a.liftCapability(b_session, .{ .far = model.FarRef.object(7) }));
    try std.testing.expectError(error.ForeignSession, a.lowerCapability(b_session, ref));
    try std.testing.expectError(error.UnknownCapability, b.lowerCapability(b_session, ref));
    try std.testing.expectError(error.ForeignSession, a.flushSession(b_session));
    try std.testing.expectError(error.ForeignSession, a.feedBytes(b_session, &.{}));
    try std.testing.expectError(error.ForeignSession, a.releaseSession(b_session));
}

test "ordinary replies and delivered arguments lift canonically under their owning sessions" {
    var client = core.Host.init(std.testing.allocator, [_]u8{0x50} ** 32, .{});
    defer client.deinit();
    var exporter_a = core.Host.init(std.testing.allocator, [_]u8{0x51} ** 32, .{});
    defer exporter_a.deinit();
    var exporter_b = core.Host.init(std.testing.allocator, [_]u8{0x52} ** 32, .{});
    defer exporter_b.deinit();
    const a = try host_pair.openPair(&client, &exporter_a, "127.0.0.1:9651");
    const b = try host_pair.openPair(&client, &exporter_b, "127.0.0.1:9652");
    const pairs = [_]host_pair.Pair{ a, b };

    const widget_a = try a.b.served.publish(&a.b.host.vat, "widget", LocalActor, .{});
    const widget_b = try b.b.served.publish(&b.b.host.vat, "widget", LocalActor, .{});
    _ = try a.b.served.publish(&a.b.host.vat, "vendor", Vendor, .{ .offered = widget_a.nearRef() });
    _ = try b.b.served.publish(&b.b.host.vat, "vendor", Vendor, .{ .offered = widget_b.nearRef() });

    var vendor_a = CapturedRef{};
    var vendor_b = CapturedRef{};
    try client.vowOn(try client.fetch(a.a, "vendor"), .{ .ctx = &vendor_a, .func = CapturedRef.record });
    try client.vowOn(try client.fetch(b.a, "vendor"), .{ .ctx = &vendor_b, .func = CapturedRef.record });
    try host_pair.pumpToQuiescence(&pairs);

    var reply_a = CapturedRef{};
    var reply_b = CapturedRef{};
    try client.vowOn(try client.send(a.a, try vendor_a.require(), .{ .verb = "make" }), .{ .ctx = &reply_a, .func = CapturedRef.record });
    try client.vowOn(try client.send(b.a, try vendor_b.require(), .{ .verb = "make" }), .{ .ctx = &reply_b, .func = CapturedRef.record });
    try host_pair.pumpToQuiescence(&pairs);
    const reply_wire_a = try reply_a.require();
    const reply_wire_b = try reply_b.require();
    const reply_ref_a = try client.liftCapability(a.a, reply_wire_a);
    const reply_ref_b = try client.liftCapability(b.a, reply_wire_b);
    try std.testing.expect(!reply_ref_a.eql(reply_ref_b));

    var arg_a: LiftCapture = .{};
    var arg_b: LiftCapture = .{};
    _ = try a.a.served.publish(&a.a.host.vat, "sink", LiftSink, .{ .host = &client, .session = a.a, .capture = &arg_a });
    _ = try b.a.served.publish(&b.a.host.vat, "sink", LiftSink, .{ .host = &client, .session = b.a, .capture = &arg_b });
    var sink_a = CapturedRef{};
    var sink_b = CapturedRef{};
    try exporter_a.vowOn(try exporter_a.fetch(a.b, "sink"), .{ .ctx = &sink_a, .func = CapturedRef.record });
    try exporter_b.vowOn(try exporter_b.fetch(b.b, "sink"), .{ .ctx = &sink_b, .func = CapturedRef.record });
    try host_pair.pumpToQuiescence(&pairs);
    try exporter_a.tell(a.b, try sink_a.require(), .{ .verb = "take", .args = &.{.{ .reference = widget_a.nearRef() }} });
    try exporter_b.tell(b.b, try sink_b.require(), .{ .verb = "take", .args = &.{.{ .reference = widget_b.nearRef() }} });
    try host_pair.pumpToQuiescence(&pairs);

    try std.testing.expectEqual(reply_wire_a.far.import_position.int(), arg_a.position.?);
    try std.testing.expectEqual(reply_wire_b.far.import_position.int(), arg_b.position.?);
    try std.testing.expect(arg_a.ref.?.eql(reply_ref_a));
    try std.testing.expect(arg_b.ref.?.eql(reply_ref_b));
}

test "first remote lift pays bounded indexes and repeated lift allocates nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = core.Host.init(failing.allocator(), [_]u8{0x4a} ** 32, .{});
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9701", &.{});
    try session.served.port.peer.importObject(7);
    try session.served.port.peer.importObject(7);

    const before = failing.alloc_index;
    const first = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    // Host reverse index, id index, peer-head index, slot storage, import
    // identity map owner, and that map's first backing allocation.
    try std.testing.expectEqual(@as(usize, 6), failing.alloc_index - before);

    failing.fail_index = failing.alloc_index;
    const repeated = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    try std.testing.expectEqual(first, repeated);
    _ = try host.lowerCapability(session, first);
    failing.fail_index = std.math.maxInt(usize);
}
