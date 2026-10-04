//! Owned argument custody spans cold reads, revision restarts and outcomes.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const host_support = @import("../../support/core_host.zig");
const pair_support = @import("../../support/host_pair.zig");
const CapturedRef = @import("../../support/capture.zig").CapturedRef;
const a = std.testing.allocator;

const Edit = struct {
    id: f.loam.core.ObjectId,
    revision: u64,
    edge: f.loam.core.Edge,

    fn stage(context: *anyopaque, store: *f.loam.core.Store) !void {
        const self: *Edit = @ptrCast(@alignCast(context));
        var record = records.record(self.id, &@as([8]u8, @splat(0)));
        record.rooted = true;
        record.edges = &.{self.edge};
        try store.putCopying(record, self.revision);
    }
};

fn invoke(call: *f.hosting.Call, view: f.loam.core.RecordView, verb: []const u8, args: []const f.driver.Value) !f.driver.Value {
    if (args.len != 1 or args[0] != .list or args[0].list.len != 2) return error.InvalidArguments;
    const first = args[0].list[0].capability;
    const second = args[0].list[1].@"struct"[0].value.capability;
    if (!first.eql(second)) return error.WrongIdentity;
    if ((call.attachment.host.capabilities.retainCount(first) orelse 0) < 2) return error.ArgumentCustodyLost;
    if (call.attachment.host.capabilities.resolve(first) == null) return error.ArgumentInvalidated;
    if (std.mem.eql(u8, verb, "save")) {
        // An unsupported capture after a proposed payload change must still
        // fail before either participant reaches the write lane.
        call.replace(&@as([8]u8, @splat(1)));
        const edit = try call.arena.create(Edit);
        edit.* = .{ .id = view.id, .revision = view.revision, .edge = try call.capture(first) };
        call.transaction = .{ .context = edit, .stage = Edit.stage };
    }
    return .{ .integer = 2 };
}
const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .invoke = invoke }};

const Live = struct {
    pub fn handle(_: *Live, turn: *f.driver.HostTurn, _: []const u8, args: []const f.driver.Value) !f.driver.Value {
        defer turn.releaseValues(args);
        return .{ .void = {} };
    }
};

fn send(client: *f.driver.Host, session: *f.driver.HostSession, target: f.driver.Capability, argument: f.driver.Capability, verb: []const u8, answer: *f.Capture) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const nested = [_]f.driver.Value{
        .{ .capability = argument },
        .{ .@"struct" = &.{.{ .key = "same", .value = .{ .capability = argument } }} },
    };
    const vow = try client.sendValues(session, target, verb, &.{.{ .list = &nested }}, arena.allocator());
    try client.vowOn(vow, .{ .ctx = answer, .func = f.Capture.record });
}

test "loam capability arguments retain nested authority across cold reads restart and session loss" {
    for ([_]enum { complete, restart, close }{ .complete, .restart, .close }) |mode| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        fixture.attached.behaviors = &behaviors;
        try fixture.attached.sleep(fixture.root);
        var client = host_support.init(a, @splat(0x76), f.driver.Host.Options.withFrameCap(4096));
        defer client.deinit();
        const swiss = try fixture.host.publishDurableCapability(@splat(0x36), fixture.root);
        const pair = try pair_support.openPair(&client, &fixture.host, "127.0.0.1:9716");
        var fetched: CapturedRef = .{};
        try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
        try pair_support.pumpToQuiescence(&.{pair});
        const target = try client.liftCapability(pair.a, try fetched.require());
        defer client.releaseCapability(target, 1) catch unreachable;
        const actor = try client.vat.spawn(f.driver.Hosting(Live), .{ .inner = .{} });
        const live = try client.liftLocalActor(actor);
        var answer: f.Capture = .{};
        try send(&client, pair.a, target, live, "inspect", &answer);
        try client.releaseCapability(live, 1);
        try pair_support.pumpToQuiescence(&.{pair});
        try fixture.attached.advance();
        const read = (try fixture.attached.nextWork()).?.read;
        const operation = for (fixture.attached.operations) |*op| {
            if (op.phase != .free) break op;
        } else return error.NoAdmittedCall;
        const retained = operation.argument_retains[0].ref;
        try std.testing.expectEqual(@as(?u64, 2), fixture.host.capabilities.retainCount(retained));
        try std.testing.expect(answer.value == null and !answer.broken);
        if (mode == .restart) {
            try fixture.data.store.begin();
            var changed = records.record(fixture.id, &@as([8]u8, @splat(0)));
            changed.rooted = true;
            try fixture.data.store.putCopying(changed, 1);
            try records.commit(&fixture.data.store, &fixture.data.backend);
        }
        if (mode == .close) {
            try fixture.host.releaseSession(pair.b);
            try client.releaseSession(pair.a);
        }
        try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
        if (mode == .close) {
            try std.testing.expectError(error.UnknownIngress, fixture.attached.advance());
            try fixture.attached.advance();
        } else {
            try fixture.drain();
            try pair_support.pumpToQuiescence(&.{pair});
            try std.testing.expectEqual(@as(?i64, 2), answer.value);
        }
        try std.testing.expectEqual(@as(?u64, null), fixture.host.capabilities.retainCount(retained));
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    }
}

test "loam capability arguments persist only a proven local recipe without partial writes" {
    for ([_]bool{ false, true }) |durable| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        fixture.attached.behaviors = &behaviors;
        var client = host_support.init(a, @splat(0x77), f.driver.Host.Options.withFrameCap(4096));
        defer client.deinit();
        const swiss = try fixture.host.publishDurableCapability(@splat(0x37), fixture.root);
        const pair = try pair_support.openPair(&client, &fixture.host, "127.0.0.1:9717");
        var fetched: CapturedRef = .{};
        try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
        try pair_support.pumpToQuiescence(&.{pair});
        const target = try client.liftCapability(pair.a, try fetched.require());
        defer client.releaseCapability(target, 1) catch unreachable;
        const argument = if (durable) target else try client.liftLocalActor(try client.vat.spawn(f.driver.Hosting(Live), .{ .inner = .{} }));
        defer if (!durable) client.releaseCapability(argument, 1) catch unreachable;
        var answer: f.Capture = .{};
        try send(&client, pair.a, target, argument, "save", &answer);
        try pair_support.pumpToQuiescence(&.{pair});
        try fixture.drain();
        try pair_support.pumpToQuiescence(&.{pair});
        try std.testing.expectEqual(!durable, answer.broken);
        try std.testing.expectEqual(@as(u64, if (durable) 2 else 1), fixture.data.store.metadata.revision);
        const lease = try records.load(&fixture.data.store, &fixture.data.backend, fixture.id);
        defer fixture.data.store.release(lease) catch unreachable;
        const view = try fixture.data.store.view(lease);
        try std.testing.expectEqual(@as(usize, if (durable) 1 else 0), view.edge_count);
        var edges = view.edges();
        if (durable) try std.testing.expect(edges.next().?.target.eql(fixture.id));
    }
}
