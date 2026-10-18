//! `hosting.Worker` slot and reader admission, recovery exclusion, and completion order.
const std = @import("std");
const f = @import("fixture.zig");
const Worker = f.hosting.Worker;

fn driveUntilQuiet(fixture: *f.Fixture, worker: *Worker) !void {
    for (0..64) |_| {
        _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
        try fixture.attached.advance();
        try worker.drive(fixture.attached, &fixture.data.backend);
        if (!fixture.attached.hasPendingWork()) return;
    }
    return error.DidNotQuiesce;
}

/// The loop every Zig consumer wrote before the worker. It is the reference
/// `drive` must match.
fn handUntilQuiet(fixture: *f.Fixture) !void {
    for (0..64) |_| {
        _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
        try fixture.attached.advance();
        while (try fixture.attached.nextWork()) |work| switch (work) {
            .read => |request| try fixture.attached.completeRead(request.ticket, fixture.data.backend.read(request)),
            .lookup => |request| try fixture.attached.completeLookup(request.ticket, fixture.data.backend.lookup(request)),
            .write => |batch| try fixture.attached.completeWrite(batch.ticket, fixture.data.backend.commit(batch)),
        };
        if (!fixture.attached.hasPendingWork()) return;
    }
    return error.DidNotQuiesce;
}

fn queueAdd(fixture: *f.Fixture, capture: *f.Capture) !void {
    try fixture.send("add", &.{.{ .integer = 4 }}, capture);
    try fixture.host.vat.drive();
    try fixture.attached.advance();
    try fixture.host.vat.drive();
}

/// Commits for real and reports `unknown`, the outcome that fences the Store.
const UnknownCommit = struct {
    inner: *f.loam.Volatile,
    pub fn read(self: UnknownCommit, request: f.loam.core.Read) f.loam.core.ReadResult {
        return self.inner.read(request);
    }
    pub fn commit(self: UnknownCommit, batch: f.loam.core.Batch) f.loam.core.Outcome {
        std.debug.assert(self.inner.commit(batch) == .committed);
        return .unknown;
    }
    pub fn lookup(self: UnknownCommit, request: f.loam.core.NameLookup) f.loam.core.NameResult {
        return self.inner.lookup(request);
    }
    pub fn recover(self: UnknownCommit, batch: f.loam.core.Batch) !f.loam.core.Resolution {
        return self.inner.recover(batch);
    }
};

test "loam worker drive quiesces to the state the hand loop reaches" {
    var by_hand: f.Fixture = undefined;
    try by_hand.init(.{});
    defer by_hand.deinit();
    var by_worker: f.Fixture = undefined;
    try by_worker.init(.{});
    defer by_worker.deinit();
    var slots: [1]Worker.Slot = undefined;
    var worker: Worker = .init(&slots, by_worker.data.backend.readerCapacity());

    var hand_capture: f.Capture = .{};
    var worker_capture: f.Capture = .{};
    try by_hand.send("add", &.{.{ .integer = 4 }}, &hand_capture);
    try by_worker.send("add", &.{.{ .integer = 4 }}, &worker_capture);
    // Evict first so the call needs a read as well as a write.
    by_hand.data.store.evict();
    by_worker.data.store.evict();
    try handUntilQuiet(&by_hand);
    try driveUntilQuiet(&by_worker, &worker);

    try std.testing.expectEqual(@as(?i64, 4), worker_capture.value);
    try std.testing.expectEqual(hand_capture.value, worker_capture.value);
    try std.testing.expectEqualDeep(by_hand.data.store.metadata, by_worker.data.store.metadata);
    try std.testing.expectEqual(by_hand.attached.stats, by_worker.attached.stats);
    try std.testing.expect(by_worker.attached.stats.loads > 0);
    try std.testing.expectEqual(@as(usize, 0), worker.active);
}

test "loam worker refuses a second request when every slot is taken" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var slots: [1]Worker.Slot = undefined;
    var worker: Worker = .init(&slots, fixture.data.backend.readerCapacity());
    var capture: f.Capture = .{};
    try queueAdd(&fixture, &capture);

    const slot = (try worker.next(fixture.attached, .when_uncertain)).?;
    try std.testing.expectError(error.Busy, worker.next(fixture.attached, .when_uncertain));
    try Worker.run(slot, &fixture.data.backend);
    try worker.complete(slot, fixture.attached);
    try worker.release(slot);
    try driveUntilQuiet(&fixture, &worker);
    try std.testing.expectEqual(@as(?i64, 4), capture.value);
}

