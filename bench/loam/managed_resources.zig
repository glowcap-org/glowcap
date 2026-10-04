//! Resource lifecycle costs retain bounded model and index working sets.
const std = @import("std");
const g = @import("glowcap");
const m = @import("managed.zig");
const setup = @import("managed_setup.zig");
const metrics = @import("alloc_metrics");
const memory = @import("process_memory.zig");
const r = @import("report.zig");

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), self: *m.Managed, depth: u16, smoke: bool, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator) !void {
    const destination = try setup.resource(self, self.parent_resource);
    const samples = if (smoke) @as(usize, 8) else 128;
    for ([_][]const u8{ "move-resource", "children" }) |phase| {
        const reads = self.reads;
        const writes = self.writes;
        const allocs = allocations.allocs;
        var timings: r.Samples = .{};
        const start = r.now(init.io);
        var items: usize = 0;
        for (0..if (std.mem.eql(u8, phase, "children")) @as(usize, 1) else samples) |i| {
            self.store.evict();
            const sample = r.now(init.io);
            if (std.mem.eql(u8, phase, "move-resource")) {
                const target = self.items[i % self.items.len].resource;
                try move(self, target, destination);
                try move(self, target, self.parent_resource);
                items += 2;
            } else {
                const operation = try self.parent_use.begin(m.record_capacity);
                defer operation.deinit() catch unreachable;
                try setup.pump(self, operation);
                const cursor = try children(self, operation);
                defer cursor.deinit() catch unreachable;
                for (0..self.items.len * 128 + 128) |_| switch (try cursor.advance()) {
                    .waiting => {},
                    .read => |request| {
                        self.reads += 1;
                        try cursor.completeRead(request.ticket, self.db.read(request));
                    },
                    .item => items += 1,
                    .done => break,
                };
                if (items != self.items.len + 1) return error.MissingChild;
            }
            timings.add(r.elapsed(init.io, sample));
        }
        if (std.mem.eql(u8, phase, "move-resource") and self.reads - reads > samples * (64 + 8 * @as(usize, depth))) return error.ResourceMoveReadBudget;
        if (std.mem.eql(u8, phase, "children") and self.reads - reads > (self.items.len + 1) * (16 + 2 * @as(usize, depth))) return error.ChildReadBudget;
        try memory.emit(init.gpa, report, phase, self.items.len, depth);
        const latency = timings.summarize();
        try r.emit(init.gpa, report, "managed phase={s} resources={d} ancestry={d} ops={d} groups={d} reads={d} writes={d} allocs={d} elapsed_ns={d} p50_ns={d} p99_ns={d} live_zig_heap_bytes={d} resident_bytes={d}\n", .{ phase, self.items.len, depth, items, timings.count, self.reads - reads, self.writes - writes, allocations.allocs - allocs, r.elapsed(init.io, start), latency.p50_ns, latency.p99_ns, bytes.liveBytes(), self.store.cache.allocated_bytes });
    }
}

fn move(self: *m.Managed, target: g.loam.access.core.ResourceId, parent: g.loam.access.core.ResourceId) !void {
    const operation = try self.parent_use.begin(m.record_capacity);
    defer operation.deinit() catch unreachable;
    try setup.pump(self, operation);
    for (0..256) |_| {
        _ = operation.prepareResourceCopying(target, .{ .move = parent }, .{ .permissions = &.{@fromBackingInt(@intCast(20))} }) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try setup.pump(self, operation);
            continue;
        };
        break;
    }
    try setup.pump(self, operation);
    try self.store.begin();
    if (!try operation.stageResource()) return error.UnchangedMove;
    try self.finish(try self.store.prepare());
}

fn children(self: *m.Managed, operation: *g.loam.access.storage.Operation) !*g.loam.access.storage.Children {
    for (0..256) |_| {
        return operation.children(self.parent_resource, .{ .permissions = &.{@fromBackingInt(@intCast(10))} }) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try setup.pump(self, operation);
            continue;
        };
    }
    return error.NoProgress;
}
