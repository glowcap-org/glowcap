//! Declared facet working sets survive repeated collection without record residency.
const std = @import("std");
const g = @import("glowcap");
const m = @import("managed.zig");
const Pair = @import("host_pair.zig").Pair;
const r = @import("report.zig");
const memory = @import("process_memory.zig");
const metrics = @import("alloc_metrics");

pub fn collect(self: *m.Managed) !void {
    for (0..20000) |_| {
        try self.finish(try self.store.prepareCollection(64));
        if (self.store.metadata.collection.phase == .idle) return;
    }
    return error.CollectionDidNotFinish;
}

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), self: *m.Managed, depth: u16, smoke: bool, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator) !void {
    const sets: []const usize = if (smoke) &.{ 8, 16 } else &.{ 8, 32, 128 };
    const distinct = @min(self.items.len, sets[sets.len - 1]);
    for (self.items[0..distinct]) |item| {
        const edge = try self.attachment.capture(item.use);
        const lease = try self.load(item.content);
        defer self.store.release(lease) catch unreachable;
        const view = try self.store.currentView(lease);
        try self.store.begin();
        try self.store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .payload = view.payload, .edges = &.{edge} }, view.revision);
        try self.finish(try self.store.prepare());
    }
    var witness = try g.driver.core.Host.init(self.allocator, @splat(0x89), @splat(0x8a), g.driver.core.Host.Options.withFrameCap(4096));
    defer witness.deinit();
    var pair = try Pair.open(&self.host, &witness, "127.0.0.1:9793");
    defer pair.close();
    const rounds: usize = if (smoke) 4 else 32;
    for (sets) |holders| {
        self.store.evict();
        const before = bytes.liveBytes();
        const slot_bytes_before = self.host.capabilities.slots.capacity * @sizeOf(@TypeOf(self.host.capabilities.slots.items[0]));
        const reads = self.reads;
        const writes = self.writes;
        const allocs = allocations.allocs;
        const start = r.now(init.io);
        var timings: r.Samples = .{};
        var facets: [128]g.driver.core.Capability = undefined;
        var held: usize = 0;
        {
            defer for (facets[0..held]) |cap| self.host.releaseCapabilityTerminal(cap, null);
            for (facets[0..holders], 0..) |*facet, index| {
                const returned = try self.host.callCapability(self.allocator, pair.session, self.items[index % distinct].use, "dependent", &.{}, 512);
                defer returned.deinit();
                try pair.drain(self, @as(?*m.Managed, null));
                if (returned.result() != .ready or returned.result().ready != .capability) return error.MissingReturnedAuthority;
                facet.* = try self.host.retainLocalCapability(self.host.localActorFor(returned.result().ready.capability).?);
                held += 1;
            }
            var steady: ?usize = null;
            for (0..rounds) |_| {
                const sample = r.now(init.io);
                try collect(self);
                for (facets[0..holders]) |facet| {
                    const called = try self.host.callCapability(self.allocator, pair.session, facet, "read", &.{}, 512);
                    defer called.deinit();
                    try pair.drain(self, @as(?*m.Managed, null));
                    if (called.result() != .ready or called.result().ready.integer != 0) return error.InvalidRetainedAuthority;
                }
                self.store.evict();
                if (self.attachment.dependent_facets != holders or self.store.cache.allocated_bytes != 0) {
                    std.debug.print("retention occupancy resources={d} ancestry={d} holders={d} facets={d} resident_bytes={d}\n", .{ self.items.len, depth, holders, self.attachment.dependent_facets, self.store.cache.allocated_bytes });
                    return error.RetainedFacetBudget;
                }
                if (steady) |previous| {
                    if (bytes.liveBytes() != previous) return error.RetainedFacetGrowth;
                } else steady = bytes.liveBytes();
                timings.add(r.elapsed(init.io, sample));
            }
            const delta = @as(i128, bytes.liveBytes()) - before;
            // Slot-array growth belongs to the whole population's high-water
            // custody. Report its exact capacity cost separately; the facet
            // budget still covers other Host/Vat index growth and two retains.
            const slot_growth = self.host.capabilities.slots.capacity * @sizeOf(@TypeOf(self.host.capabilities.slots.items[0])) - slot_bytes_before;
            const facet_delta = delta - @as(i128, slot_growth);
            if (facet_delta > holders * 1024) {
                std.debug.print("retention heap resources={d} ancestry={d} holders={d} before={d} after={d} delta={d}\n", .{ self.items.len, depth, holders, before, bytes.liveBytes(), delta });
                return error.RetainedFacetBudget;
            }
            try memory.emit(init.gpa, report, "retention-working-set", self.items.len, depth);
            const latency = timings.summarize();
            const elapsed_ns = r.elapsed(init.io, start);
            const calls = holders * (rounds + 1);
            try r.emit(init.gpa, report, "managed_retention resources={d} ancestry={d} holders={d} distinct_targets={d} rounds={d} calls={d} reads={d} writes={d} allocs={d} elapsed_ns={d} calls_per_second={d} round_p50_ns={d} round_p99_ns={d} retained_heap_delta={d} capability_slot_growth_bytes={d} facet_heap_delta={d} live_zig_heap_bytes={d} resident_bytes=0 objects={d} record_bytes={d}\n", .{ self.items.len, depth, holders, @min(distinct, holders), rounds, calls, self.reads - reads, self.writes - writes, allocations.allocs - allocs, elapsed_ns, @as(u128, calls) * std.time.ns_per_s / @max(1, elapsed_ns), latency.p50_ns, latency.p99_ns, delta, slot_growth, facet_delta, bytes.liveBytes(), self.store.metadata.objects, self.store.metadata.record_bytes });
        }
        try (try self.call(0, "read")).requireNumber(0);
        if (self.attachment.dependent_facets != 0) return error.UnreleasedRetainedFacets;
    }
}
