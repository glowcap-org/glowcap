const std = @import("std");
const gen = @import("binding_host_action_gen.zig");

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
            std.debug.print("gen-binding-host-action: {s} missing ({s}). Run `zig build gen-binding-host-action` and commit it.\n", .{ out.path, @errorName(err) });
            stale = true;
            continue;
        };
        defer a.free(committed);
        if (!std.mem.eql(u8, committed, bytes)) {
            std.debug.print("gen-binding-host-action: {s} is stale. Run `zig build gen-binding-host-action` and commit it.\n", .{out.path});
            stale = true;
        }
    }
    if (stale) return error.BindingHostActionStale;
}
