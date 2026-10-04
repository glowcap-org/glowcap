//! Native observer contexts measure quota, bounded replay fanout and cancellation.
const std = @import("std");
const g = @import("glowcap");
const access = g.loam.access;
const m = @import("managed.zig");
const setup = @import("managed_setup.zig");
const metrics = @import("alloc_metrics");
const memory = @import("process_memory.zig");
const r = @import("report.zig");
const capacity = access.records.ObservationIndexRecord.capacity;

fn register(self: *m.Managed, key: [32]u8) !g.loam.core.ObjectId {
    const source = try self.parent_use.begin(m.record_capacity);
    defer source.deinit() catch unreachable;
    try setup.pump(self, source);
    const registration = for (0..256) |_| {
        const registration = access.storage.ObservationRegistration.init(source, self.parent_resource, key) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try setup.pump(self, source);
            continue;
        };
        break registration;
    } else return error.NoProgress;
    defer registration.deinit() catch unreachable;
    try setup.pump(self, registration);
    try self.store.begin();
    errdefer if (self.store.phase == .staging) self.store.abort() catch unreachable;
    const id = try registration.stage(@splat(null));
    try self.finish(try self.store.prepare());
    return id;
}
fn poll(self: *m.Managed, id: g.loam.core.ObjectId, cursor: ?access.storage.Observation.Cursor) !access.storage.Observation.Result {
    const lease = try self.load(id);
    const observation = access.storage.Observation.init(&self.capabilities, lease, cursor, m.record_capacity) catch |err| {
        try self.store.release(lease);
        return err;
    };
    try self.store.release(lease);
    defer observation.deinit() catch unreachable;
    try setup.pump(self, observation);
    return observation.result();
}
fn cancel(self: *m.Managed, id: g.loam.core.ObjectId) !void {
    const lease = try self.load(id);
    const closing = access.storage.ObservationCancellation.init(&self.store, lease) catch |err| {
        try self.store.release(lease);
        return err;
    };
    try self.store.release(lease);
    defer closing.deinit() catch unreachable;
    try setup.pump(self, closing);
    try self.store.begin();
    errdefer if (self.store.phase == .staging) self.store.abort() catch unreachable;
    if (!try closing.stage(null)) return error.UnchangedObservation;
    try self.finish(try self.store.prepare());
}

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), self: *m.Managed, depth: u16, smoke: bool, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator) !void {
    var contexts: [capacity]g.loam.core.ObjectId = undefined;
    var cursors: [capacity]access.storage.Observation.Cursor = undefined;
    var key: [32]u8 = undefined;
    const objects = self.store.metadata.objects;
    for ([_][]const u8{ "observe-register", "observe-unchanged", "observe-fanout", "observe-cancel" }) |phase| {
        const reads = self.reads;
        const writes = self.writes;
        const allocs = allocations.allocs;
        var timings: r.Samples = .{};
        var operations: usize = 0;
        const start = r.now(init.io);
        if (std.mem.eql(u8, phase, "observe-register")) {
            for (&contexts, &cursors) |*context, *cursor| {
                const sample = r.now(init.io);
                std.Io.random(init.io, &key);
                context.* = try register(self, key);
                cursor.* = (try poll(self, context.*, null)).cursor;
                operations += 1;
                timings.add(r.elapsed(init.io, sample));
            }
            if (self.store.metadata.objects - objects != capacity + 1) return error.ObservationCostMismatch;
            const revision = self.store.metadata.revision;
            if (register(self, key)) |_| return error.UnboundedObservations else |err| if (err != error.ObservationCapacity) return err;
            if (self.store.metadata.revision != revision) return error.ObservationQuotaWrite;
        } else if (std.mem.eql(u8, phase, "observe-unchanged")) {
            self.store.evict();
            for (contexts, cursors) |context, cursor| {
                const sample = r.now(init.io);
                const result = try poll(self, context, cursor);
                if (result.changed or result.resync or !std.mem.eql(u8, &result.cursor, &cursor)) return error.ChangedIdleObservation;
                operations += 1;
                timings.add(r.elapsed(init.io, sample));
            }
            if (self.writes != writes) return error.ObservationReadWrite;
        } else if (std.mem.eql(u8, phase, "observe-fanout")) {
            for (0..if (smoke) @as(usize, 2) else 16) |round| {
                _ = try setup.issue(self, if (round % 2 == 0) .{ .pause = self.parent_grant } else .{ .resume_access = self.parent_grant });
                self.store.evict();
                for (contexts, &cursors) |context, *cursor| {
                    const sample = r.now(init.io);
                    const result = try poll(self, context, cursor.*);
                    if (!result.changed or result.resync or !result.notices.access) return error.MissedObservation;
                    const expected: std.meta.Tag(access.core.GrantView.Access) = if (round % 2 == 0) .paused else .active;
                    if (std.meta.activeTag(result.snapshot.use.access) != expected) return error.StaleObservation;
                    cursor.* = result.cursor;
                    operations += 1;
                    timings.add(r.elapsed(init.io, sample));
                }
            }
            if (self.reads - reads > operations * (40 + 2 * @as(usize, depth))) return error.ObservationReadBudget;
        } else {
            for (contexts) |context| {
                const sample = r.now(init.io);
                try cancel(self, context);
                operations += 1;
                timings.add(r.elapsed(init.io, sample));
            }
            if (self.writes - writes != capacity) return error.ObservationCancellationCost;
            std.Io.random(init.io, &key);
            const replacement = try register(self, key);
            try cancel(self, replacement);
        }
        if (self.capabilities.operations != 0 or self.capabilities.observations != 0) return error.RetainedObservationOperations;
        try memory.emit(init.gpa, report, phase, self.items.len, depth);
        const latency = timings.summarize();
        try r.emit(init.gpa, report, "managed phase={s} resources={d} ancestry={d} contexts={d} ops={d} reads={d} writes={d} allocs={d} elapsed_ns={d} p50_ns={d} p99_ns={d} live_zig_heap_bytes={d} resident_bytes={d} objects={d} record_bytes={d}\n", .{ phase, self.items.len, depth, capacity, operations, self.reads - reads, self.writes - writes, allocations.allocs - allocs, r.elapsed(init.io, start), latency.p50_ns, latency.p99_ns, bytes.liveBytes(), self.store.cache.allocated_bytes, self.store.metadata.objects, self.store.metadata.record_bytes });
    }
}
