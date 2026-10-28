//! CapTP delivery through an ordinary Host, with storage completion outside
//! the actor turn. These are internal cross-layer tests, not external interop.
const std = @import("std");
const f = @import("fixture.zig");
const host_support = @import("../../support/core_host.zig");
const pair_support = @import("../../support/host_pair.zig");
const CapturedRef = @import("../../support/capture.zig").CapturedRef;
const records = @import("../core/fixture.zig");

test "loam actor held CapTP reference wakes repeatedly and publication retirement preserves it" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .sleep_policy = .every_turn });
    defer fixture.deinit();
    var client = host_support.init(std.testing.allocator, @splat(0x72), f.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    try fixture.data.store.begin();
    const publication = try f.hosting.publication.stage(fixture.attached, @splat(0x21), fixture.root);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    const swiss = try f.hosting.publication.restore(fixture.attached, lease);
    try fixture.data.store.release(lease);
    fixture.data.store.evict();
    const pair = try pair_support.openPair(&client, &fixture.host, "127.0.0.1:9712");
    var fetched: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    const held = try fetched.require();
    const active = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    try fixture.data.store.begin();
    try f.hosting.publication.stageRetirement(fixture.attached, active);
    _ = try fixture.attached.submit();
    try fixture.drain();
    try std.testing.expectError(error.StaleSnapshot, f.hosting.publication.restore(fixture.attached, active));
    try fixture.data.store.release(active);
    const retired = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    try std.testing.expectError(error.RetiredPublication, f.hosting.publication.restore(fixture.attached, retired));
    try fixture.data.store.release(retired);
    fixture.data.store.evict();
    for (0..3) |i| {
        var answer: f.Capture = .{};
        try client.vowOn(try client.send(pair.a, held, .{ .verb = "add", .args = &.{.{ .integer = 1 }} }), .{ .ctx = &answer, .func = f.Capture.record });
        try pair_support.pumpToQuiescence(&.{pair});
        try std.testing.expect(answer.value == null);
        try fixture.drain();
        try pair_support.pumpToQuiescence(&.{pair});
        try std.testing.expectEqual(@as(?i64, @intCast(i + 1)), answer.value);
        try std.testing.expectEqual(@as(usize, 0), fixture.data.store.cache.allocated_bytes);
    }
    try std.testing.expectEqual(@as(u64, 3), fixture.attached.stats.loads);
}

