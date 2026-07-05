const std = @import("std");
const ts_abi_gen = @import("ts_abi_gen.zig");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = try ts_abi_gen.generate(a);
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ts_abi_gen.header_path, .data = bytes });
}
