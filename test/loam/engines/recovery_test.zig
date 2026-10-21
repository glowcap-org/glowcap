//! A disk commit with an unknown outcome resolves on the same open store, which keeps its lock and open count.
const std = @import("std");
const core = @import("loam_core");
const engine = @import("engine_fixture");
const f = @import("loam_test_support");
extern "c" fn loam_test_commit_unknown(before: c_int) void;
extern "c" fn loam_test_recovery_failure() void;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;

test "uncertain disk commit refreshes under custody and resolves the original Store" {
    for ([_]bool{ false, true }) |before| {
        var tmp = try engine.Temp.init();
        defer tmp.deinit();
        var db = try engine.open(tmp.path, .create, f.id);
        defer db.close() catch unreachable;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var store = try core.Store.init(arena.allocator(), db.metadata, &f.schemas, f.limits);
        var store_open = true;
        // best-effort: a failed assertion is the report, not its busy teardown.
        defer if (store_open) store.deinit() catch {};
        const incarnation = store.metadata.incarnation;
        const initial = try db.inspect();
        const capacity = capacityOf(initial) + 32 * initial.page_bytes;
        try db.grow(capacity);
        var snapshot = try db.beginRead();
        var reading = true;
        defer if (reading) snapshot.end();
        _ = try core.backend.metadata(&snapshot);
        try store.begin();
        const object = try store.allocateId();
        try store.putCopying(f.record(object, "recovery"), null);
        const ticket = try store.prepare();
        const batch = try store.beginWrite(ticket);
        loam_test_commit_unknown(@intFromBool(before));
        const outcome = db.commit(batch);
        try std.testing.expectEqual(.unknown, std.meta.activeTag(outcome));
        try store.completeWrite(ticket, outcome);
        try std.testing.expectError(error.Busy, db.recover(batch));
        try std.testing.expectError(error.ReopenRequired, db.beginRead());
        try std.testing.expectError(error.ReopenRequired, db.beginWrite());
        snapshot.end();
        reading = false;
        // Refresh must survive a failed reopen, retain custody, and never
        // create a new data file in place of the one it cannot find.
        var source_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var parked_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const source = try std.fmt.bufPrintSentinel(&source_buf, "{s}/" ++ engine.data_file, .{tmp.path}, 0);
        const parked = try std.fmt.bufPrintSentinel(&parked_buf, "{s}/parked-data", .{tmp.path}, 0);
        try std.testing.expectEqual(@as(c_int, 0), rename(source, parked));
        var parking = true;
        defer if (parking) {
            std.debug.assert(rename(parked, source) == 0);
        };
        if (db.recover(batch)) |_| return error.TestExpectedRecoveryFailure else |_| {}
        try std.testing.expect(std.c.access(source, std.c.F_OK) != 0);
        try std.testing.expectError(error.ReopenRequired, db.beginRead());
        try std.testing.expectError(error.ReopenRequired, db.beginWrite());
        try std.testing.expectError(error.CustodyUnavailable, engine.open(tmp.path, .open, f.id));
        try std.testing.expectEqual(@as(c_int, 0), rename(parked, source));
        parking = false;
        // A fresh receipt still cannot establish durability if recovery's
        // own flush fails. Its failure must retain the fence and custody too.
        loam_test_recovery_failure();
        try std.testing.expectError(error.StorageFailure, db.recover(batch));
        try std.testing.expectError(error.ReopenRequired, db.beginRead());
        try std.testing.expectError(error.ReopenRequired, db.beginWrite());
        try std.testing.expectError(error.CustodyUnavailable, engine.open(tmp.path, .open, f.id));
        const resolution = try db.recover(batch);
        try std.testing.expectEqual(@as(std.meta.Tag(core.Resolution), if (before) .unchanged else .committed), std.meta.activeTag(resolution));
        try store.resolve(ticket, resolution);
        try std.testing.expectEqual(incarnation, store.metadata.incarnation);
        try std.testing.expectEqual(capacity, capacityOf(try db.inspect()));
        {
            var read = try db.beginRead();
            defer read.end();
            try std.testing.expectEqual(!before, (try read.get(&object.key())) != null);
        }
        try store.begin();
        try store.putCopying(f.record(try store.allocateId(), "after-recovery"), null);
        const next_ticket = try store.prepare();
        const next = db.commit(try store.beginWrite(next_ticket));
        try std.testing.expectEqual(.committed, std.meta.activeTag(next));
        try store.completeWrite(next_ticket, next);
        try store.deinit();
        store_open = false;
    }
}

fn capacityOf(stat: anytype) usize {
    return if (@hasField(@TypeOf(stat), "map_bytes")) stat.map_bytes else stat.capacity_bytes;
}