test "loam actor restores a held local capability edge without waking the target graph" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.data.store.begin();
    const second_id = try fixture.data.store.allocateId();
    var record = records.record(second_id, &@as([8]u8, @splat(0)));
    record.rooted = true;
    record.edges = &.{try fixture.attached.capture(fixture.root)};
    try fixture.data.store.putCopying(record, null);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const second_lease = try records.load(&fixture.data.store, &fixture.data.backend, second_id);
    const second = try fixture.attached.restore(second_lease);
    try fixture.data.store.release(second_lease);
    defer fixture.host.releaseCapability(second, 1) catch unreachable;
    try fixture.data.store.begin();
    record = records.record(fixture.id, &@as([8]u8, @splat(0)));
    record.rooted = true;
    record.edges = &.{try fixture.attached.capture(second)};
    try fixture.data.store.putCopying(record, 1);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    fixture.data.store.evict();
    var client = host_support.init(std.testing.allocator, @splat(0x73), f.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const swiss = try fixture.host.publishDurableCapability(@splat(0x22), fixture.root);
    const pair = try pair_support.openPair(&client, &fixture.host, "127.0.0.1:9713");
    var root: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &root, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    var linked: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, try root.require(), .{ .verb = "edge", .args = &.{} }), .{ .ctx = &linked, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try fixture.drain();
    try pair_support.pumpToQuiescence(&.{pair});
    const held = try linked.require();
    try std.testing.expectEqual(@as(u64, 1), fixture.attached.stats.loads);
    try std.testing.expectError(error.ResidencyRequired, fixture.attached.pin(second));
    var answer: f.Capture = .{};
    try client.vowOn(try client.send(pair.a, held, .{ .verb = "add", .args = &.{.{ .integer = 9 }} }), .{ .ctx = &answer, .func = f.Capture.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try fixture.drain();
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(?i64, 9), answer.value);
}

test "loam actor CapTP pipeline waits through a cold capability reply and durable mutation" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .sleep_policy = .every_turn });
    defer fixture.deinit();
    try fixture.data.store.begin();
    var record = records.record(fixture.id, &@as([8]u8, @splat(0)));
    record.rooted = true;
    record.edges = &.{try fixture.attached.capture(fixture.root)};
    try fixture.data.store.putCopying(record, 1);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    fixture.data.store.evict();
    var client = host_support.init(std.testing.allocator, @splat(0x74), f.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const swiss = try fixture.host.publishDurableCapability(@splat(0x23), fixture.root);
    const pair = try pair_support.openPair(&client, &fixture.host, "127.0.0.1:9715");
    const fetched = try client.fetch(pair.a, swiss.slice());
    const edge = try client.vowSend(fetched, .{ .verb = "edge", .args = &.{} });
    const added = try client.vowSend(edge, .{ .verb = "add", .args = &.{.{ .integer = 6 }} });
    var answer: f.Capture = .{};
    try client.vowOn(added, .{ .ctx = &answer, .func = f.Capture.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expect(answer.value == null and !answer.broken);
    for (0..8) |_| {
        try fixture.drain();
        try pair_support.pumpToQuiescence(&.{pair});
        if (answer.value != null or answer.broken) break;
    }
    try std.testing.expect(!answer.broken);
    try std.testing.expectEqual(@as(?i64, 6), answer.value);
    try std.testing.expectEqual(@as(u64, 3), fixture.data.store.metadata.revision);
}

test "loam actor released session cannot abandon a load or an admitted commit" {
    for ([_]bool{ false, true }) |writing| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        try fixture.attached.sleep(fixture.root);
        var client = host_support.init(std.testing.allocator, @splat(0x75), f.driver.Host.Options.withFrameCap(4096));
        defer client.deinit();
        const swiss = try fixture.host.publishDurableCapability(@splat(0x24), fixture.root);
        const pair = try pair_support.openPair(&client, &fixture.host, "127.0.0.1:9716");
        var fetched: CapturedRef = .{};
        try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
        try pair_support.pumpToQuiescence(&.{pair});
        _ = try client.send(pair.a, try fetched.require(), .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
        try pair_support.pumpToQuiescence(&.{pair});
        try fixture.attached.advance();
        const read = (try fixture.attached.nextWork()).?.read;
        if (writing) {
            try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
            try fixture.attached.advance();
        }
        try fixture.host.releaseSession(pair.b);
        try client.releaseSession(pair.a);
        try std.testing.expectEqual(@as(usize, 1), fixture.host.pending_operations);
        try std.testing.expectError(error.Busy, fixture.attached.destroy());
        if (writing) {
            const batch = (try fixture.attached.nextWork()).?.write;
            try fixture.attached.completeWrite(batch.ticket, fixture.data.backend.commit(batch));
        } else {
            try fixture.attached.completeRead(read.ticket, fixture.data.backend.read(read));
            try fixture.attached.advance();
            const failed = for (fixture.attached.operations) |operation| {
                if (operation.phase == .failed) break operation;
            } else return error.MissingDisconnectedCallFailure;
            try std.testing.expectEqual(@as(anyerror, error.UnknownIngress), failed.failure);
        }
        try fixture.attached.advance();
        try std.testing.expectEqual(@as(usize, 0), fixture.host.pending_operations);
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
        try std.testing.expectEqual(@as(u64, if (writing) 2 else 1), fixture.data.store.metadata.revision);
    }
}

test "loam publication retirement fences discovery at its owned commit outcome" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.data.store.begin();
    const publication = try f.hosting.publication.stage(fixture.attached, @splat(0x31), fixture.root);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    const swiss = try f.hosting.publication.restore(fixture.attached, lease);
    try fixture.data.store.release(lease);

    const active = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    try fixture.data.store.begin();
    try f.hosting.publication.stageRetirement(fixture.attached, active);
    try fixture.data.store.release(active);
    _ = try fixture.attached.submit();
    var slot: [1]f.hosting.Worker.Slot = undefined;
    var worker: f.hosting.Worker = .init(&slot, fixture.data.backend.readerCapacity());
    try worker.drive(fixture.attached, &fixture.data.backend);
    try std.testing.expectError(error.UnknownPublication, fixture.host.removeDurable(swiss.slice()));
}

test "loam fenced publication retirement stays removed when recovery finds the commit" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.data.store.begin();
    const publication = try f.hosting.publication.stage(fixture.attached, @splat(0x32), fixture.root);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    const swiss = try f.hosting.publication.restore(fixture.attached, lease);
    try fixture.data.store.release(lease);

    const active = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    try fixture.data.store.begin();
    try f.hosting.publication.stageRetirement(fixture.attached, active);
    try fixture.data.store.release(active);
    const ticket = try fixture.attached.submit();
    while (try fixture.attached.nextWork()) |work| switch (work) {
        .read => |request| try fixture.attached.completeRead(request.ticket, fixture.data.backend.read(request)),
        .lookup => |request| try fixture.attached.completeLookup(request.ticket, fixture.data.backend.lookup(request)),
        .write => |batch| {
            _ = fixture.data.backend.commit(batch);
            // The commit's reply is lost: the fence still applies, fail closed.
            try fixture.attached.completeWrite(ticket, .unknown);
        },
    };
    try std.testing.expectError(error.UnknownPublication, fixture.host.removeDurable(swiss.slice()));
    const pending = try fixture.attached.recoveryBatch();
    try fixture.attached.resolve(ticket, try fixture.data.backend.recover(pending));
    try std.testing.expectError(error.UnknownPublication, fixture.host.removeDurable(swiss.slice()));
}

