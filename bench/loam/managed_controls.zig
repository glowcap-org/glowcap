//! Management dependency walks use one transient lease per ancestor.
const std = @import("std");
const g = @import("glowcap");
const m = @import("managed.zig");
const setup = @import("managed_setup.zig");
const metrics = @import("alloc_metrics");
const memory = @import("process_memory.zig");
const r = @import("report.zig");

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), self: *m.Managed, depth: u16, smoke: bool, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator) !void {
    const edge = try self.attachment.capture(self.items[0].control);
    const endpoint_lease = try self.load(edge.target);
    const endpoint = try g.loam.access.records.EndpointRecord.decode(try self.store.currentView(endpoint_lease));
    try self.store.release(endpoint_lease);
    const lease = try self.load(endpoint.descriptor);
    var held = try self.capabilities.restoreControl(lease);
    try self.store.release(lease);
    defer held.release();
    const reads = self.reads;
    const writes = self.writes;
    const allocs = allocations.allocs;
    const objects = self.store.metadata.objects;
    var timings: r.Samples = .{};
    const count: usize = if (smoke) 4 else 32;
    const start = r.now(init.io);
    for (0..count) |_| {
        self.store.evict();
        const sample = r.now(init.io);
        const operation = try held.begin(m.record_capacity);
        defer operation.deinit() catch unreachable;
        try setup.pump(self, operation);
        for (0..256) |_| {
            operation.prepareAttenuationCopying(.{ .revoke = true, .delegate_control = true }) catch |err| {
                if (err != error.RecordUnloaded) return err;
                try setup.pump(self, operation);
                continue;
            };
            break;
        } else return error.NoProgress;
        try self.store.begin();
        const descriptor = try self.capabilities.stageAttenuatedControl(operation, false);
        try self.finish(try self.store.prepare());
        const child_lease = try self.load(descriptor);
        const child = try self.capabilities.restoreControl(child_lease);
        try self.store.release(child_lease);
        held.release();
        held = child;
        timings.add(r.elapsed(init.io, sample));
    }
    // Each attenuation creates a descriptor and one retained batch.
    if (self.store.metadata.objects - objects != 2 * count or self.writes - writes != count) return error.ControlCostMismatch;
    if (self.reads - reads > count * (32 + 2 * @as(usize, depth) + count)) return error.ControlReadBudget;
    try memory.emit(init.gpa, report, "attenuate-control", self.items.len, depth);
    const latency = timings.summarize();
    try r.emit(init.gpa, report, "managed phase=attenuate-control resources={d} ancestry={d} management_depth={d} ops={d} reads={d} writes={d} allocs={d} elapsed_ns={d} p50_ns={d} p99_ns={d} live_zig_heap_bytes={d} resident_bytes={d} objects={d} record_bytes={d}\n", .{ self.items.len, depth, count, count, self.reads - reads, self.writes - writes, allocations.allocs - allocs, r.elapsed(init.io, start), latency.p50_ns, latency.p99_ns, bytes.liveBytes(), self.store.cache.allocated_bytes, self.store.metadata.objects, self.store.metadata.record_bytes });
    const terminal = try held.begin(m.record_capacity);
    defer terminal.deinit() catch unreachable;
    try setup.pump(self, terminal);
    const changed = for (0..256) |_| {
        const changed = terminal.prepareControlRevocation() catch |err| {
            if (err != error.RecordUnloaded) return err;
            try setup.pump(self, terminal);
            continue;
        };
        break changed;
    } else return error.NoProgress;
    if (!changed) return error.UnchangedControl;
    try self.store.begin();
    if (!try terminal.stageControlRevocation()) return error.UnchangedControl;
    try self.finish(try self.store.prepare());
    try (try self.call(0, "read")).requireNumber(0);
}
