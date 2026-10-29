//! Owned enlivenment shares cached, wire and parked producer paths.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("harness.zig");
const test_host = @import("../../support/core_host.zig");
const Host = glowcap.driver.core.Host;
const a = std.testing.allocator;

extern fn glowcap_test_archive_enliven(host: *Host) ?*glowcap.driver.core.Host.Enliven;
extern fn glowcap_test_archive_call(host: *Host, session: *glowcap.driver.core.HostSession, target: *const glowcap.driver.core.Capability) ?*glowcap.driver.core.Host.Call;
extern fn glowcap_test_archive_send(host: *Host, target: *const glowcap.driver.core.Capability) u64;
extern fn glowcap_test_archive_forward(turn: *glowcap.actors.Turn, vow: *const glowcap.actors.Vow) bool;

test "core host: pending forwarding from independently compiled archives retires at teardown" {
    for ([_]enum { local, far }{ .local, .far }) |location| {
        var peers = try glowcap.ocapn.engine.pairing.paired(a);
        defer peers.deinit();
        var vat = glowcap.actors.Vat.init(a);
        defer vat.deinit();
        var port = glowcap.actors.Port.init(a, &peers.p1);
        defer port.deinit(&vat);
        const source = switch (location) {
            .local => (try vat.spawnVow()).vow,
            .far => blk: {
                try peers.p1.importObject(5);
                break :blk try port.send(&vat, .{ .far = glowcap.ocapn.model.FarRef.object(5) }, .{ .verb = "poke" });
            },
        };
        const Forwarder = struct {
            source: glowcap.actors.Vow,
            forwarded: *bool,
            pub fn handle(self: *@This(), turn: *glowcap.actors.Turn, _: glowcap.actors.Delivery) !glowcap.ocapn.model.Argument {
                if (!glowcap_test_archive_forward(turn, &self.source)) return error.ForeignAdmissionFailed;
                self.forwarded.* = turn.forwarded;
                return .{ .void = {} };
            }
        };
        var forwarded = false;
        const actor = try vat.spawn(Forwarder, .{ .source = source, .forwarded = &forwarded });
        const result = try port.send(&vat, actor, .{ .verb = "forward" });
        try vat.drive();
        try std.testing.expect(forwarded);
        try std.testing.expect(vat.pending_local_vows.contains(.{ .id = result.local }));
        // The allocator proves that both Vat and Port teardown recognize and
        // free the foreign image's context even though its vow never settles.
    }
}

test "core host: owned observations cancel across independently compiled archives" {
    var client = test_host.init(a, @splat(0x49), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x50), Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7911", &dials);
    _ = try pair.b.served.publish(&server.vat, "widget", h.Widget, .{});
    const baseline = pair.a.served.port.peer.session_state.outbound_answers.len();
    const pending = glowcap_test_archive_enliven(&client) orelse return error.ForeignAdmissionFailed;
    try std.testing.expect(pending.result() == .pending);
    const sibling = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7911", "widget"));
    defer sibling.deinit();
    pending.deinit();
    try std.testing.expectEqual(@as(usize, 1), client.pendingVowCount());
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(sibling.result() == .ready);
    try std.testing.expectEqual(baseline, pair.a.served.port.peer.session_state.outbound_answers.len());

    const restored = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7911", "widget"));
    defer restored.deinit();
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    const target = restored.result().ready.capability;
    const call = glowcap_test_archive_call(&client, pair.a, &target) orelse return error.ForeignAdmissionFailed;
    try std.testing.expect(call.result() == .pending);
    call.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqual(baseline, pair.a.served.port.peer.session_state.outbound_answers.len());

    const Local = struct {
        calls: *usize,
        pub fn handle(self: *@This(), turn: *glowcap.driver.core.HostTurn, _: ?[]const u8, args: glowcap.driver.core.Args) !glowcap.driver.core.Value {
            const arg_values = try args.values();
            defer turn.releaseValues(arg_values);
            self.calls.* += 1;
            return .void;
        }
    };
    var calls: usize = 0;
    const reserved = try client.reserveFreshCapability(null);
    const actor = try client.vat.spawn(glowcap.driver.core.Hosting(Local), .{ .inner = .{ .calls = &calls } });
    const local = client.adoptReservedLocalCapability(reserved, actor);
    defer client.releaseCapabilityTerminal(local, null);
    const public = glowcap_test_archive_send(&client, &local);
    try std.testing.expect(public != 0);
    try client.vowRelease(public);
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    try client.vat.drive();
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), client.pending_operations);
}

