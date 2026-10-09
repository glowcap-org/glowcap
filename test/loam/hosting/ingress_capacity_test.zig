//! Loam retained working sets and Vat queued messages have distinct byte owners.
const std = @import("std");
const f = @import("fixture.zig");
const metrics = @import("../../support/alloc_metrics.zig");
const Operation = @typeInfo(@FieldType(f.hosting.Attachment, "operations")).pointer.child;
const Memory = @FieldType(Operation, "memory");
const Bound = f.hosting.references.AllocationBound;

test "loam canceled ingress retires its retained call without failing unrelated work" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    defer fixture.drain() catch unreachable;
    const ingress = try fixture.host.vat.openIngress();
    var abandoned: f.Capture = .{};
    _ = try fixture.host.vat.sendObservedFromIngress(ingress, fixture.host.localActorFor(fixture.root).?, .{ .verb = "add", .args = &.{.{ .integer = 9 }} }, .{ .ctx = &abandoned, .func = f.Capture.record });
    _ = try fixture.host.vat.driveIngressBudgeted(ingress, 64);
    try std.testing.expect(fixture.attached.hasPendingWork());
    try fixture.host.vat.cancelIngress(ingress, "caller disconnected");
    var survivor: f.Capture = .{};
    try fixture.send("get", &.{}, &survivor);
    try fixture.attached.advance();
    try fixture.drain();
    try std.testing.expect(abandoned.broken);
    try std.testing.expectEqual(@as(?i64, 0), survivor.value);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
}

test "loam fresh inventory growth allowance matches observed spines when resizing refuses" {
    var bound: Bound = .{};
    try bound.includeArrayGrowth(f.driver.Capability, 129);
    var memory: Memory = undefined;
    memory.init(std.testing.allocator, try bound.physicalBytes());
    defer memory.deinit();
    var traffic: metrics.AllocationTraffic(Bound) = .{ .backing = memory.working.allocator() };
    var list: std.ArrayList(f.driver.Capability) = .empty;
    defer list.deinit(traffic.allocator());
    for (0..129) |_| try list.append(traffic.allocator(), undefined);
    try std.testing.expectEqualDeep(bound, traffic.demand);
    try std.testing.expect(list.capacity >= 129);
}

test "loam aggregate allocation allowance covers split payloads without multiplying their sum" {
    var bound: Bound = .{};
    try bound.includeTotal(1024, 64, 32);
    var traffic: metrics.AllocationTraffic(Bound) = .{ .backing = std.testing.allocator };
    var memory: Memory = undefined;
    memory.init(traffic.allocator(), try bound.physicalBytes());
    defer memory.deinit();
    var observed: Bound = .{};
    var borrows: [32][]align(64) u8 = undefined;
    for (&borrows, 0..) |*borrow, index| {
        const length: usize = if (index == 31) 497 else 17;
        borrow.* = try memory.working.allocator().alignedAlloc(u8, .fromByteUnits(64), length);
        try observed.include(length, 64, 1);
        @memset(borrow.*, @intCast(index));
    }
    try std.testing.expectEqualDeep(observed, bound);
    try std.testing.expect(traffic.demand.bytes <= try bound.physicalBytes());
    for (borrows, 0..) |borrow, index| for (borrow) |byte| try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
    var repeated: Bound = .{};
    try repeated.include(1024, 64, 32);
    try std.testing.expect(bound.bytes < repeated.bytes);
    const saved = bound;
    try std.testing.expectError(error.Overflow, bound.includeTotal(std.math.maxInt(usize), 64, 32));
    try std.testing.expectEqualDeep(saved, bound);
}

test "loam physical call bound admits mixed alignment demands and one shared scratch peak" {
    var bound: Bound = .{};
    for (0..128) |index| try bound.include(1 + (index * 97) % 1024, @as(usize, 1) << @intCast(index % 8), 1);
    var temporary: Bound = .{};
    try temporary.include(4096, 64, 1);
    try bound.merge(temporary);
    var live: metrics.LiveBytesAllocator = .{ .backing = std.testing.allocator };
    var memory: Memory = undefined;
    memory.init(live.allocator(), try bound.physicalBytes());
    var borrows: [128][]u8 = undefined;
    for (&borrows, 0..) |*borrow, index| {
        const alignment: std.mem.Alignment = .fromByteUnits(@as(usize, 1) << @intCast(index % 8));
        const allocator = if (index % 3 == 0) memory.input.allocator() else memory.working.allocator();
        const length = 1 + (index * 97) % 1024;
        const pointer = allocator.rawAlloc(length, alignment, @returnAddress()) orelse return error.OutOfMemory;
        borrow.* = pointer[0..length];
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(pointer) % alignment.toByteUnits());
        @memset(borrow.*, @intCast(index));
        var scratch = memory.scratch();
        _ = try scratch.allocator().alignedAlloc(u8, .fromByteUnits(64), 4096);
        try std.testing.expectEqual(memory.backing.used, live.liveBytes());
        scratch.deinit();
    }
    for (borrows, 0..) |borrow, index| for (borrow) |byte| try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
    memory.deinit();
    try std.testing.expectEqual(@as(u64, 0), live.liveBytes());
    const saved = bound;
    try std.testing.expectError(error.Overflow, bound.include(std.math.maxInt(usize), 2, 1));
    try std.testing.expectEqualDeep(saved, bound);
    try std.testing.expectError(error.Overflow, (Bound{ .bytes = std.math.maxInt(usize) }).physicalBytes());
    try std.testing.expectError(error.Overflow, (Bound{ .allocations = std.math.maxInt(usize) }).physicalBytes());
}

