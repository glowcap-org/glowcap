//! Shared stale-diff harness for every `tools/gen/` generator.
//!
//! `build.zig` adds the concrete generator as `@import("generator")`. The
//! generator exposes either `outputs` (multi-file) or `header_path` +
//! `generate` (single-file), plus `step_name` for the fix hint.

const std = @import("std");
const generator = @import("generator");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const step = generator.step_name;
    var stale = false;

    if (@hasDecl(generator, "outputs")) {
        for (generator.outputs) |out| {
            if (try verifyOne(a, io, step, out.path, out.generate)) stale = true;
        }
    } else {
        if (try verifyOne(a, io, step, generator.header_path, generator.generate)) stale = true;
    }

    if (stale) return error.GeneratedStale;
}

fn verifyOne(
    a: std.mem.Allocator,
    io: std.Io,
    step: []const u8,
    path: []const u8,
    generate: *const fn (std.mem.Allocator) anyerror![]u8,
) !bool {
    const bytes = try generate(a);
    defer a.free(bytes);
    const committed = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |err| {
        std.debug.print("{s}: {s} missing ({s}). Run `zig build {s}` and commit it.\n", .{ step, path, @errorName(err), step });
        return true;
    };
    defer a.free(committed);
    if (!std.mem.eql(u8, committed, bytes)) {
        std.debug.print("{s}: {s} is stale. Run `zig build {s}` and commit it.\n", .{ step, path, step });
        return true;
    }
    return false;
}
