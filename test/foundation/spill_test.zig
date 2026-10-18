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

test "a small straddle costs a small buffer, not a fixed floor" {
    const allocator = std.testing.allocator;
    // The byte-fed host tier reaches this on any chunk boundary that lands
    // mid-frame, which is most connections. A kilobyte-scale growth floor here
    // is multiplied by every live connection, so it is a footprint decision
    // rather than an allocation detail: at the ladder's 500k target, a 4 KiB
    // floor is about two gigabytes for tails that hold a few bytes each.
    var spill: Spill = .{};
    defer spill.deinit(allocator);

    try spill.absorbBytes(allocator, &@as([10]u8, @splat(0)));
    try std.testing.expectEqual(@as(usize, 10), spill.bytes().len);
    try std.testing.expect(spill.buf.len < 64);
}

test "a whole read buffer lands in one allocation" {
    const allocator = std.testing.allocator;
    // The other tier's first absorb is everything the reader had buffered, so
    // growing toward it in doublings would pay a realloc per doubling. Taking
    // what is asked when it exceeds a double keeps that to one.
    var spill: Spill = .{};
    defer spill.deinit(allocator);

    try spill.absorbBytes(allocator, &@as([16384]u8, @splat(0)));
    try std.testing.expectEqual(@as(usize, 16384), spill.buf.len);
}

test "growth stays geometric across many small absorbs" {
    const allocator = std.testing.allocator;
    // Exact-fit growth would realloc on every absorb. Doubling is what keeps a
    // dribbled frame's assembly amortized, which is the whole reason the spill
    // is cheaper than re-reading.
    var spill: Spill = .{};
    defer spill.deinit(allocator);

    var i: usize = 0;
    while (i < 1000) : (i += 1) try spill.absorbBytes(allocator, &[_]u8{7});
    try std.testing.expectEqual(@as(usize, 1000), spill.bytes().len);
    // Ten doublings from a one-byte start reach 1024; anything near 1000 means
    // it grew one byte at a time.
    try std.testing.expect(spill.buf.len <= 2048);
    for (spill.bytes()) |b| try std.testing.expectEqual(@as(u8, 7), b);
}

test "a drained spill keeps what its tier asked it to keep" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);

    // Retain zero: the stream-reader posture, where spilling is the exception.
    try spill.absorbBytes(allocator, &@as([8192]u8, @splat(0)));
    spill.consume(allocator, 8192, 0);
    try std.testing.expect(!spill.isActive());
    try std.testing.expectEqual(@as(usize, 0), spill.buf.len);

    // Retain a steady size: the byte-fed posture, where straddling is ordinary.
    try spill.absorbBytes(allocator, &@as([8192]u8, @splat(0)));
    spill.consume(allocator, 8192, 4096);
    try std.testing.expect(!spill.isActive());
    try std.testing.expectEqual(@as(usize, 4096), spill.buf.len);

    // Under the bound, a drain keeps what it has rather than growing to meet it.
    var small: Spill = .{};
    defer small.deinit(allocator);
    try small.absorbBytes(allocator, &@as([10]u8, @splat(0)));
    const grown = small.buf.len;
    small.consume(allocator, 10, 4096);
    try std.testing.expectEqual(grown, small.buf.len);
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
