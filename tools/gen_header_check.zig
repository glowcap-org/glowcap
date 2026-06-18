const std = @import("std");
const header_gen = @import("header_gen.zig");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = try header_gen.generate(a);
    defer a.free(bytes);
    const committed = try std.Io.Dir.cwd().readFileAlloc(io, header_gen.header_path, a, .limited(1 << 20));
    defer a.free(committed);

    if (!std.mem.eql(u8, committed, bytes)) {
        std.debug.print("gen-header-ocapn: {s} is stale. Run `zig build gen-header-ocapn` and commit it.\n", .{header_gen.header_path});
        return error.HeaderStale;
    }
}