test "loam temporary call storage retires around retained allocations under one quota" {
    var live: metrics.LiveBytesAllocator = .{ .backing = std.testing.allocator };
    var memory: Memory = undefined;
    memory.init(live.allocator(), 8192);
    const input = try memory.input.allocator().dupe(u8, "input survives scratch");
    const before = memory.backing.used;
    var scratch = memory.scratch();
    const temporary = try scratch.allocator().alloc(u8, 2048);
    @memset(temporary, 0xab);
    const temporary_bytes = memory.backing.used - before;
    // Persistent work is allocated after scratch. Reclaiming scratch must
    // neither retain its interior blocks nor invalidate this later borrow.
    const retained = try memory.working.allocator().dupe(u8, "reply survives scratch");
    const persistent = memory.backing.used - temporary_bytes;
    try std.testing.expectError(error.OutOfMemory, scratch.allocator().alloc(u8, 8192));
    try std.testing.expectEqualSlices(u8, &@as([2048]u8, @splat(0xab)), temporary);
    scratch.deinit();
    try std.testing.expectEqual(persistent, memory.backing.used);
    try std.testing.expectEqual(persistent, live.liveBytes());
    for (0..32) |_| {
        var next = memory.scratch();
        _ = try next.allocator().alloc(u8, 2048);
        try std.testing.expectEqual(persistent + temporary_bytes, live.liveBytes());
        next.deinit();
        try std.testing.expectEqual(persistent, live.liveBytes());
    }
    try std.testing.expectEqualStrings("input survives scratch", input);
    try std.testing.expectEqualStrings("reply survives scratch", retained);
    memory.deinit();
    try std.testing.expectEqual(@as(u64, 0), live.liveBytes());
}

test "loam call blocks clamp growth and refuse one byte short without changing custody" {
    var memory: Memory = undefined;
    memory.init(std.testing.allocator, 256);
    defer memory.deinit();
    const allocator = memory.working.allocator();
    const first = try allocator.alloc(u8, 80);
    @memset(first, 0xab);
    const initial = memory.backing.used;
    const header = initial - first.len;
    var second = try allocator.alloc(u8, 40);
    // Doubling the previous block exceeds the remainder; the smaller block fits.
    try std.testing.expect(initial * 2 > memory.backing.limit - initial);
    try std.testing.expectEqual(memory.backing.limit, memory.backing.used);
    try std.testing.expect(allocator.resize(first, 79));
    try std.testing.expect(!allocator.resize(first[0..79], 81));
    second = allocator.remap(second, 60).?;
    try std.testing.expect(allocator.remap(second, 256) == null);
    allocator.free(second);
    // A fully charged owner can still use its current block's existing tail.
    _ = try allocator.alloc(u8, 40);
    try std.testing.expectEqual(memory.backing.limit, memory.backing.used);
    try std.testing.expectEqualSlices(u8, &@as([79]u8, @splat(0xab)), first[0..79]);

    var short: Memory = undefined;
    short.init(std.testing.allocator, initial + header + 40 - 1);
    defer short.deinit();
    const retained = try short.working.allocator().dupe(u8, first);
    try std.testing.expectError(error.OutOfMemory, short.working.allocator().alloc(u8, 40));
    try std.testing.expectEqual(initial, short.backing.used);
    try std.testing.expectEqualSlices(u8, first, retained);
}

test "loam call blocks preserve alignment overflow and failed acquisition" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var memory: Memory = undefined;
    memory.init(failing.allocator(), 4096);
    defer memory.deinit();
    const allocator = memory.working.allocator();
    const first = try allocator.alignedAlloc(u8, .fromByteUnits(64), 96);
    @memset(first, 0xcd);
    const second = try allocator.alignedAlloc(u8, .fromByteUnits(128), 512);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(first.ptr) % 64);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(second.ptr) % 128);
    const acquired = memory.backing.used;
    const attempts = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
    try std.testing.expectEqual(attempts, failing.alloc_index);
    try std.testing.expectEqual(acquired, memory.backing.used);
    failing.fail_index = attempts;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1024));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(acquired, memory.backing.used);
    try std.testing.expectEqualSlices(u8, &@as([96]u8, @splat(0xcd)), first);
}