test "loam worker admits reads up to the engine's readers and still offers the write" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var slots: [2]Worker.Slot = undefined;
    var worker: Worker = .init(&slots, 1);
    var capture: f.Capture = .{};
    fixture.data.store.evict();
    try queueAdd(&fixture, &capture);

    const read = (try worker.next(fixture.attached, .when_uncertain)).?;
    try std.testing.expect(read.request == .read);
    // A slot is free, but the one read the engine admits is taken.
    try std.testing.expectError(error.Busy, worker.next(fixture.attached, .when_uncertain));
    try Worker.run(read, &fixture.data.backend);
    try worker.complete(read, fixture.attached);
    // The read holds its reader until release, and the write it enabled
    // needs none, so the worker offers it once the call stages it.
    for (0..8) |_| {
        try fixture.host.vat.drive();
        try fixture.attached.advance();
        if (fixture.attached.writing != null) break;
    } else return error.DidNotStage;
    const write = (try worker.next(fixture.attached, .when_uncertain)).?;
    try std.testing.expect(write.request == .write);
    try worker.release(read);
    try Worker.run(write, &fixture.data.backend);
    try worker.complete(write, fixture.attached);
    try worker.release(write);
    try driveUntilQuiet(&fixture, &worker);
    try std.testing.expectEqual(@as(?i64, 4), capture.value);
    try std.testing.expectEqual(@as(usize, 0), worker.reading);
}

test "loam worker recovery excludes ordinary work in both directions" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var slots: [2]Worker.Slot = undefined;
    var worker: Worker = .init(&slots, fixture.data.backend.readerCapacity());
    var capture: f.Capture = .{};
    try queueAdd(&fixture, &capture);

    const write = (try worker.next(fixture.attached, .when_uncertain)).?;
    try std.testing.expect(write.request == .write);
    try std.testing.expectError(error.Busy, worker.next(fixture.attached, .forced));
    try Worker.run(write, UnknownCommit{ .inner = &fixture.data.backend });
    try worker.complete(write, fixture.attached);
    try std.testing.expect(fixture.data.store.phase == .uncertain);
    // The fenced write still holds a slot, so recovery waits for its release.
    try std.testing.expectError(error.Busy, worker.next(fixture.attached, .when_uncertain));
    try worker.release(write);

    const recovery = (try worker.next(fixture.attached, .when_uncertain)).?;
    try std.testing.expect(recovery.request == .recover);
    try std.testing.expectError(error.Busy, worker.next(fixture.attached, .when_uncertain));
    try Worker.run(recovery, &fixture.data.backend);
    try worker.complete(recovery, fixture.attached);
    try worker.release(recovery);
    try driveUntilQuiet(&fixture, &worker);
    try std.testing.expectEqual(@as(?i64, 4), capture.value);
}

test "loam worker refuses to complete a slot that has not run" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    var slots: [1]Worker.Slot = undefined;
    var worker: Worker = .init(&slots, fixture.data.backend.readerCapacity());
    var capture: f.Capture = .{};
    try queueAdd(&fixture, &capture);

    const slot = (try worker.next(fixture.attached, .when_uncertain)).?;
    try std.testing.expectError(error.WorkerNotRetired, worker.complete(slot, fixture.attached));
    try std.testing.expectError(error.Busy, worker.release(slot));
    try Worker.run(slot, &fixture.data.backend);
    try std.testing.expectError(error.StaleCompletion, Worker.run(slot, &fixture.data.backend));
    try worker.complete(slot, fixture.attached);
    try std.testing.expectError(error.StaleCompletion, worker.complete(slot, fixture.attached));
    try worker.release(slot);
    try driveUntilQuiet(&fixture, &worker);
    try std.testing.expectEqual(@as(?i64, 4), capture.value);
}

test "loam worker leaves a sibling attachment's uncertain write to its owner" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const sibling = try f.hosting.Attachment.create(std.testing.allocator, &fixture.host, &fixture.data.store, &f.behaviors, .{});
    defer sibling.destroy() catch unreachable;
    var slots: [1]Worker.Slot = undefined;
    var worker: Worker = .init(&slots, fixture.data.backend.readerCapacity());
    var sibling_slots: [1]Worker.Slot = undefined;
    var sibling_worker: Worker = .init(&sibling_slots, fixture.data.backend.readerCapacity());
    var capture: f.Capture = .{};
    try queueAdd(&fixture, &capture);

    const write = (try worker.next(fixture.attached, .when_uncertain)).?;
    try Worker.run(write, UnknownCommit{ .inner = &fixture.data.backend });
    try worker.complete(write, fixture.attached);
    try worker.release(write);
    try std.testing.expect(fixture.data.store.phase == .uncertain);
    try std.testing.expect(!sibling.awaitsRecovery());
    // The sibling has no recovery batch of its own, so it takes none.
    try sibling_worker.drive(sibling, &fixture.data.backend);
    try std.testing.expectEqual(@as(usize, 0), sibling_worker.active);
    try driveUntilQuiet(&fixture, &worker);
    try std.testing.expect(fixture.data.store.phase == .idle);
    try std.testing.expectEqual(@as(?i64, 4), capture.value);
}
