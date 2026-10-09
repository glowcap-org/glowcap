//! Returned authority and parked call storage use the shipped Host boundaries.
const std = @import("std");
const g = @import("glowcap");
const m = @import("managed.zig");
const r = @import("report.zig");
const metrics = @import("alloc_metrics");
const memory = @import("process_memory.zig");
const driver = g.driver.core;

const Pair = @import("host_pair.zig").Pair;

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), self: *m.Managed, depth: u16, smoke: bool, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator) !void {
    // A self-reference stays inside this resource's object-scoped grant. The
    // facet still owns two authority retains and evaluates both dependencies.
    const edge = try self.attachment.capture(self.items[0].use);
    const lease = try self.load(self.items[0].content);
    const view = try self.store.currentView(lease);
    try self.store.begin();
    try self.store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .payload = view.payload, .edges = &.{edge} }, view.revision);
    try self.finish(try self.store.prepare());
    try self.store.release(lease);
    var witness = try driver.Host.init(self.allocator, @splat(0x85), @splat(0x86), driver.Host.Options.withFrameCap(4096));
    defer witness.deinit();
    var lane = try Pair.open(&self.host, &witness, "127.0.0.1:9792");
    defer lane.close();
    const session = lane.session;
    const samples: usize = if (smoke) 8 else 128;
    for ([_][]const u8{ "exact", "dependent" }) |phase| {
        const reads = self.reads;
        const writes = self.writes;
        const allocs = allocations.allocs;
        var timings: r.Samples = .{};
        const start = r.now(init.io);
        for (0..samples) |_| {
            const sample = r.now(init.io);
            const returned = try self.host.callCapability(self.allocator, session, self.items[0].use, phase, &.{}, 512);
            defer returned.deinit();
            try lane.drain(self, @as(?*m.Managed, null));
            if (returned.result() == .failed) std.debug.print("managed_reference phase={s} refusal={s}\n", .{ phase, returned.result().failed.message });
            if (returned.result() != .ready or returned.result().ready != .capability) return error.MissingReturnedAuthority;
            const called = try self.host.callCapability(self.allocator, session, returned.result().ready.capability, "read", &.{}, 512);
            defer called.deinit();
            try lane.drain(self, @as(?*m.Managed, null));
            if (called.result() != .ready or called.result().ready.integer != 0) return error.InvalidReturnedAuthority;
            timings.add(r.elapsed(init.io, sample));
        }
        // A normal actor turn reclaims boxes whose last hold just retired.
        try (try self.call(0, "read")).requireNumber(0);
        const latency = timings.summarize();
        const elapsed_ns = r.elapsed(init.io, start);
        try r.emit(init.gpa, report, "managed_reference phase={s} resources={d} ancestry={d} groups={d} calls={d} reads={d} writes={d} allocs={d} elapsed_ns={d} ops_per_second={d} p50_ns={d} p99_ns={d} live_zig_heap_bytes={d}\n", .{ phase, self.items.len, depth, samples, samples * 2 + 1, self.reads - reads, self.writes - writes, allocations.allocs - allocs, elapsed_ns, @as(u128, samples * 2 + 1) * std.time.ns_per_s / @max(1, elapsed_ns), latency.p50_ns, latency.p99_ns, bytes.liveBytes() });
        if (self.writes != writes or self.attachment.dependent_facets != 0) return error.ReferenceCustodyGrowth;
    }
    // Keep eight independent facets through cold calls and repeated collection.
    // Each hold keeps two authorities, without retaining their record buffers.
    self.store.evict();
    const before_facets = bytes.liveBytes();
    var facets: [8]driver.Capability = undefined;
    var held: usize = 0;
    defer for (facets[0..held]) |cap| self.host.releaseCapabilityTerminal(cap, null);
    for (&facets) |*cap| {
        const returned = try self.host.callCapability(self.allocator, session, self.items[0].use, "dependent", &.{}, 512);
        defer returned.deinit();
        try lane.drain(self, @as(?*m.Managed, null));
        if (returned.result() != .ready) return error.MissingReturnedAuthority;
        cap.* = try self.host.retainLocalCapability(self.host.localActorFor(returned.result().ready.capability).?);
        held += 1;
    }
    const collection_rounds: usize = if (smoke) 4 else 32;
    for (0..collection_rounds) |_| {
        for (0..20000) |_| {
            try self.finish(try self.store.prepareCollection(64));
            if (self.store.metadata.collection.phase == .idle) break;
        } else return error.CollectionDidNotFinish;
        const called = try self.host.callCapability(self.allocator, session, facets[0], "read", &.{}, 512);
        defer called.deinit();
        try lane.drain(self, @as(?*m.Managed, null));
        if (called.result() != .ready or called.result().ready.integer != 0) return error.InvalidReturnedAuthority;
    }
    self.store.evict();
    if (self.store.cache.allocated_bytes != 0 or self.attachment.dependent_facets != 8) return error.ReferenceCustodyGrowth;
    try memory.emit(init.gpa, report, "held-facets", self.items.len, depth);
    try r.emit(init.gpa, report, "managed_reference phase=held-facets resources={d} ancestry={d} facets=8 authorities_per_facet=2 collection_rounds={d} retained_heap_delta={d} live_zig_heap_bytes={d} resident_bytes=0 objects={d} record_bytes={d}\n", .{ self.items.len, depth, collection_rounds, @as(i128, bytes.liveBytes()) - before_facets, bytes.liveBytes(), self.store.metadata.objects, self.store.metadata.record_bytes });
    var calls: [8]*driver.Host.Call = undefined;
    var admitted: usize = 0;
    defer for (calls[0..admitted]) |call| call.deinit();
    const before = bytes.liveBytes();
    for (&calls) |*call| {
        call.* = try self.host.callCapability(self.allocator, session, facets[0], "read", &.{}, 512);
        admitted += 1;
    }
    try self.host.flushSession(session);
    try self.attachment.advance();
    if (self.attachment.pending_bytes != 8 * self.attachment.options.call_bytes) return error.ParkedCallBudget;
    var reads: usize = 0;
    for (self.attachment.reads) |read| if (read != null) {
        reads += 1;
    };
    if (reads != 1) return error.UncoalescedParkedCalls;
    try memory.emit(init.gpa, report, "parked-facets", self.items.len, depth);
    try r.emit(init.gpa, report, "managed_reference phase=parked-facets resources={d} ancestry={d} calls=8 reply_bytes_each=512 call_bytes_each={d} pending_bytes={d} coalesced_reads=1 retained_heap_delta={d} live_zig_heap_bytes={d}\n", .{ self.items.len, depth, self.attachment.options.call_bytes, self.attachment.pending_bytes, bytes.liveBytes() - before, bytes.liveBytes() });
    const refused = try self.host.callCapability(self.allocator, session, facets[0], "read", &.{}, 512);
    defer refused.deinit();
    try self.host.flushSession(session);
    if (refused.result() != .failed or self.attachment.pending_bytes != 8 * self.attachment.options.call_bytes) return error.ParkedCallBudget;
    try lane.drain(self, @as(?*m.Managed, null));
    for (calls) |call| if (call.result() != .ready or call.result().ready.integer != 0) return error.InvalidParkedReply;
}