test "core host: own key enliven uses exact local publication without a session or dial" {
    var host = test_host.init(a, @splat(0x39), Host.Options.withFrameCap(h.frame_cap));
    defer host.deinit();
    const actor = try host.publish("widget", h.Widget, .{});
    const designator = host.node.publicKey().toDesignator();
    const sturdy: glowcap.ocapn.model.SturdyRef = .{
        .peer = .{ .transport = "webrtc", .designator = &designator },
        .swissnum = "widget",
    };
    const first = try host.enlivenCapability(a, sturdy);
    try std.testing.expectEqual(.verified, first.result().ready.provenance);
    try std.testing.expectEqual(actor, host.localActorFor(first.result().ready.capability).?);
    const second = try host.enlivenCapability(a, sturdy);
    try std.testing.expect(first.result().ready.capability.eql(second.result().ready.capability));
    const public = try host.enlivenSelectOrDial(sturdy);
    const action = (try host.nextAction()).?;
    try std.testing.expect(action == .settled);
    try std.testing.expectEqual(public, action.settled.vow_id);
    try std.testing.expectEqual(null, action.settled.peer_handle);
    try std.testing.expect(action.settled.value.capability.eql(first.result().ready.capability));
    host.freeAction(action);
    first.deinit();
    second.deinit();
    try std.testing.expect(host.vat.hasActor(actor.local));
    try std.testing.expectEqual(@as(usize, 0), host.sessions.count());
    try std.testing.expectEqual(@as(usize, 0), host.pending_enliven_count);
    try std.testing.expect((try host.nextAction()) == null);
    var missing = sturdy;
    missing.swissnum = "absent";
    const refused = try host.enlivenCapability(a, missing);
    defer refused.deinit();
    try std.testing.expectEqualStrings("unknown swissnum", refused.result().failed.message);
}

test "core host: owned enliven returns the same exact identity from wire and cache" {
    var client = test_host.init(a, @splat(0x31), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x32), Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7901", &dials);
    _ = try pair.b.served.publish(&server.vat, "widget", h.Widget, .{});
    const ref = h.tcpSturdyref("127.0.0.1:7901", "widget");
    const first = try client.enlivenCapability(a, ref);
    defer first.deinit();
    try std.testing.expect(first.result() == .pending);
    try std.testing.expectError(error.EnlivenPending, first.take());
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    const ready = first.result().ready;
    try std.testing.expectEqual(.dial_target, ready.provenance);
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    const second = try client.enlivenCapability(a, ref);
    defer second.deinit();
    try std.testing.expect(second.result() == .ready);
    const held = try second.take();
    defer client.releaseCapability(held, 1) catch unreachable;
    try std.testing.expect(ready.capability.eql(held));
    try std.testing.expectEqual(@as(?u64, 2), client.capabilities.retainCount(held));
    // Cached observation never manufactures a public completion action.
    while (try client.nextAction()) |action| {
        try std.testing.expect(action != .settled and action != .failed);
    }
}

test "core host: owned enliven cancellation detaches wire listener and permits immediate retry" {
    var client = test_host.init(a, @splat(0x33), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x34), Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7902", &dials);
    _ = try pair.b.served.publish(&server.vat, "widget", h.Widget, .{});
    const ref = h.tcpSturdyref("127.0.0.1:7902", "widget");
    const cancelled = try client.enlivenCapability(a, ref);
    cancelled.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    const retry = try client.enlivenCapability(a, ref);
    defer retry.deinit();
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(retry.result() == .ready);
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
}