test "loam fenced publication retirement restores discovery when recovery proves the batch absent" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.data.store.begin();
    const publication = try f.hosting.publication.stage(fixture.attached, @splat(0x33), fixture.root);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    const swiss = try f.hosting.publication.restore(fixture.attached, lease);
    try fixture.data.store.release(lease);

    const active = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    try fixture.data.store.begin();
    try f.hosting.publication.stageRetirement(fixture.attached, active);
    try fixture.data.store.release(active);
    const ticket = try fixture.attached.submit();
    while (try fixture.attached.nextWork()) |work| switch (work) {
        .read => |request| try fixture.attached.completeRead(request.ticket, fixture.data.backend.read(request)),
        .lookup => |request| try fixture.attached.completeLookup(request.ticket, fixture.data.backend.lookup(request)),
        .write => try fixture.attached.completeWrite(ticket, .unknown),
    };
    try std.testing.expectError(error.UnknownPublication, fixture.host.removeDurable(swiss.slice()));
    // Recovery restores its hidden row even when the recipe is cold.
    _ = try fixture.data.store.evictObject(publication);
    const pending = try fixture.attached.recoveryBatch();
    try fixture.attached.resolve(ticket, try fixture.data.backend.recover(pending));
    try fixture.drain();
    _ = try fixture.host.removeDurable(swiss.slice());
}

test "loam known absent recovery restores exact publication without allocation or residency" {
    for ([_]bool{ false, true }) |cold| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var fixture: f.Fixture = undefined;
        try fixture.initAllocator(failing.allocator(), .{});
        defer fixture.deinit();
        try fixture.data.store.begin();
        const publication = try f.hosting.publication.stage(fixture.attached, @splat(0x36), fixture.root);
        try records.commit(&fixture.data.store, &fixture.data.backend);
        const lease = try records.load(&fixture.data.store, &fixture.data.backend, publication);
        const swiss = try f.hosting.publication.restore(fixture.attached, lease);
        const actor = fixture.host.publications.get(fixture.host.publication_secret, swiss.slice()).?.actor;
        try fixture.data.store.begin();
        try f.hosting.publication.stageRetirement(fixture.attached, lease);
        try fixture.data.store.release(lease);
        const ticket = try fixture.attached.submit();
        const batch = (try fixture.attached.nextWork()).?.write;
        try fixture.attached.completeWrite(ticket, .unknown);
        const hidden = fixture.host.publications.get(fixture.host.publication_secret, swiss.slice()).?;
        try std.testing.expect(!hidden.active);
        try std.testing.expectEqual(actor, hidden.actor);
        if (cold) _ = try fixture.data.store.evictObject(publication);
        const resolution = try fixture.data.backend.recover(batch);
        failing.fail_index = failing.alloc_index;
        defer failing.fail_index = std.math.maxInt(usize);
        try fixture.attached.resolve(ticket, resolution);
        try std.testing.expect(fixture.attached.writing == null);
        try std.testing.expect(fixture.data.store.phase == .idle);
        try std.testing.expect(!fixture.attached.hasPendingWork());
        const restored = fixture.host.publications.get(fixture.host.publication_secret, swiss.slice()).?;
        try std.testing.expect(restored.active);
        try std.testing.expectEqual(actor, restored.actor);
        try std.testing.expect(!failing.has_induced_failure);
        _ = try fixture.host.removeDurable(swiss.slice());
    }
}

