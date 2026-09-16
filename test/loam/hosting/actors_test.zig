//! Sleep, activation, and durable visibility use the ordinary Vat call path.
const std = @import("std");
const f = @import("fixture.zig");

test "loam actor keeps its near identity across sleep wake and committed turns" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const near = fixture.host.localActorFor(fixture.root).?;
    try fixture.attached.sleep(fixture.root);
    try std.testing.expectError(error.ResidencyRequired, fixture.host.vat.near(near, .{ .verb = "get", .args = &.{} }));
    try std.testing.expectEqual(@as(u64, 0), fixture.attached.stats.loads);
    for (0..3) |i| {
        var capture: f.Capture = .{};
        try fixture.send("add", &.{.{ .integer = 1 }}, &capture);
        try fixture.drain();
        try std.testing.expectEqual(@as(?i64, @intCast(i + 1)), capture.value);
        try std.testing.expectEqual(near, fixture.host.localActorFor(fixture.root).?);
        try std.testing.expectEqual(@as(i64, @intCast(i + 1)), (try fixture.host.vat.near(near, .{ .verb = "get", .args = &.{} })).integer);
        try fixture.attached.sleep(fixture.root);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.data.store.cache.allocated_bytes);
}

test "loam actor coalesces cold callers and preserves invocation order" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.attached.sleep(fixture.root);
    var captures: [8]f.Capture = @splat(.{});
    for (&captures) |*capture| try fixture.send("add", &.{.{ .integer = 1 }}, capture);
    try fixture.host.vat.drive();
    try fixture.attached.advance();
    const read = (try fixture.attached.nextWork()).?.read;
    try std.testing.expect((try fixture.attached.nextWork()) == null);
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
    try std.testing.expectError(error.Busy, fixture.attached.destroy());
    try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
    try fixture.drain();
    for (captures, 0..) |capture, i| try std.testing.expectEqual(@as(?i64, @intCast(i + 1)), capture.value);
}

test "loam actor reply waits for commit and unknown outcome recovery" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var capture: f.Capture = .{};
    try fixture.send("add", &.{.{ .integer = 4 }}, &capture);
    try fixture.host.vat.drive();
    try fixture.attached.advance();
    try fixture.host.vat.drive();
    const batch = (try fixture.attached.nextWork()).?.write;
    try std.testing.expect(capture.value == null);
    try std.testing.expect(fixture.data.backend.commit(batch) == .committed);
    try fixture.attached.completeWrite(batch.ticket, .unknown);
    try fixture.attached.advance();
    try std.testing.expect(capture.value == null);
    try std.testing.expectError(error.RecoveryRequired, fixture.attached.pin(fixture.root));
    const recovery = try fixture.attached.recoveryBatch();
    try fixture.attached.resolve(batch.ticket, try fixture.data.backend.recover(recovery));
    try fixture.attached.advance();
    try std.testing.expectEqual(@as(?i64, 4), capture.value);
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.invocations);
}

test "loam actor failed state replacement is not installed and pins prevent sleep" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const pin = try fixture.attached.pin(fixture.root);
    try std.testing.expectError(error.Busy, fixture.attached.sleep(fixture.root));
    try fixture.data.store.release(pin);
    var capture: f.Capture = .{};
    try fixture.send("fail", &.{.{ .integer = 8 }}, &capture);
    try fixture.drain();
    try std.testing.expect(capture.broken);
    try std.testing.expectEqual(@as(u64, 1), fixture.data.store.metadata.revision);
    const near = fixture.host.localActorFor(fixture.root).?;
    try std.testing.expectEqual(@as(i64, 0), (try fixture.host.vat.near(near, .{ .verb = "get", .args = &.{} })).integer);
    try std.testing.expectError(error.DurableTurnRequired, fixture.host.vat.near(near, .{ .verb = "add", .args = &.{.{ .integer = 9 }} }));
}

test "loam actor cancellation retires a scheduled activation pin" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const ingress = try fixture.host.vat.openIngress();
    var capture: f.Capture = .{};
    const near = fixture.host.localActorFor(fixture.root).?;
    _ = try fixture.host.vat.sendObservedFromIngress(ingress, near, .{ .verb = "get", .args = &.{} }, .{ .ctx = &capture, .func = f.Capture.record });
    _ = try fixture.host.vat.driveBudgeted(1);
    try fixture.attached.advance();
    try fixture.host.vat.cancelIngress(ingress, "closed");
    try fixture.attached.advance();
    try std.testing.expect(capture.broken);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    try fixture.attached.sleep(fixture.root);
}

test "loam actor slow storage and bounded pending calls preserve unrelated Vat progress" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_calls = 2, .call_bytes = 2048, .pending_bytes = 4096 });
    defer fixture.deinit();
    try fixture.attached.sleep(fixture.root);
    var captures: [3]f.Capture = @splat(.{});
    for (&captures) |*capture| try fixture.send("get", &.{}, capture);
    try fixture.host.vat.drive();
    try std.testing.expect(captures[2].broken);
    try std.testing.expectEqual(@as(usize, 4096), fixture.attached.pending_bytes);
    const Other = struct {
        pub fn handle(_: *@This(), _: *f.actors.Turn, _: f.actors.Message) !@import("glowcap").ocapn.model.Argument {
            return .{ .integer = 77 };
        }
    };
    const other = try fixture.host.vat.spawn(Other, .{});
    defer fixture.host.vat.releaseActor(other.local);
    var independent: f.Capture = .{};
    _ = try fixture.host.vat.sendObservedFromIngress(.local, other, .{ .verb = "get", .args = &.{} }, .{ .ctx = &independent, .func = f.Capture.record });
    try fixture.attached.advance();
    const read = (try fixture.attached.nextWork()).?.read;
    try fixture.host.vat.drive();
    try std.testing.expectEqual(@as(?i64, 77), independent.value);
    try std.testing.expect(captures[0].value == null);
    try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
    try fixture.drain();
}

