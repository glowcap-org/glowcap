//! Isolated collection counts over a fixed graph. Volatile commits exercise the
//! real batch contract; timings here do not model storage or fsync throughput.
const std = @import("std");
const builtin = @import("builtin");
const g = @import("glowcap");
const core = g.loam.core;
const r = @import("report.zig");
const schemas = [_]core.Schema{.{ .id = 1, .version = 1, .max_payload = 1, .max_edges = 1 }};
const record_bytes = 1024;
const cache_slots = 2;

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), smoke: bool) !void {
    try r.emit(init.gpa, report, "Loam collection counts mode={s} arch={s} os={s} backend=volatile cache_slots={d} max_record_bytes={d} durability=none\n", .{
        @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), cache_slots, record_bytes,
    });
    const chain: usize = if (smoke) 128 else 1024;
    const garbage: usize = if (smoke) 64 else 256;
    const holds: []const usize = if (smoke) &.{ 0, 8, 32 } else &.{ 0, 32, 128 };
    for (holds) |held| for ([_]usize{ 8, 64, 256 }) |work| {
        try measure(init, report, chain, garbage, held, work);
    };
}

fn measure(init: std.process.Init, report: *std.ArrayList(u8), chain: usize, garbage: usize, held: usize, work: usize) !void {
    var backend = try g.loam.Volatile.init(init.gpa, @fromBackingInt(75), 16 * 1024 * 1024);
    defer backend.deinit();
    var allocator: Counter = .{ .backing = init.gpa };
    var store = try core.Store.init(allocator.allocator(), try backend.open(), &schemas, .{
        .records = .{ .max_record_bytes = record_bytes, .max_edges = 1 },
        .cache_slots = cache_slots,
        .max_leases = 2,
        .resident_bytes = cache_slots * record_bytes,
        .max_retentions = 128,
        .max_collection_roots = 512,
    });
    defer store.deinit() catch unreachable;
    const ids = try init.gpa.alloc(core.ObjectId, chain);
    defer init.gpa.free(ids);
    // Build backwards: each strong target already exists when its parent commits.
    for (0..chain) |offset| {
        const index = chain - offset - 1;
        try store.begin();
        ids[index] = try store.allocateId();
        try store.putCopying(.{
            .id = ids[index],
            .revision = 0,
            .schema = 1,
            .payload = "x",
            .rooted = index == 0,
            .edges = if (index + 1 == chain) &.{} else &.{.{ .target = ids[index + 1] }},
        }, null);
        try finish(&store, &backend, try store.prepare());
    }
    for (0..garbage / 2) |_| {
        try store.begin();
        const a = try store.allocateId();
        const b = try store.allocateId();
        try store.putCopying(.{ .id = a, .revision = 0, .schema = 1, .payload = "x", .edges = &.{.{ .target = b }} }, null);
        try store.putCopying(.{ .id = b, .revision = 0, .schema = 1, .payload = "x", .edges = &.{.{ .target = a }} }, null);
        try finish(&store, &backend, try store.prepare());
    }
    var tokens: [128]core.Retention = undefined;
    var admitted: usize = 0;
    defer for (tokens[0..admitted]) |token| store.releaseRetention(token) catch unreachable;
    for (tokens[0..held], ids[0..held]) |*token, id| {
        token.* = try store.retain(id);
        admitted += 1;
    }
    var batches: usize = 0;
    var root_ids: usize = 0;
    var seed_lookups: usize = 0;
    var already_marked: usize = 0;
    var trace_steps: u64 = 0;
    var preparation_allocs: usize = 0;
    const scratch_before = allocator.scratch_allocs;
    while (true) {
        const before = store.metadata.collection;
        const allocations = allocator.allocs;
        const ticket = try store.prepareCollection(work);
        preparation_allocs += allocator.allocs - allocations;
        const batch = try store.beginWrite(ticket);
        root_ids += batch.collection.?.roots.len;
        // Count predicted root-origin lookups, not all backend reads. The
        // baseline crossed clearing within its first batch; a clean custody
        // cycle begins directly in roots. Restart clearing is a separate barrier.
        const seeds = before.tracing() or before.phase == .idle;
        if (seeds) for (batch.collection.?.roots) |id| {
            seed_lookups += 1;
            const key = "gm".* ++ id.key();
            if (backend.rows.get(.{ .bytes = key, .length = key.len }) != null) already_marked += 1;
        };
        try std.testing.expectError(error.Busy, store.acquire(ids[0]));
        const outcome = backend.commit(batch);
        try store.completeWrite(ticket, outcome);
        if (outcome != .committed) return error.CollectionFailed;
        trace_steps += store.metadata.collection.head - before.head;
        batches += 1;
        if (store.metadata.collection.phase == .idle) break;
        if (batches > 20000) return error.CollectionDidNotFinish;
    }
    if (store.metadata.objects != chain or store.metadata.collection.reclaimed_objects != garbage or trace_steps != chain) return error.InvalidCollection;
    if (root_ids != held or seed_lookups != held or already_marked != 0 or allocator.scratch_allocs - scratch_before != 1) return error.RepeatedCollectionCustody;
    try r.emit(init.gpa, report, "collection_cost backend=volatile chain={d} garbage={d} held={d} work_limit={d} batches={d} commits={d} submitted_root_ids={d} root_key_bytes_hashed={d} predicted_seed_mark_lookups={d} pre_batch_marked_seeds={d} traced_records={d} reclaimed={d} prepare_allocs={d} scratch_allocs={d} foreground_fences={d}\n", .{
        chain, garbage, held, work, batches, batches, root_ids, root_ids * 33 * 2, seed_lookups, already_marked, trace_steps, garbage, preparation_allocs, allocator.scratch_allocs - scratch_before, batches,
    });
}

fn finish(store: *core.Store, backend: *g.loam.Volatile, ticket: core.Ticket) !void {
    const outcome = backend.commit(try store.beginWrite(ticket));
    try store.completeWrite(ticket, outcome);
    if (outcome != .committed) return error.CommitFailed;
}

const Counter = struct {
    backing: std.mem.Allocator,
    allocs: usize = 0,
    scratch_allocs: usize = 0,

    fn allocator(self: *Counter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const bytes = self.backing.rawAlloc(len, alignment, ret) orelse return null;
        self.allocs += 1;
        if (len == record_bytes and alignment == std.mem.Alignment.of(u8)) self.scratch_allocs += 1;
        return bytes;
    }
    fn resize(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(bytes, alignment, len, ret);
    }
    fn remap(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(bytes, alignment, len, ret);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ret);
    }
};