test "core host: concurrent enliven preserves each observer when the first cancels" {
    var client = test_host.init(a, @splat(0x51), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x52), Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7911", &dials);
    _ = try pair.b.served.publish(&server.vat, "widget", h.Widget, .{});
    const sturdy = h.tcpSturdyref("127.0.0.1:7911", "widget");
    const sibling = blk: {
        const original = try client.enlivenCapability(a, sturdy);
        defer original.deinit();
        break :blk try client.enlivenCapability(a, sturdy);
    };
    defer sibling.deinit();
    try std.testing.expectEqual(@as(usize, 1), client.pendingVowCount());
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(sibling.result() == .ready);
}

test "core host: owned enliven parked cancellation preserves shared observers and public completion" {
    var host = test_host.init(a, @splat(0x35), Host.Options.withFrameCap(h.frame_cap));
    defer host.deinit();
    const first = try host.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7903", "one"));
    const second = try host.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7903", "two"));
    defer second.deinit();
    const third = try host.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7903", "three"));
    const public = try host.enlivenSelectOrDial(h.tcpSturdyref("127.0.0.1:7903", "public"));
    const dial = (try host.nextAction()).?.dial;
    first.deinit();
    third.deinit();
    try std.testing.expectEqual(@as(usize, 2), host.pending_enliven_count);
    try host.dialFailed(dial.ticket, dial.route_index, "unavailable");
    try std.testing.expectEqualStrings("unavailable", second.result().failed.message);
    try std.testing.expectEqual(@as(usize, 0), host.pending_enliven_count);
    var public_completed = false;
    while (try host.nextAction()) |action| {
        if (action == .failed) {
            try std.testing.expectEqual(public, action.failed.vow_id);
            public_completed = true;
        }
    }
    try std.testing.expect(public_completed);
}

test "core host: owned enliven completes when a parked dial opens" {
    var client = test_host.init(a, @splat(0x36), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x37), Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const owned = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7904", "widget"));
    defer owned.deinit();
    const dial = (try client.nextAction()).?.dial;
    const accepted = try h.publishAndOpenAccepted(&server, "tcp", "127.0.0.1:7904", &.{});
    _ = try accepted.served.publish(&server.vat, "widget", h.Widget, .{});
    try client.ensureAdvertisedLocator("tcp");
    const dialed = (try client.openPendingDial(dial.ticket, dial.route_index)).?;
    const pair = h.Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    _ = try client.exporterDialed(dial.ticket, dial.route_index, dialed);
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(owned.result() == .ready);
    try std.testing.expectEqual(@as(usize, 0), client.pending_enliven_count);
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
}