test "loam call arenas include headers and reclaim working blocks independently" {
    var live: metrics.LiveBytesAllocator = .{ .backing = std.testing.allocator };
    var memory: Memory = undefined;
    memory.init(live.allocator(), 4096);
    const input = try memory.input.allocator().dupe(u8, "retained input");
    const input_bytes = memory.backing.used;
    _ = try memory.working.allocator().alloc(u8, 256);
    const bytes = memory.backing.used;
    try std.testing.expect(bytes > memory.input.queryCapacity() + memory.working.queryCapacity());
    try std.testing.expectEqual(bytes, live.liveBytes());
    try std.testing.expectError(error.OutOfMemory, memory.working.allocator().alloc(u8, 4096));
    try std.testing.expectEqual(bytes, memory.backing.used);
    memory.resetWorking();
    try std.testing.expectEqual(input_bytes, memory.backing.used);
    try std.testing.expectEqualStrings("retained input", input);
    memory.deinit();
    try std.testing.expectEqual(@as(u64, 0), live.liveBytes());
}

test "loam small calls acquire backing independently of configured call ceiling" {
    var previous: ?u64 = null;
    for ([_]usize{ 64 * 1024, 32 * 1024 * 1024 }) |ceiling| {
        var live: metrics.LiveBytesAllocator = .{ .backing = std.testing.allocator };
        var fixture: f.Fixture = undefined;
        try fixture.initAllocator(live.allocator(), .{ .call_bytes = ceiling, .pending_bytes = ceiling, .ingress_bytes = ceiling });
        defer fixture.deinit();
        const before = live.liveBytes();
        var answer: f.Capture = .{};
        try fixture.send("get", &.{}, &answer);
        _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
        const acquired = live.liveBytes() - before;
        try std.testing.expectEqual(ceiling, fixture.attached.pending_bytes);
        try std.testing.expectError(error.Busy, fixture.attached.destroy());
        try fixture.drain();
        try std.testing.expectEqual(@as(?i64, 0), answer.value);
        try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
        try std.testing.expect(acquired < 16 * 1024);
        if (previous) |bytes| try std.testing.expectEqual(bytes, acquired);
        previous = acquired;
    }
}

test "loam retained ingress admits a large call without changing Vat queue limits" {
    var fixture: f.Fixture = undefined;
    try std.testing.expectError(error.InvalidLimits, fixture.init(.{ .call_bytes = 2 * 1024 * 1024 }));
    try fixture.init(.{ .call_bytes = 2 * 1024 * 1024, .pending_bytes = 4 * 1024 * 1024, .ingress_bytes = 2 * 1024 * 1024 });
    defer fixture.deinit();
    try std.testing.expectEqual(@as(u32, 1024 * 1024), fixture.host.vat.queue_limits.max_pending_bytes);
    var first: f.Capture = .{};
    var crowded: f.Capture = .{};
    try fixture.send("get", &.{}, &first);
    try fixture.send("get", &.{}, &crowded);
    _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), fixture.attached.pending_bytes);
    try std.testing.expect(crowded.broken);
    try std.testing.expect(first.value == null);
    try fixture.drain();
    try std.testing.expectEqual(@as(?i64, 0), first.value);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    var next: f.Capture = .{};
    try fixture.send("get", &.{}, &next);
    try fixture.drain();
    try std.testing.expectEqual(@as(?i64, 0), next.value);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
}

test "loam retained ingress keeps the independent turn bound and retires refused calls" {
    var fixture: f.Fixture = undefined;
    try fixture.init(.{ .ingress_bytes = 4 * 1024 * 1024 });
    defer fixture.deinit();
    fixture.host.vat.queue_limits.max_pending_turns = 1;
    var first: f.Capture = .{};
    try fixture.send("unknown", &.{}, &first);
    _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
    try std.testing.expectEqual(@as(usize, 64 * 1024), fixture.attached.pending_bytes);
    var second: f.Capture = .{};
    try fixture.send("get", &.{}, &second);
    _ = try fixture.host.vat.driveIngressBudgeted(.local, 64);
    try std.testing.expect(second.broken);
    try fixture.drain();
    try std.testing.expect(first.broken);
    try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
    var retry: f.Capture = .{};
    try fixture.send("get", &.{}, &retry);
    try fixture.drain();
    try std.testing.expectEqual(@as(?i64, 0), retry.value);
}
