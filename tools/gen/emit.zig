//! Shared rewrite harness for every `tools/gen/` generator.
//!
//! `build.zig` adds the concrete generator as `@import("generator")`. Same
//! surface as `verify.zig`: `outputs` or `header_path` + `generate`.

const std = @import("std");
const generator = @import("generator");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (@hasDecl(generator, "outputs")) {
        for (generator.outputs) |out| {
            const bytes = try out.generate(a);
            defer a.free(bytes);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out.path, .data = bytes });
        }
    } else {
        const bytes = try generator.generate(a);
        defer a.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = generator.header_path, .data = bytes });
    }
}