test "core host: owned enliven survives missing target and session closure" {
    for ([_]bool{ false, true }) |close| {
        var client = test_host.init(a, @splat(0x38), Host.Options.withFrameCap(h.frame_cap));
        defer client.deinit();
        var server = test_host.init(a, @splat(0x39), Host.Options.withFrameCap(h.frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(h.ParkedDial) = .empty;
        defer dials.deinit(a);
        const pair = try h.openPair(a, &client, &server, "127.0.0.1:7905", &dials);
        const owned = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7905", "absent"));
        defer owned.deinit();
        if (close) try client.releaseSession(pair.a) else try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
        try std.testing.expect(owned.result() == .failed);
        try std.testing.expectEqual(@as(glowcap.driver.core.VowFailure, if (close) .closed else .broken), owned.result().failed.kind);
        try std.testing.expectError(error.EnlivenFailed, owned.take());
        try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    }
}

test "core host: owned enliven cancellation needs no allocator after admission" {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var client = test_host.init(failing.allocator(), @splat(0x40), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x41), Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7906", &dials);
    const baseline_answers = pair.a.served.port.peer.session_state.outbound_answers.len();
    const owned = try client.enlivenCapability(failing.allocator(), h.tcpSturdyref("127.0.0.1:7906", "widget"));
    failing.fail_index = failing.alloc_index;
    const before = failing.alloc_index;
    owned.deinit();
    try std.testing.expectEqual(before, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    failing.fail_index = std.math.maxInt(usize);
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqual(baseline_answers, pair.a.served.port.peer.session_state.outbound_answers.len());
}

test "core host: owned enliven admission rolls back every refused allocation" {
    try std.testing.checkAllAllocationFailures(a, refusedAdmission, .{});
}

fn refusedAdmission(allocator: std.mem.Allocator) !void {
    var client = test_host.init(allocator, @splat(0x42), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    const owned = try client.enlivenCapability(allocator, h.tcpSturdyref("127.0.0.1:7907", "widget"));
    owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.pending_enliven_count);
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
}

test "core host: owned enliven connected admission releases every partial reservation" {
    for (0..64) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var client = test_host.init(failing.allocator(), @splat(0x43), Host.Options.withFrameCap(h.frame_cap));
        defer client.deinit();
        var server = test_host.init(a, @splat(0x44), Host.Options.withFrameCap(h.frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(h.ParkedDial) = .empty;
        defer dials.deinit(a);
        const pair = try h.openPair(a, &client, &server, "127.0.0.1:7908", &dials);
        const state = &pair.a.served.port.peer.session_state;
        const answers = state.outbound_answers.len();
        failing.fail_index = failing.alloc_index + offset;
        const owned = client.enlivenCapability(failing.allocator(), h.tcpSturdyref("127.0.0.1:7908", "widget")) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
            try std.testing.expectEqual(answers, state.outbound_answers.len());
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        owned.deinit();
        try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
        return;
    }
    return error.AllocationSweepIncomplete;
}

test "core host: owned enliven cached acquisition survives allocator pressure beside a public completion" {
    for (0..64) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var client = test_host.init(failing.allocator(), @splat(0x45), Host.Options.withFrameCap(h.frame_cap));
        defer client.deinit();
        var server = test_host.init(a, @splat(0x46), Host.Options.withFrameCap(h.frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(h.ParkedDial) = .empty;
        defer dials.deinit(a);
        const pair = try h.openPair(a, &client, &server, "127.0.0.1:7909", &dials);
        _ = try pair.b.served.publish(&server.vat, "widget", h.Widget, .{});
        const ref = h.tcpSturdyref("127.0.0.1:7909", "widget");
        const public = try client.enlivenSelectOrDial(ref);
        for (0..64) |_| {
            if (!try h.shuttleAll(&.{pair})) break;
        } else return error.PumpDidNotQuiesce;
        // Leave the public completion unprojected in Host's action queue.
        failing.fail_index = failing.alloc_index + offset;
        const observed = client.enlivenCapability(a, ref) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        defer observed.deinit();
        try std.testing.expect(observed.result() == .ready);
        try std.testing.expect(pair.a.sessionOpen());
        while (try client.nextAction()) |action| {
            if (action != .settled or action.settled.vow_id != public) continue;
            const capability = client.projectCompletion(action, {}, identityValue).settled.value.capability;
            try client.releaseCapability(capability, 1);
            try client.vowRelease(public);
            return;
        }
        return error.CompletionLost;
    }
    return error.AllocationSweepIncomplete;
}

test "core host: releasing cached owned enliven preserves a transferred public completion" {
    var client = test_host.init(a, @splat(0x47), Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x48), Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7910", &dials);
    _ = try pair.b.served.publish(&server.vat, "widget", h.Widget, .{});
    const ref = h.tcpSturdyref("127.0.0.1:7910", "widget");
    const public = try client.enlivenSelectOrDial(ref);
    for (0..64) |_| {
        if (!try h.shuttleAll(&.{pair})) break;
    } else return error.PumpDidNotQuiesce;
    const completion = while (try client.takeAction()) |action| {
        if (action == .settled and action.settled.vow_id == public) break action;
        client.freeAction(action);
    } else return error.CompletionLost;
    defer client.freeAction(completion);
    const observed = try client.enlivenCapability(a, ref);
    try std.testing.expect(observed.result() == .ready);
    observed.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const projected = client.projectCompletion(completion, {}, identityValue);
    try std.testing.expect(projected == .settled);
    const held = projected.settled.value.capability;
    defer client.releaseCapability(held, 1) catch unreachable;
    _ = try client.sendValues(pair.a, held, "poke", &.{}, arena.allocator());
    try client.vowRelease(public);
}

fn identityValue(_: void, value: glowcap.driver.core.Value) !glowcap.driver.core.Value {
    return value;
}
