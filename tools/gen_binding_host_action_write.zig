const std = @import("std");
const gen = @import("binding_host_action_gen.zig");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (gen.outputs) |out| {
        const bytes = try out.generate(a);
        defer a.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out.path, .data = bytes });
    }
}
