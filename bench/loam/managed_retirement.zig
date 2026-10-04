//! Hosted bounded cleanup separates retained identities from reclaimed payloads.
const std = @import("std");
const g = @import("glowcap");
const access = g.loam.access;
const m = @import("managed.zig");
const metrics = @import("alloc_metrics");
const memory = @import("process_memory.zig");
const r = @import("report.zig");
const publication = g.loam.hosting.publication;

const Answer = struct {
    sequence: ?u64 = null,
    idle: bool = false,
    retired: bool = false,
    fn receive(context: ?*anyopaque, result: g.actors.Resolution) void {
        const self: *Answer = @ptrCast(@alignCast(context.?));
        if (result != .fulfilled or result.fulfilled != .tagged) return;
        const value = result.fulfilled.tagged;
        if (!std.mem.eql(u8, value.tag, "access:maintenance") or value.value.len != 4) return;
        if (value.value[0] != .integer or value.value[0].integer < 0 or value.value[1] != .symbol or value.value[2] != .boolean) return;
        self.sequence = @intCast(value.value[0].integer);
        self.idle = std.mem.eql(u8, value.value[1].symbol, "idle");
        self.retired = value.value[2].boolean;
    }
};
fn call(self: *m.Managed, admin: g.driver.core.Capability, verb: []const u8, sequence: u64) !Answer {
    var answer: Answer = .{};
    _ = try self.host.vat.sendObservedFromIngress(.local, self.host.localActorFor(admin).?, .{ .verb = verb, .args = &.{.{ .integer = @intCast(sequence) }} }, .{ .ctx = &answer, .func = Answer.receive });
    try self.drain();
    if (answer.sequence != sequence + 1) return error.InvalidMaintenanceReply;
    return answer;
}
fn collect(self: *m.Managed) !void {
    for (0..20000) |_| {
        try self.finish(try self.store.prepareCollection(64));
        if (self.store.metadata.collection.phase == .idle) return;
    }
    return error.CollectionDidNotFinish;
}

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), self: *m.Managed, depth: u16, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator) !void {
    const gpa = init.gpa;
    const count = self.items.len;
    const named = @min(count, 32);
    try collect(self);
    const base_entries = (try self.db.inspect()).entries - self.store.metadata.objects;
    for (self.items[0..named], 0..) |item, index| {
        const target = try self.attachment.capture(item.use);
        const lease = try self.load(target.target);
        defer self.store.release(lease) catch unreachable;
        var entropy: publication.Entropy = @splat(0xb1);
        std.mem.writeInt(u64, entropy[0..8], index + 1, .big);
        try self.store.begin();
        const id = try access.hosting.stagePublication(&self.store, lease, entropy);
        try self.finish(try self.store.prepare());
        const recipe = try self.load(id);
        defer self.store.release(recipe) catch unreachable;
        _ = try publication.restore(self.attachment, recipe);
    }
    const admin = blk: {
        const owner_lease = try self.load(self.owner);
        defer self.store.release(owner_lease) catch unreachable;
        break :blk try self.attachment.restore(owner_lease);
    };
    defer self.host.releaseCapability(admin, 1) catch unreachable;
    var sequence: u64 = 0;
    for ([_][]const u8{ "sweep", "retire-owner" }) |phase| {
        const before_objects = self.store.metadata.objects;
        const before_bytes = self.store.metadata.record_bytes;
        const reads = self.reads;
        const writes = self.writes;
        const allocs = allocations.allocs;
        const start = r.now(init.io);
        var timings: r.Samples = .{};
        var steps: usize = 0;
        var maximum_reads: u64 = 0;
        var first = true;
        for (0..32768) |_| {
            self.store.evict();
            const prior_reads = self.reads;
            const sample = r.now(init.io);
            const answer = try call(self, admin, if (first) phase else "maintenance-step", sequence);
            first = false;
            maximum_reads = @max(maximum_reads, self.reads - prior_reads);
            sequence = answer.sequence.?;
            if (steps % 16 == 0) timings.add(r.elapsed(init.io, sample));
            steps += 1;
            if (answer.idle) {
                if (answer.retired != std.mem.eql(u8, phase, "retire-owner")) return error.InvalidOwnerRetirement;
                break;
            }
        } else return error.UnboundedMaintenance;
        // A step seeks one fixed-depth index path and prepares one bounded
        // authority path. Owner population cannot add an unrelated scan.
        if (maximum_reads > 32 + 2 * @as(u64, depth)) return error.MaintenanceReadBudget;
        try collect(self);
        const latency = timings.summarize();
        try r.emit(gpa, report, "managed_retirement phase={s} resources={d} ancestry={d} steps={d} reads={d} max_step_reads={d} writes={d} allocs={d} elapsed_ns={d} step_sample_stride=16 p50_ns={d} p99_ns={d} before_objects={d} after_objects={d} before_record_bytes={d} after_record_bytes={d} live_zig_heap_bytes={d}\n", .{
            phase, count, depth, steps, self.reads - reads, maximum_reads, self.writes - writes, allocations.allocs - allocs, r.elapsed(init.io, start), latency.p50_ns, latency.p99_ns, before_objects, self.store.metadata.objects, before_bytes, self.store.metadata.record_bytes, bytes.liveBytes(),
        });
        try memory.emit(gpa, report, phase, count, depth);
    }
    if (self.store.metadata.objects > 2 * count + 2) return error.RetainedRetiredPayload;
    const stat = try self.db.inspect();
    if (stat.entries - self.store.metadata.objects != base_entries + named) return error.LostNameReservations;
    const Name = @FieldType(g.loam.core.NameLookup, "name");
    const name: Name = .{ .schema = publication.schema.id, .bytes = @splat(0) };
    const reservation_bytes = name.key().len + self.owner.key().len;
    try r.emit(gpa, report, "managed_retired_names resources={d} ancestry={d} reservations={d} bytes_each={d} logical_bytes={d} backend_entries={d} retained_records={d}\n", .{ count, depth, named, reservation_bytes, named * reservation_bytes, stat.entries, self.store.metadata.objects });
}