test "loam publication retirement custody is bounded duplicate-safe and droppable" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .max_retirements = 1 });
    defer fixture.deinit();
    try fixture.data.store.begin();
    const first = try f.hosting.publication.stage(fixture.attached, @splat(0x34), fixture.root);
    const second = try f.hosting.publication.stage(fixture.attached, @splat(0x35), fixture.root);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const first_lease = try records.load(&fixture.data.store, &fixture.data.backend, first);
    defer fixture.data.store.release(first_lease) catch unreachable;
    const second_lease = try records.load(&fixture.data.store, &fixture.data.backend, second);
    defer fixture.data.store.release(second_lease) catch unreachable;

    try fixture.data.store.begin();
    try f.hosting.publication.stageRetirement(fixture.attached, first_lease);
    try std.testing.expectError(error.RetirementPending, f.hosting.publication.stageRetirement(fixture.attached, first_lease));
    try std.testing.expectError(error.RetirementCapacity, f.hosting.publication.stageRetirement(fixture.attached, second_lease));
    try fixture.data.store.abort();
    try f.hosting.publication.dropRetirement(fixture.attached, first);
    try fixture.data.store.begin();
    try f.hosting.publication.stageRetirement(fixture.attached, second_lease);
    try f.hosting.publication.dropRetirement(fixture.attached, second);
    try fixture.data.store.abort();
}

test "loam publication retirement staging refusal releases custody for retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture: f.Fixture = undefined;
    try fixture.initAllocator(failing.allocator(), .{ .max_retirements = 1 });
    defer fixture.deinit();
    try fixture.data.store.begin();
    const publication = try f.hosting.publication.stage(fixture.attached, @splat(0x36), fixture.root);
    try records.commit(&fixture.data.store, &fixture.data.backend);
    const lease = try records.load(&fixture.data.store, &fixture.data.backend, publication);
    defer fixture.data.store.release(lease) catch unreachable;
    defer {
        failing.fail_index = std.math.maxInt(usize);
        if (fixture.attached.retirements[0] != null) f.hosting.publication.dropRetirement(fixture.attached, publication) catch unreachable;
        if (fixture.data.store.phase == .staging) fixture.data.store.abort() catch unreachable;
    }

    try std.testing.expectError(error.WrongPhase, f.hosting.publication.stageRetirement(fixture.attached, lease));
    try std.testing.expect(fixture.attached.retirements[0] == null);
    try fixture.data.store.begin();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, f.hosting.publication.stageRetirement(fixture.attached, lease));
    try std.testing.expect(fixture.attached.retirements[0] == null);
    failing.fail_index = std.math.maxInt(usize);
    try f.hosting.publication.stageRetirement(fixture.attached, lease);
    _ = try fixture.attached.submit();
    try fixture.drain();
    try std.testing.expect(fixture.attached.retirements[0] == null);
}

test "loam publication retirement completion survives host close admission" {
    for ([_]bool{ false, true }) |cancel| for ([_]bool{ false, true }) |absent| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        try fixture.data.store.begin();
        const publication = try f.hosting.publication.stage(fixture.attached, @splat(0x37), fixture.root);
        try records.commit(&fixture.data.store, &fixture.data.backend);
        const lease = try records.load(&fixture.data.store, &fixture.data.backend, publication);
        const swiss = try f.hosting.publication.restore(fixture.attached, lease);
        try fixture.data.store.begin();
        try f.hosting.publication.stageRetirement(fixture.attached, lease);
        try fixture.data.store.release(lease);
        _ = try fixture.attached.submit();
        var slots: [1]f.hosting.Worker.Slot = undefined;
        var worker: f.hosting.Worker = .init(&slots, fixture.data.backend.readerCapacity());
        const slot = (try worker.next(fixture.attached, .when_uncertain)).?;
        if (absent) slot.result = .{ .write = .unknown } else try f.hosting.Worker.run(slot, &fixture.data.backend);
        defer {
            // Keep a failed assertion from hiding the original completion error
            // behind fixture teardown's busy guard.
            fixture.host.lifecycle = .active;
            if (fixture.attached.writing != null) fixture.attached.completeWrite(slot.request.write.ticket, slot.result.?.write) catch unreachable;
            if (slot.active and slot.completed) worker.release(slot) catch unreachable;
            if (fixture.attached.hasPendingWork()) fixture.drain() catch unreachable;
        }
        fixture.host.beginClose(if (cancel) .cancel else .{ .finish = .unbounded }, 0);
        try std.testing.expectError(error.HostClosing, fixture.host.removeDurable(swiss.slice()));
        try worker.complete(slot, fixture.attached);
        if (absent) {
            const pending = try fixture.attached.recoveryBatch();
            try fixture.attached.resolve(pending.ticket, try fixture.data.backend.recover(pending));
            try fixture.attached.advance();
        }
        try std.testing.expectEqual(f.loam.core.Store.Phase.idle, fixture.data.store.phase);
        try std.testing.expectEqual(absent and !cancel, fixture.host.publications.contains(fixture.host.publication_secret, swiss.slice()));
        try std.testing.expect(!fixture.attached.hasPendingWork());
    };
}
