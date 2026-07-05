const std = @import("std");
const ts_abi_gen = @import("ts_abi_gen.zig");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = try ts_abi_gen.generate(a);
    defer a.free(bytes);
    const committed = try std.Io.Dir.cwd().readFileAlloc(io, ts_abi_gen.header_path, a, .limited(1 << 20));
    defer a.free(committed);

    if (!std.mem.eql(u8, committed, bytes)) {
        std.debug.print("gen-ts-abi: {s} is stale. Run `zig build gen-ts-abi` and commit it.\n", .{ts_abi_gen.header_path});
        return error.TsAbiStale;
    }
}
