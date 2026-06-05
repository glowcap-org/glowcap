const std = @import("std");
const pancake = @import("pancake");

const frame_support = @import("frame.zig");
const foundation = pancake.foundation;
const io_adapter = pancake.io_adapter;

pub fn writeFrameCopy(
    endpoint: *io_adapter.MemoryEndpoint,
    io: std.Io,
    frame: foundation.FrameView,
) !void {
    var owned = try frame_support.copyFromBorrowed(endpoint.allocator, frame.bytes, frame.shape);
    errdefer owned.deinit();
    try endpoint.writeFrameOwned(io, owned);
}
