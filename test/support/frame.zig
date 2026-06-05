const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;

pub fn copyFromBorrowed(
    allocator: std.mem.Allocator,
    bytes_to_copy: []const u8,
    shape: foundation.FrameShape,
) !foundation.Frame {
    const storage = switch (shape) {
        .byte => try allocator.alloc(u8, bytes_to_copy.len),
        .word => try allocator.alignedAlloc(u8, .fromByteUnits(8), bytes_to_copy.len),
    };
    errdefer freeStorage(allocator, storage, shape);

    @memcpy(storage, bytes_to_copy);
    return foundation.Frame.initOwned(allocator, storage, shape, alignmentForShape(shape));
}

fn freeStorage(allocator: std.mem.Allocator, storage: []u8, shape: foundation.FrameShape) void {
    if (storage.len == 0) {
        return;
    }
    @memset(storage, undefined);
    allocator.rawFree(storage, alignmentForShape(shape), @returnAddress());
}

fn alignmentForShape(shape: foundation.FrameShape) std.mem.Alignment {
    return switch (shape) {
        .byte => .fromByteUnits(1),
        .word => .fromByteUnits(8),
    };
}
