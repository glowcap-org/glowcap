const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const memory_endpoint_support = @import("../support/memory_endpoint.zig");

test "memory endpoint transfers owned frames without copying" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var endpoint = memory_endpoint_support.MemoryEndpoint.init(allocator);
    defer endpoint.deinit();

    const storage = try allocator.dupe(u8, "abc");
    const storage_ptr = @intFromPtr(storage.ptr);
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try endpoint.writeFrameOwned(io, frame);

    var read = (try endpoint.readFrame(io, allocator)).?;
    defer read.deinit();

    try std.testing.expectEqual(storage_ptr, @intFromPtr(read.bytes().ptr));
    try std.testing.expectEqualSlices(u8, "abc", read.bytes());
}

test "memory endpoint copy path is explicit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var endpoint = memory_endpoint_support.MemoryEndpoint.init(allocator);
    defer endpoint.deinit();

    var bytes = [_]u8{ 'a', 'b', 'c' };
    const source_ptr = @intFromPtr(bytes[0..].ptr);

    try memory_endpoint_support.writeFrameCopy(&endpoint, io, .{
        .bytes = bytes[0..],
        .shape = .byte,
    });

    var read = (try endpoint.readFrame(io, allocator)).?;
    defer read.deinit();

    try std.testing.expect(source_ptr != @intFromPtr(read.bytes().ptr));
    try std.testing.expectEqualSlices(u8, "abc", read.bytes());
}
