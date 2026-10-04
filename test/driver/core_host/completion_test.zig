//! Completion custody survives queue transfer, projection refusal and closure.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("harness.zig");
const test_host = @import("../../support/core_host.zig");
const core = glowcap.driver.core;
const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const a = std.testing.allocator;

fn identity(_: void, value: core.Value) !core.Value {
    return value;
}

fn refuse(_: void, _: core.Value) !core.Value {
    return error.Refused;
}

const Nested = struct {
    fields: [2]model.Argument,

    pub fn handle(self: *Nested, _: *actors.Turn, _: actors.Message) !model.Argument {
        return .{ .tagged = .{ .tag = "two references", .value = &self.fields } };
    }
};

test "Host completion owns nested occurrences and projection adds independent retains without allocation" {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var client = test_host.init(failing.allocator(), @splat(0x51), core.Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = test_host.init(a, @splat(0x52), core.Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7911", &dials);
    const widget = try pair.b.served.publish(&server.vat, "widget", h.Widget, .{});
    _ = try pair.b.served.publish(&server.vat, "nested", Nested, .{
        .fields = .{ .{ .reference = widget.nearRef() }, .{ .reference = widget.nearRef() } },
    });
    const target = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7911", "nested"));
    defer target.deinit();
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const vow = try client.sendValues(pair.a, target.result().ready.capability, "get", &.{}, arena.allocator());
    for (0..64) |_| {
        if (!try h.shuttleAll(&.{pair})) break;
    } else return error.PumpDidNotQuiesce;
    const action = while (try client.takeAction()) |action| {
        if (action == .settled and action.settled.vow_id == vow) break action;
        client.freeAction(action);
    } else return error.CompletionLost;
    var action_live = true;
    defer if (action_live) client.freeAction(action);
    try client.vowRelease(vow);
    const tagged = action.settled.value.tagged;
    try std.testing.expectEqualStrings("two references", tagged.tag);
    const cap = tagged.value[0].capability;
    try std.testing.expect(cap.eql(tagged.value[1].capability));
    try std.testing.expectEqual(@as(?u64, 2), client.capabilities.retainCount(cap));

    failing.fail_index = failing.alloc_index;
    const refused = client.projectCompletion(action, {}, refuse);
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqual(@as(?u64, 2), client.capabilities.retainCount(cap));
    const first = client.projectCompletion(action, {}, identity);
    const second = client.projectCompletion(action, {}, identity);
    try std.testing.expect(first == .settled and second == .settled);
    try std.testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(?u64, 6), client.capabilities.retainCount(cap));
    // Projection borrows the action's data but owns its capability retains.
    client.freeAction(action);
    action_live = false;
    try std.testing.expectEqual(@as(?u64, 4), client.capabilities.retainCount(cap));
    try client.releaseCapability(cap, 4);
    try std.testing.expect(client.capabilities.retainCount(cap) == null);
}

test "Host completion uses actual capability home after its source session closes" {
    var host = test_host.init(a, @splat(0x53), .{});
    defer host.deinit();
    var first = test_host.init(a, @splat(0x54), .{});
    defer first.deinit();
    var second = test_host.init(a, @splat(0x55), .{});
    defer second.deinit();
    const source = (try h.host_pair.openPair(&host, &first, "127.0.0.1:7912")).a;
    const home = (try h.host_pair.openPair(&host, &second, "127.0.0.1:7913")).a;
    const peer = source.peer_handle;
    const local = try host.spawn(source, h.Widget, .{});
    try home.served.port.peer.importObject(7);
    const remote = try host.liftCapability(home, .{ .far = model.FarRef.object(7) });
    const local_action: core.HostAction = .{ .settled = .{ .peer_handle = peer, .vow_id = 1, .value = .{ .capability = local } } };
    const remote_action: core.HostAction = .{ .settled = .{ .peer_handle = peer, .vow_id = 2, .value = .{ .capability = remote } } };
    defer host.freeAction(local_action);
    defer host.freeAction(remote_action);
    try host.releaseSession(source);
    try std.testing.expect(host.projectCompletion(local_action, {}, identity) == .settled);
    try std.testing.expect(host.projectCompletion(remote_action, {}, identity) == .settled);
    try host.releaseCapability(local, 1);
    try host.releaseCapability(remote, 1);
    try host.releaseSession(home);
    const closed = host.projectCompletion(remote_action, {}, identity);
    try std.testing.expect(closed == .failed);
    try std.testing.expectEqual(core.VowFailure.closed, closed.failed.failure);
    try std.testing.expectEqual(@as(u64, 2), closed.failed.vow_id);
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(remote));
}

