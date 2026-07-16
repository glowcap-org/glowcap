const std = @import("std");
const gen = @import("binding_ffi_layout_gen.zig");

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

    for (gen.outputs) |out| {
        const bytes = try out.generate(a);
        defer a.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out.path, .data = bytes });
    }
}