test "loam actor storage corruption breaks waiters without fresh actor fallback" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.attached.sleep(fixture.root);
    var capture: f.Capture = .{};
    try fixture.send("get", &.{}, &capture);
    try fixture.host.vat.drive();
    try fixture.attached.advance();
    const read = (try fixture.attached.nextWork()).?.read;
    const result = fixture.data.backend.read(read);
    read.buffer[0] ^= 1;
    try std.testing.expectError(error.Corrupt, fixture.attached.completeRead(read.ticket, result));
    try fixture.attached.advance();
    try std.testing.expect(capture.broken);
    try std.testing.expectEqual(@as(u64, 0), fixture.attached.stats.invocations);
    try std.testing.expectError(error.StaleCompletion, fixture.attached.completeRead(read.ticket, result));
}

test "loam actor attachment closes while held endpoints refuse without touching freed storage" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    const near = fixture.host.localActorFor(fixture.root).?;
    try fixture.attached.destroy();
    fixture.data.deinit();
    try std.testing.expectError(error.AttachmentClosed, fixture.host.vat.near(near, .{ .verb = "get", .args = &.{} }));
    try fixture.host.releaseCapability(fixture.root, 1);
    fixture.host.deinit();
}

test "loam actor allocation refusal unwinds or finishes exactly one mutation" {
    var refusals: usize = 0;
    var successes: usize = 0;
    for (0..96) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var fixture: f.Fixture = undefined;
        try fixture.initAllocator(failing.allocator(), .{});
        defer fixture.deinit();
        try fixture.attached.sleep(fixture.root);
        failing.fail_index = failing.alloc_index + offset;
        var answer: f.Capture = .{};
        fixture.send("add", &.{.{ .integer = 1 }}, &answer) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        fixture.drain() catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        if (failing.has_induced_failure) refusals += 1;
        failing.fail_index = std.math.maxInt(usize);
        try fixture.drain();
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
        try std.testing.expect(fixture.attached.stats.invocations <= 1);
        if (answer.value) |number| {
            try std.testing.expectEqual(@as(i64, 1), number);
            try std.testing.expectEqual(@as(u64, 2), fixture.data.store.metadata.revision);
            successes += 1;
        } else try std.testing.expectEqual(@as(u64, 1), fixture.data.store.metadata.revision);
    }
    try std.testing.expect(refusals > 5 and successes > 0);
}

test "loam actor cold object growth does not create endpoints or cache allocations" {
    const records = @import("../core/fixture.zig");
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_endpoints = 2 });
    defer fixture.deinit();
    try fixture.attached.sleep(fixture.root);
    for (0..128) |_| {
        try fixture.data.store.begin();
        for (0..8) |_| {
            var record = records.record(try fixture.data.store.allocateId(), &@as([8]u8, @splat(0)));
            record.rooted = true;
            try fixture.data.store.putCopying(record, null);
        }
        try records.commit(&fixture.data.store, &fixture.data.backend);
    }
    try std.testing.expectEqual(@as(u64, 1025), fixture.data.store.metadata.objects);
    try std.testing.expectEqual(@as(usize, 0), fixture.data.store.cache.allocated_bytes);
    var endpoints: usize = 0;
    for (fixture.attached.entries) |entry| if (entry.actor != null) {
        endpoints += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), endpoints);
    var answer: f.Capture = .{};
    try fixture.send("get", &.{}, &answer);
    try fixture.drain();
    try std.testing.expectEqual(@as(?i64, 0), answer.value);
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
}

test "loam actor attachment creation unwinds each allocation refusal" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndRelease, .{});
}

test "loam actor held capability retains a sleeping unrooted record through collection" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    var held = true;
    defer {
        if (held) fixture.host.releaseCapability(fixture.root, 1) catch unreachable;
        fixture.attached.destroy() catch unreachable;
        fixture.host.deinit();
        fixture.data.deinit();
    }
    const store = &fixture.data.store;
    const records = @import("../core/fixture.zig");
    const lease = try records.load(store, &fixture.data.backend, fixture.id);
    const portrait = try store.view(lease);
    try store.begin();
    var r = records.record(fixture.id, portrait.payload);
    r.rooted = false;
    try store.putCopying(r, portrait.revision);
    try store.release(lease);
    try records.commit(store, &fixture.data.backend);
    try fixture.attached.sleep(fixture.root);
    try records.collect(store, &fixture.data.backend);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 0), fixture.attached.stats.loads);
    var capture: f.Capture = .{};
    try fixture.send("get", &.{}, &capture);
    try fixture.drain();
    try std.testing.expectEqual(@as(?i64, 0), capture.value);
    try fixture.host.releaseCapability(fixture.root, 1);
    held = false;
    // Cross an ordinary Vat boundary to retire the released endpoint box.
    _ = try fixture.host.vat.near(fixture.attached.runner, .{ .verb = "barrier", .args = &.{} });
    try records.collect(store, &fixture.data.backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
}

fn createAndRelease(allocator: std.mem.Allocator) !void {
    var fixture: f.Fixture = undefined;
    try fixture.initAllocator(allocator, .{});
    fixture.deinit();
}
