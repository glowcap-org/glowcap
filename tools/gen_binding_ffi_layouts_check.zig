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

    var stale = false;
    for (gen.outputs) |out| {
        const bytes = try out.generate(a);
        defer a.free(bytes);
        const committed = std.Io.Dir.cwd().readFileAlloc(io, out.path, a, .limited(1 << 20)) catch |err| {
            std.debug.print("gen-binding-ffi-layouts: {s} missing ({s}). Run `zig build gen-binding-ffi-layouts` and commit it.\n", .{ out.path, @errorName(err) });
            stale = true;
            continue;
        };
        defer a.free(committed);
        if (!std.mem.eql(u8, committed, bytes)) {
            std.debug.print("gen-binding-ffi-layouts: {s} is stale. Run `zig build gen-binding-ffi-layouts` and commit it.\n", .{out.path});
            stale = true;
        }
    }
    if (stale) return error.BindingFfiLayoutsStale;
}
