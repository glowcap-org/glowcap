const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;

pub fn copyFromBorrowed(
    allocator: std.mem.Allocator,
    bytes_to_copy: []const u8,
    shape: foundation.FrameShape,
) !foundation.Frame {
    const storage = switch (shape) {
        .byte => try allocator.alloc(u8, bytes_to_copy.len),
        .word => try allocator.alignedAlloc(u8, .fromByteUnits(8), bytes_to_copy.len),
    };
    @memcpy(storage, bytes_to_copy);
    // `initOwned` takes ownership unconditionally: on a shape refusal it frees
    // the storage itself, so no errdefer is needed here.
    return foundation.Frame.initOwned(allocator, storage, shape, alignmentForShape(shape));
}

fn alignmentForShape(shape: foundation.FrameShape) std.mem.Alignment {
    return switch (shape) {
        .byte => .fromByteUnits(1),
        .word => .fromByteUnits(8),
    };
}
