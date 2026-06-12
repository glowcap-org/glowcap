const std = @import("std");
const header_gen = @import("header_gen_iroh.zig");

// Force the sidecar stubs into the link so this reflection-only generator
// builds cargo-free (the iroh module's externs need a definition to link).
comptime {
    _ = @import("iroh_sidecar_stub.zig");
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = try header_gen.generate(a);
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = header_gen.header_path, .data = bytes });
}