test "Host completion projection rolls back a retained prefix before a closed capability" {
    var host = test_host.init(a, @splat(0x56), .{});
    defer host.deinit();
    var partner = test_host.init(a, @splat(0x57), .{});
    defer partner.deinit();
    const session = (try h.host_pair.openPair(&host, &partner, "127.0.0.1:7914")).a;
    const peer = session.peer_handle;
    const local = try host.spawn(session, h.Widget, .{});
    try session.served.port.peer.importObject(7);
    const remote = try host.liftCapability(session, .{ .far = model.FarRef.object(7) });
    var arena = std.heap.ArenaAllocator.init(a);
    const fields = try arena.allocator().dupe(core.Value, &.{ .{ .capability = local }, .{ .capability = remote } });
    const action: core.HostAction = .{ .settled = .{
        .peer_handle = peer,
        .vow_id = 3,
        .value = .{ .list = fields },
        .storage = arena.state,
    } };
    defer host.freeAction(action);
    try host.releaseSession(session);
    const failed = host.projectCompletion(action, {}, identity);
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqual(core.VowFailure.closed, failed.failed.failure);
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(local));
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(remote));
}

test "Host completion borrowed retry and discard release exactly their owned occurrences" {
    var host = test_host.init(a, @splat(0x58), .{});
    defer host.deinit();
    const session = try h.publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7915", &.{});
    while (try host.nextAction()) |_| {}
    const cap = try host.spawn(session, h.Widget, .{});
    _ = try host.capabilities.retain(a, host.capabilities.resolve(cap).?);
    try host.actions.reserve(a, 2);
    for (0..2) |i| host.actions.pushReserved(.{ .settled = .{
        .peer_handle = session.peer_handle,
        .vow_id = i,
        .value = .{ .capability = cap },
    } });
    try std.testing.expectEqual(@as(u64, 0), (try host.nextAction()).?.settled.vow_id);
    try std.testing.expect(host.retryBorrowedAction());
    try std.testing.expectEqual(@as(u64, 0), (try host.nextAction()).?.settled.vow_id);
    try std.testing.expectEqual(@as(?u64, 2), host.capabilities.retainCount(cap));
    try std.testing.expectEqual(@as(u64, 1), (try host.nextAction()).?.settled.vow_id);
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(cap));
    try std.testing.expect((try host.nextAction()) == null);
    try std.testing.expect(host.capabilities.retainCount(cap) == null);
}

const Large = struct {
    fields: []const model.Argument,
    pub fn handle(self: *Large, _: *actors.Turn, _: actors.Message) !model.Argument {
        return .{ .list = self.fields };
    }
};

test "Host completion materialization refuses each allocation without leaking partially lifted authority" {
    for ([_]usize{ 1, 9 }) |references| try refusedMaterialization(references);
}

fn refusedMaterialization(references: usize) !void {
    var refused: usize = 0;
    for (0..64) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var host = test_host.init(failing.allocator(), @splat(0x59), .{});
        defer host.deinit();
        const session = try h.publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7916", &.{});
        const text: [8192]u8 = @splat('x');
        var fields: [10]model.Argument = undefined;
        fields[references] = .{ .string = &text };
        const target = try session.served.publish(&host.vat, "large", Large, .{ .fields = fields[0 .. references + 1] });
        // Export the same local actor as the first returned capability. The
        // string forces a later arena growth after that retain was acquired.
        for (fields[0..references]) |*field| field.* = .{ .reference = target.nearRef() };
        const held = try host.liftCapability(session, target.nearRef());
        defer host.releaseCapability(held, 1) catch unreachable;
        const vow = try host.queueSend(session, target.nearRef(), .{ .verb = "get", .args = &.{} });
        failing.fail_index = failing.alloc_index + offset;
        host.flushSession(session) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        try host.flushSession(session);
        var finished = false;
        while (try host.nextAction()) |action| switch (action) {
            .settled => |settled| {
                try std.testing.expectEqual(vow, settled.vow_id);
                try std.testing.expectEqual(@as(usize, 8192), settled.value.list[references].string.len);
                finished = true;
            },
            .failed => |failed| {
                try std.testing.expectEqual(vow, failed.vow_id);
                finished = true;
            },
            else => {},
        };
        try std.testing.expect(finished);
        try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(held));
        try host.vowRelease(vow);
        if (!induced) {
            try std.testing.expect(refused >= 2);
            return;
        }
        refused += 1;
    }
    return error.AllocationSweepIncomplete;
}
