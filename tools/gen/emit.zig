//! Shared rewrite harness for every `tools/gen/` generator.
//!
//! `build.zig` adds the concrete generator as `@import("generator")`. Same
//! surface as `verify.zig`: every generator lists its files in one `outputs`
//! slice, single- or multi-file alike.

const std = @import("std");
const generator = @import("generator");

// Force-link the transport sidecar stubs here, in the executable root, so a
// generator that reflects a sidecar-linked archive stays cargo-free and no
// generator has to remember to force them itself.
comptime {
    _ = @import("iroh_sidecar_stub");
    _ = @import("webrtc_sidecar_stub");
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (generator.outputs) |out| {
        const bytes = try out.generate(a);
        defer a.free(bytes);
        // Rewriting a file whose bytes did not change still moves its mtime,
        // which invalidates every downstream cache keyed on it for no reason.
        if (try upToDate(a, io, out.path, bytes)) continue;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out.path, .data = bytes });
    }
}

/// Whether `path` already holds exactly `bytes`. A missing or unreadable file
/// is not up to date, so the write below still runs.
fn upToDate(a: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !bool {
    const on_disk = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return false;
    defer a.free(on_disk);
    return std.mem.eql(u8, on_disk, bytes);
}
