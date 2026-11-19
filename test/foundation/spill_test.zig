//! What a stream's waiting bytes cost, at both tiers that keep them.
//!
//! `foundation.Spill` holds the front of a frame whose rest has not arrived.
//! Two tiers share it and they arrive with very different appetites: a stream
//! reader hands over a whole read buffer at once and only when a frame outgrows
//! it, while a byte-fed host straddles a chunk boundary by a handful of bytes on
//! ordinary traffic. The growth and the drain both have to serve both, and
//! neither is covered by the struct-size gates, because all of it is heap.

const std = @import("std");
const glowcap = @import("glowcap");

const Spill = glowcap.foundation.Spill;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;

test "spill capacity and allocation traffic follow geometric growth" {
    const payload = &@as([16384]u8, @splat(7));
    const Plan = struct { first: usize, chunk: usize = 0, repeats: usize = 0 };
    for ([_]Plan{
        .{ .first = 10 },
        .{ .first = payload.len },
        .{ .first = 1, .chunk = 1, .repeats = 999 },
        .{ .first = 1, .chunk = payload.len, .repeats = 1 },
    }) |plan| {
        var counter: CountingAllocator = .{ .backing = std.testing.allocator };
        const allocator = counter.allocator();
        var spill: Spill = .{};
        defer spill.deinit(allocator);
        var copy_bound_bytes: usize = 0;
        var growth_events: usize = 0;
        for (0..plan.repeats + 1) |i| {
            const before = spill.buf.len;
            const incoming = if (i == 0) plan.first else plan.chunk;
            const required = spill.len + incoming;
            try spill.absorbBytes(allocator, payload[0..incoming]);
            if (required > before) {
                copy_bound_bytes += before;
                growth_events += 1;
                try std.testing.expectEqual(@max(before * 2, required), spill.buf.len);
            } else {
                try std.testing.expectEqual(before, spill.buf.len);
            }
            try std.testing.expectEqual(required, spill.len);
            try std.testing.expectEqual(growth_events, counter.allocs);
            try std.testing.expect(copy_bound_bytes < spill.buf.len);
        }
        for (spill.bytes()) |byte| try std.testing.expectEqual(@as(u8, 7), byte);
    }
}

test "draining spill retains the smaller of capacity and the caller's limit" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 0, 4096, 16384 }) |retain| {
        var spill: Spill = .{};
        defer spill.deinit(allocator);
        try spill.absorbBytes(allocator, &@as([8192]u8, @splat(0)));
        const expected = @min(retain, spill.buf.len);
        spill.consume(allocator, spill.len, retain);
        try std.testing.expect(!spill.isActive());
        try std.testing.expectEqual(expected, spill.buf.len);
    }
}

test "a partial consume compacts the remainder to the front" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);

    try spill.absorbBytes(allocator, &[_]u8{ 1, 2, 3, 4, 5 });
    spill.consume(allocator, 2, 0);
    try std.testing.expect(spill.isActive());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 4, 5 }, spill.bytes());
}

test "zero consumption preserves waiting bytes but still releases an empty spill" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytes(allocator, "pending");
    const storage = spill.buf;
    spill.consume(allocator, 0, 0);
    try std.testing.expectEqual(storage.ptr, spill.buf.ptr);
    try std.testing.expectEqual(storage.len, spill.buf.len);
    try std.testing.expectEqualStrings("pending", spill.bytes());
    try spill.absorbBytes(allocator, " tail");
    spill.consume(allocator, 0, 0);
    try std.testing.expectEqualStrings("pending tail", spill.bytes());
    spill.consume(allocator, spill.len, spill.buf.len);
    try std.testing.expectEqual(@as(usize, 0), spill.len);
    try std.testing.expect(spill.buf.len != 0);
    spill.consume(allocator, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), spill.buf.len);
}

test "spill reservation overflow preserves pending bytes and permits retry" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytesPrecise(allocator, "pending");
    const storage = spill.buf;
    try std.testing.expectError(error.OutOfMemory, spill.ensureUnusedCapacityPrecise(allocator, std.math.maxInt(usize)));
    try std.testing.expectEqual(storage.ptr, spill.buf.ptr);
    try std.testing.expectEqual(storage.len, spill.buf.len);
    try std.testing.expectEqualStrings("pending", spill.bytes());
    try spill.ensureUnusedCapacityPrecise(allocator, 5);
    spill.absorbBytesAssumeCapacity(" tail");
    try std.testing.expectEqualStrings("pending tail", spill.bytes());
}

test "spill append refusal preserves storage and bytes for both growth policies" {
    const allocator = std.testing.allocator;
    inline for (.{ Spill.absorbBytes, Spill.absorbBytesPrecise }) |absorb| {
        var spill: Spill = .{};
        defer spill.deinit(allocator);
        try absorb(&spill, allocator, "pending");
        const storage = spill.buf;
        var refusing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        try absorb(&spill, refusing.allocator(), "");
        try std.testing.expectError(error.OutOfMemory, absorb(&spill, refusing.allocator(), " tail"));
        try std.testing.expectEqual(storage.ptr, spill.buf.ptr);
        try std.testing.expectEqual(storage.len, spill.buf.len);
        try std.testing.expectEqualStrings("pending", spill.bytes());
        try absorb(&spill, allocator, " tail");
        try std.testing.expectEqualStrings("pending tail", spill.bytes());
    }
}

test "truncate drops the bytes absorbed after a mark and keeps the buffer" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytes(allocator, "12:ab");
    const mark = spill.len;
    try spill.absorbBytes(allocator, "cdef");
    const capacity = spill.buf.len;
    spill.truncate(mark);
    try std.testing.expectEqualStrings("12:ab", spill.bytes());
    try std.testing.expectEqual(capacity, spill.buf.len);
}
